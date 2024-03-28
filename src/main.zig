const std = @import("std");
const clap = @import("clap");

const io = std.io;

const ArgError = error{
    bad_coordinate,
    no_resolution,
    no_duration,
};

pub fn parseCoordinate(resolution_str: []const u8) ![2]usize {
    var index_of_x: ?usize = null;
    for (0.., resolution_str) |i, char| {
        if (char == 'x') {
            index_of_x = i;
            break;
        }
    }

    const x_index = index_of_x orelse
        return ArgError.bad_coordinate;

    const width_str = resolution_str[0..x_index];
    const height_str = resolution_str[x_index + 1 ..];

    const width = std.fmt.parseInt(usize, width_str, 10) catch
        return ArgError.bad_coordinate;
    const height = std.fmt.parseInt(usize, height_str, 10) catch
        return ArgError.bad_coordinate;

    return .{ width, height };
}

/// Configuration options passed from the command line.
const CliConfig = struct {
    allocator: std.mem.Allocator,

    x: usize = 0,
    y: usize = 0,
    gif_width: usize,
    gif_height: usize,

    duration_seconds: f64,
    out_path: [:0]const u8,

    pub fn deinit(self: *const CliConfig) void {
        self.allocator.free(self.out_path);
    }
};

pub fn parseArguments(allocator: std.mem.Allocator) !?CliConfig {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this message and exit.
        \\-r, --resolution <str>    <width>x<height> Set the dimensions of the image.
        \\-d, --duration   <f64>    Set the duration of the GIF (in seconds).
        \\-o, --output     <str>    Set the output filepath (default: out.gif).
        \\-c, --coord      <str>    <x>x<y> Set the top-left coordinates of the capture area (default: 0,0).
    );

    var diag = clap.Diagnostic{};

    const res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        return null;
    }

    const resolution = if (res.args.resolution) |res_str|
        try parseCoordinate(res_str)
    else {
        return ArgError.no_resolution;
    };

    const topleft = if (res.args.coord) |coord|
        try parseCoordinate(coord)
    else
        .{ 0, 0 };

    const duration = if (res.args.duration) |dur| dur else {
        return ArgError.no_duration;
    };

    const output = res.args.output orelse "out.gif";
    const output_owned = try allocator.dupeZ(u8, output);

    return CliConfig{
        .allocator = allocator,
        .x = topleft[0],
        .y = topleft[1],
        .gif_width = resolution[0],
        .gif_height = resolution[1],
        .duration_seconds = duration,
        .out_path = output_owned,
    };
}

const core = @import("frametap");
const FrameTap = core.FrameTap;
const zgif = @import("zgif");
const Queue = @import("util/queue.zig").Queue;

const Thread = std.Thread;

/// Data shared between the thread that produces frames,
/// and the one that consumes them.
const SharedContext = struct {
    /// A Queue of frames. Producer pushes, consumer pops.
    unprocessed_frames: *Queue(core.Frame),
    /// A thread must hold this mutext to acess anything else in the struct
    mutex: Thread.Mutex = .{},
    /// Will be posted to when the producer is finished.
    all_frames_produced: Thread.Semaphore = .{},
    /// The producer will post to this when a new frame is ready for processing.
    new_frame_ready: Thread.Semaphore = .{},
};

const Capturer = FrameTap(*SharedContext);

fn startCapture(ctx: *SharedContext, capturer: *Capturer) !void {
    try capturer.capture.begin(); // this will block forever.
    ctx.mutex.lock();
    ctx.all_frames_produced.post();
    ctx.new_frame_ready.post();
    ctx.mutex.unlock();
}

fn produceFrame(ctx: *SharedContext, frame: core.Frame) !void {
    ctx.mutex.lock();
    try ctx.unprocessed_frames.push(frame);
    ctx.mutex.unlock();
    ctx.new_frame_ready.post();
}

fn consumer(
    ctx: *SharedContext,
    width: usize, // width of a frame.
    height: usize, // height of a frame.
    out_path: [:0]const u8, // path to write the gif to.
) !void {
    const allocator = std.heap.page_allocator;
    var gif = try zgif.Gif.init(allocator, .{
        .width = width,
        .height = height,
        .path = out_path,
        .use_dithering = true,
    });

    defer gif.deinit();

    while (true) {
        ctx.new_frame_ready.wait();
        if (ctx.all_frames_produced.timedWait(0)) break else |_| {
            // If it errors out, then there is nothing to wait on.
            // This means the producer hasn't called `post` on this semaphore,
            // because it's not done producing frames yet.
        }

        ctx.mutex.lock(); // lock this mutex to access values in ctx.
        std.debug.assert(!ctx.unprocessed_frames.isEmpty());
        const frame = try ctx.unprocessed_frames.pop();
        const duration = frame.duration_ms;
        ctx.mutex.unlock(); // unlock drop mutex after frame is copied.

        // add frame to GIF.
        try gif.addFrame(.{
            .bgra_buf = frame.image.data,
            .duration_ms = @intFromFloat(duration),
        });
    }

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    while (!ctx.unprocessed_frames.isEmpty()) {
        const frame = try ctx.unprocessed_frames.pop();
        try gif.addFrame(.{
            .bgra_buf = frame.image.data,
            .duration_ms = @intFromFloat(frame.duration_ms),
        });
    }

    try gif.close();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const maybe_args = if (parseArguments(allocator)) |args| args else |err| {
        switch (err) {
            ArgError.bad_coordinate => {
                _ = try io.getStdErr().write("Invalid coordinate. Use <width>x<height>\n");
            },
            ArgError.no_resolution => {
                _ = try io.getStdErr().write("Resolution is required (e.g -r 400x400)\n");
            },
            ArgError.no_duration => {
                _ = try io.getStdErr().write("Duration is required (e.g -d 10)\n");
            },
            else => |e| return e,
        }

        return err;
    };

    const args = maybe_args orelse return;
    defer args.deinit();

    const frame_queue = try allocator.create(Queue(core.Frame));
    frame_queue.* = try Queue(core.Frame).init(allocator);
    defer {
        frame_queue.deinit();
        allocator.destroy(frame_queue);
    }

    const ctx = try allocator.create(SharedContext);
    ctx.* = SharedContext{ .unprocessed_frames = frame_queue };
    defer allocator.destroy(ctx);

    const capturer = try Capturer.init(allocator, ctx, .{
        .x = @floatFromInt(args.x),
        .y = @floatFromInt(args.y),
        .width = @floatFromInt(args.gif_width),
        .height = @floatFromInt(args.gif_height),
    });
    defer capturer.deinit();
    capturer.onFrame(produceFrame);

    const producer_thread = try std.Thread.spawn(.{}, startCapture, .{ ctx, capturer });
    const consumer_thread = try std.Thread.spawn(.{}, consumer, .{
        ctx,
        args.gif_width,
        args.gif_height,
        args.out_path,
    });

    const sleep_ns: u64 = @intFromFloat(
        args.duration_seconds * @as(f64, @floatFromInt(std.time.ns_per_s)),
    );

    std.time.sleep(sleep_ns);

    try capturer.capture.end();
    producer_thread.join();
    consumer_thread.join();
}
