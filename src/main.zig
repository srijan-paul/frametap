pub const core = @import("core.zig");
const std = @import("std");
const gif = @import("gif.zig");

const FrameTap = core.FrameTap(*std.ArrayList([]const u8));
fn onFrame(frames: *std.ArrayList([]const u8), frame: core.Frame) !void {
    try frames.append(frame.data);
}

fn captureFrames(frametap: *FrameTap) !void {
    try frametap.capture.begin();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var frames = std.ArrayList([]const u8).init(allocator);
    var frametap = try FrameTap.init(allocator, &frames, core.Rect{
        .x = 0,
        .y = 100,
        .width = 400,
        .height = 400,
    });
    defer {
        frametap.deinit();
        for (frames.items) |frame| {
            allocator.free(frame);
        }
        frames.deinit();
    }
    frametap.onFrame(onFrame);

    _ = try std.Thread.spawn(.{}, captureFrames, .{frametap});
    std.time.sleep(4 * std.time.ns_per_s);

    try frametap.capture.end();
    try gif.bgraFrames2Gif(
        allocator,
        frames.items,
        10,
        400,
        400,
        "out.gif",
    );
}
