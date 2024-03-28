const std = @import("std");
const stb = @cImport(@cInclude("load_image.h"));

const FrameTapError = @import("core.zig").FrametapError;

/// Convert an RGBA frame to a PNG file.
pub fn writeRgbaToPng(
    allocator: std.mem.Allocator,
    buf: []const u8,
    width: usize,
    height: usize,
    file_path: [:0]const u8,
) !void {
    const rgb = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(rgb);

    for (width * height) |i| {
        const rgba_offset = i * 4;
        const rgb_offset = i * 3;
        rgb[rgb_offset] = buf[rgba_offset];
        rgb[rgb_offset + 1] = buf[rgba_offset + 1];
        rgb[rgb_offset + 2] = buf[rgba_offset + 2];
    }

    const ok = stb.write_image_to_png(file_path.ptr, rgb.ptr, width, height);
    if (!ok) {
        return FrameTapError.PNGConvertFailed;
    }
}
