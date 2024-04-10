pub const core = @import("core.zig");
const std = @import("std");
const gif = @import("gif.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var frames = std.ArrayList(core.Frame).init(allocator);
    const FrameTap = core.FrameTap(*std.ArrayList(core.Frame));
    var frametap = try FrameTap.init(allocator, &frames, onFrame);
    // try frametap.capture.begin();

    const area = core.Rect{
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 50,
    };
    const frame = try frametap.capture.screenshot(area);
    try frame.writePng("screenshot.png");

    // defer {
    //     frametap.deinit();
    //     for (frames.items) |frame| {
    //         allocator.free(frame.data);
    //     }
    //     frames.deinit();
    // }

    // try gif.bgraFrames2Gif(
    //     allocator,
    //     ctx.frames.items,
    //     std.time.ms_per_s * 4,
    //     @intCast(ctx.width),
    //     @intCast(ctx.height),
    //     "out.gif",
    // );
}

pub fn onFrame(frames: *std.ArrayList(core.Frame), frame: core.Frame) !void {
    try frames.append(frame);
    std.debug.print("frame: {}x{}\n", .{ frame.width, frame.height });
}
