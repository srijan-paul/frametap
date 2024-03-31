// A Zig wrapper for the CGIF project.
// Only supports the functionality needed by this this project.

const std = @import("std");
const cgif = @cImport(@cInclude("cgif.h"));
const JifError = @import("./core.zig").JifError;
const quant = @import("./quantize.zig");

/// Intialize a cgif gif config struct.
fn initGifConfig(
    gif_config: *cgif.CGIF_Config,
    path: [:0]const u8,
    width: usize,
    height: usize,
) void {
    // in a c program, this would be a memset(0), but we can't do that in Zig
    gif_config.pGlobalPalette = null;
    gif_config.pContext = null;
    gif_config.pWriteFn = null;
    gif_config.attrFlags = 0;
    gif_config.genFlags = 0;
    gif_config.numGlobalPaletteEntries = 0;
    gif_config.numLoops = 0;

    gif_config.path = path.ptr;
    gif_config.width = @intCast(width);
    gif_config.height = @intCast(height);
}

/// Intialize a cgif frame config struct.
fn initFrameConfig(conf: *cgif.CGIF_FrameConfig, delay: u16) void {
    conf.pLocalPalette = null;
    conf.pImageData = null;

    conf.numLocalPaletteEntries = 0;
    conf.attrFlags = 0;
    conf.genFlags = 0;
    conf.transIndex = 0;

    conf.delay = delay;
}

/// convert a sequence of BGRA frames to a gif file.
pub fn bgraFrames2Gif(
    allocator: std.mem.Allocator,
    frames: []const []const u8,
    width: usize,
    height: usize,
    path: [:0]const u8,
) !void {
    const n_pixels = width * height;
    const rgb_buf = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(rgb_buf);

    var gif_config: cgif.CGIF_Config = undefined;
    initGifConfig(&gif_config, path, width, height);
    gif_config.attrFlags = cgif.CGIF_ATTR_NO_GLOBAL_TABLE | cgif.CGIF_ATTR_IS_ANIMATED;

    var frame_config: cgif.CGIF_FrameConfig = undefined;
    initFrameConfig(&frame_config, 10);
    frame_config.attrFlags = cgif.CGIF_FRAME_ATTR_USE_LOCAL_TABLE;

    var gif: *cgif.CGIF = cgif.cgif_newgif(&gif_config) orelse {
        return JifError.GifConvertFailed;
    };
    gif = gif; // suppress non-const warning. cgif needs this to be non-const.

    for (frames) |frame| {
        // convert BGRA buffer to RGB
        for (0..n_pixels) |i| {
            const src_base = i * 4;
            const dst_base = i * 3;

            const b = frame[src_base];
            const g = frame[src_base + 1];
            const r = frame[src_base + 2];

            rgb_buf[dst_base] = r;
            rgb_buf[dst_base + 1] = g;
            rgb_buf[dst_base + 2] = b;
        }

        // quantize the RGB buffer
        const quantized = try quant.quantize(allocator, rgb_buf);
        defer quantized.deinit(allocator);

        frame_config.pImageData = quantized.image_buffer.ptr;
        frame_config.pLocalPalette = quantized.color_table.ptr;
        frame_config.numLocalPaletteEntries = @intCast(quantized.color_table.len / 3);

        if (cgif.cgif_addframe(gif, &frame_config) != 0) {
            return JifError.GifConvertFailed;
        }
        // std.debug.print("added frame\n", .{});
    }

    if (cgif.cgif_close(gif) != 0) {
        return JifError.GifFlushFailed;
    }
}
