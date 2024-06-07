pub const core = @import("core.zig");
const std = @import("std");
const gif = @import("gif.zig");

const FrameTap = core.FrameTap(*std.ArrayList(core.Frame));
fn onFrame(frames: *std.ArrayList(core.Frame), frame: core.Frame) !void {
    try frames.append(frame);
}

fn captureFrames(frametap: *FrameTap) !void {
    try frametap.capture.begin();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var frames = std.ArrayList(core.Frame).init(allocator);
    var frametap = try FrameTap.init(allocator, &frames, core.Rect{
        .x = 0,
        .y = 51,
        .width = 500,
        .height = 500,
    });

    defer {
        frametap.deinit();
        for (frames.items) |frame| {
            allocator.free(frame.image.data);
        }
        frames.deinit();
    }
    frametap.onFrame(onFrame);

    _ = try std.Thread.spawn(.{}, captureFrames, .{frametap});
    std.time.sleep(5 * std.time.ns_per_s);

    try frametap.capture.end();
    try gif.encodeGif(allocator, .{
        .frames = frames.items,
        .path = "out.gif",
        .use_global_palette = true,
    });
}
