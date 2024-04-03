pub const core = @import("core.zig");
const screencap = @cImport(@cInclude("screencap.h"));
const mac = @import("mac-os.zig");
const std = @import("std");
const png = @import("png.zig");
const gif = @import("gif.zig");

const Thread = std.Thread;

pub const GifContext = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    frames: std.ArrayList([]u8),
    width: usize,
    height: usize,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Self {
        return GifContext{
            .allocator = allocator,
            .frames = std.ArrayList([]u8).init(allocator),
            .width = 0,
            .height = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.frames.items) |frame| {
            self.allocator.free(frame);
        }
        self.frames.deinit();
    }
};

export fn processFrame(
    frame: [*c]u8,
    w: usize,
    h: usize,
    bytes_per_row: usize,
    otherdata: ?*anyopaque,
) void {
    const ptr = if (otherdata) |ptr| ptr else return std.debug.panic("failed cast", .{});
    const gif_ctx: *GifContext = @alignCast(@ptrCast(ptr));

    gif_ctx.width = w;
    gif_ctx.height = h;

    const len = bytes_per_row * h;
    const buf = gif_ctx.allocator.alloc(u8, len) catch std.debug.panic("WTF", .{});

    @memcpy(buf, @as([*]u8, frame));

    gif_ctx.frames.append(buf) catch std.debug.panic("WTF", .{});
}

fn startCapture(sc: *screencap.ScreenCapture) void {
    _ = screencap.start_capture_and_wait(sc);
}

pub fn main_() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var ctx = GifContext.init(allocator);
    defer ctx.deinit();

    var frame_processor: screencap.FrameProcessor = undefined;
    frame_processor.other_data = &ctx;
    frame_processor.process_fn = processFrame;

    const sc = screencap.alloc_capture().?;
    screencap.init_capture(sc, frame_processor);

    const thread = try std.Thread.spawn(.{}, startCapture, .{sc});
    std.time.sleep(std.time.ns_per_s * 4);

    screencap.stop_capture(sc);
    thread.join();
    try gif.bgraFrames2Gif(
        allocator,
        ctx.frames.items,
        std.time.ms_per_s * 4,
        @intCast(ctx.width),
        @intCast(ctx.height),
        "out.gif",
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var capture = try core.Capture.create(allocator, null);
    defer capture.destroy();

    const then = std.time.milliTimestamp();
    const frame = try capture.screenshot(null);
    const now = std.time.milliTimestamp();

    const delta = now - then;

    std.debug.print("{}x{} screenshot took: {} (size: {})\n", .{ frame.width, frame.height, delta, frame.data.len });

    const dir = std.fs.cwd();
    const file = try dir.createFile("input.rgba", .{ .read = true });
    try file.writeAll(frame.data);
}
