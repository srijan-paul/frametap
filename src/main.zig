const std = @import("std");
const clap = @import("clap");

const io = std.io;

const ArgError = error{
    bad_resolution,
    no_resolution,
    no_duration,
};

pub fn parseResolution(resolution_str: []const u8) ![2]usize {
    var index_of_x: ?usize = null;
    for (0.., resolution_str) |i, char| {
        if (char == 'x') {
            index_of_x = i;
            break;
        }
    }

    const x_index = index_of_x orelse
        return ArgError.bad_resolution;

    const width_str = resolution_str[0..x_index];
    const height_str = resolution_str[x_index + 1 ..];

    const width = std.fmt.parseInt(usize, width_str, 10) catch
        return ArgError.bad_resolution;
    const height = std.fmt.parseInt(usize, height_str, 10) catch
        return ArgError.bad_resolution;

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
        \\-h, --help                Display this help and exit.
        \\-r, --resolution <str>    <width>x<height> Set the dimensions of the image.
        \\-d, --duration   <f64>    Set the duration of the GIF (in seconds).
        \\-o, --output     <str>    Set the output filepath (default: out.gif).
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
        try parseResolution(res_str)
    else {
        _ = try io.getStdErr().write("Resolution is required (e.g -r 400x400)\n");
        return ArgError.no_resolution;
    };

    const duration = if (res.args.duration) |dur| dur else {
        _ = try io.getStdErr().write("Duration is required (e.g -d 100)\n");
        return ArgError.no_duration;
    };

    const output = res.args.output orelse "out.gif";
    const output_owned = try allocator.dupeZ(u8, output);

    return CliConfig{
        .allocator = allocator,
        .x = 0,
        .y = 0,
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
    all_frames_produced: Thread.Mutex = .{},
    /// The producer will post to this when a new frame is ready for processing.
    new_frame_ready: Thread.Semaphore = .{},
};

const Capturer = FrameTap(*SharedContext);

fn startCapture(capturer: *Capturer) !void {
    try capturer.capture.begin(); // this will block forever.
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
    });

    defer gif.deinit();

    // Allocate a buffer that can hold the color data
    // for a frame when it arrives.
    const framebuf: []u8 = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(framebuf);

    while (true) {
        ctx.new_frame_ready.wait();

        const no_more_frames = ctx.all_frames_produced.tryLock();
        if (no_more_frames) {
            ctx.mutex.lock();
            break;
        }

        ctx.mutex.lock(); // lock mutex to access queue
        std.debug.assert(!ctx.unprocessed_frames.isEmpty());
        const frame = try ctx.unprocessed_frames.pop();
        const duration = frame.duration_ms;
        @memcpy(framebuf, frame.image.data);
        ctx.mutex.unlock(); // drop mutex after frame is copied.

        // add frame to GIF.
        try gif.addFrame(.{
            .bgra_buf = framebuf,
            .duration_ms = @intFromFloat(duration),
        });
    }

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

    const args = (try parseArguments(allocator)) orelse return;
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
        .x = 0,
        .y = 0,
        .width = @floatFromInt(args.gif_width),
        .height = @floatFromInt(args.gif_height),
    });
    defer capturer.deinit();
    capturer.onFrame(produceFrame);

    ctx.all_frames_produced.lock();
    const producer_thread = try std.Thread.spawn(.{}, startCapture, .{capturer});
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

    ctx.all_frames_produced.unlock();
    ctx.new_frame_ready.post();

    consumer_thread.join();

    std.debug.print("done :)\n", .{});
}
