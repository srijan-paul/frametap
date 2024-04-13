pub const core = @import("core.zig");
const std = @import("std");
const gif = @import("gif.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const FrameTap = core.FrameTap(?*anyopaque);
    var frametap = try FrameTap.init(allocator, null);

    const area = core.Rect{
        .x = 0,
        .y = 0,
        .width = 1000,
        .height = 1000,
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
