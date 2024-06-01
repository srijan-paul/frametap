pub const core = @import("core.zig");
const std = @import("std");
const gif = @import("gif.zig");
const lib = @import("lib.zig");
const png = @import("png.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const frame = lib.captureFrame(0, 0, 400, 400);
    defer lib.releaseFrame(frame);

    const rgba: []u8 = frame.data[0 .. frame.width * frame.height * 4];

    const quantized = try gif.quantizeRgbaFrame(allocator, rgba, frame.width, frame.height);
    defer allocator.free(quantized);

    try png.writeRgbaToPng(quantized, frame.width, frame.height, "out.png");
}
