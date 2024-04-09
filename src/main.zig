pub const core = @import("core.zig");
const std = @import("std");
const gif = @import("gif.zig");

const Thread = std.Thread;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var frames = std.ArrayList(core.Frame).init(allocator);
    const FrameTap = core.FrameTap(*std.ArrayList(core.Frame));
    var frametap = try FrameTap.init(allocator, &frames, onFrame);
    // try frametap.capture.begin();

    const frame = try frametap.capture.screenshot(null);
    const file_path = "screenshot.png";
    try frame.writePNG(file_path);

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
