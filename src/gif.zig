// A Zig wrapper for the CGIF project.
// Only supports the functionality needed by this this project.

const std = @import("std");
const cgif = @cImport(@cInclude("cgif.h"));
const core = @import("./core.zig");
const quant = @import("./quantize.zig");

const FrametapError = core.FrametapError;

/// Intialize a cgif gif config struct.
fn initGifConfig(
    gif_config: *cgif.CGIF_Config,
    path: [:0]const u8,
    width: usize,
    height: usize,
) void {
    // in a c program, this would be a memset(gif_config, 0), but we can't do that in Zig
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
fn initFrameConfig(conf: *cgif.CGIF_FrameConfig) void {
    conf.pLocalPalette = null;
    conf.pImageData = null;

    conf.numLocalPaletteEntries = 0;
    conf.attrFlags = 0;
    conf.genFlags = 0;
    conf.transIndex = 0;

    conf.delay = 0;
}

pub fn applyQuantization(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    quantized: quant.QuantizeResult,
) ![]const u8 {
    const n_pixels = width * height;
    var new_frame = try allocator.alloc(u8, n_pixels * 4);

    for (0..n_pixels) |i| {
        const dst_base = i * 4;

        const color_index: usize = quantized.image_buffer[i];
        new_frame[dst_base] = quantized.color_table[color_index * 3];
        new_frame[dst_base + 1] = quantized.color_table[color_index * 3 + 1];
        new_frame[dst_base + 2] = quantized.color_table[color_index * 3 + 2];
        new_frame[dst_base + 3] = 255;
    }

    return new_frame;
}

// quantize a single frame from 4bit BGRA to 3 bit RGB.
pub fn quantizeRgbaFrame(
    allocator: std.mem.Allocator,
    frame: []const u8,
    width: usize,
    height: usize,
) ![]const u8 {
    const n_pixels = width * height;
    const rgb_buf = try allocator.alloc(u8, n_pixels * 3);
    defer allocator.free(rgb_buf);

    // convert BGRA buffer to RGB
    for (0..n_pixels) |i| {
        const src_base = i * 4;
        const dst_base = i * 3;

        const r = frame[src_base];
        const g = frame[src_base + 1];
        const b = frame[src_base + 2];

        rgb_buf[dst_base] = r;
        rgb_buf[dst_base + 1] = g;
        rgb_buf[dst_base + 2] = b;
    }

    const quantize_result = try quant.quantizeRgbImage(allocator, rgb_buf);
    defer quantize_result.deinit(allocator);

    return applyQuantization(allocator, width, height, quantize_result);
}

/// A struct to hold the settings for the Gif encoder.
pub const GifEncoderSettings = struct {
    /// BGRA frames to encode.
    frames: []core.Frame,
    /// The output path for the .gif file.
    path: [:0]const u8,
    /// When `true`, the encoder will use a single global color palette
    /// for all frames. Helps reduce file size.
    use_global_palette: bool = false,
};

/// Encode a sequence of BGRA frames to a gif file using a global color palette.
/// `frame_config` must be initialized with the desired `genFlags`.
/// duration, palette, and image data can be uninitialized.
/// `gif_config` must also be initialized with the desired `path`, `width`, `height`, and flags.
fn encodeGifWithGlobalPalette(
    allocator: std.mem.Allocator,
    frames: []core.Frame,
    gif: *cgif.CGIF,
    gif_config: *cgif.CGIF_Config,
    frame_config: *cgif.CGIF_FrameConfig,
) !void {
    var raw_frames = try allocator.alloc([]const u8, frames.len);
    defer allocator.free(raw_frames);

    for (0.., frames) |i, *frame| {
        raw_frames[i] = frame.image.data;
    }

    const quantized = try quant.quantizeBgraFrames(allocator, raw_frames);
    defer quantized.deinit();

    std.debug.assert(quantized.frames.len == frames.len);

    gif_config.pGlobalPalette = quantized.color_table.ptr;
    gif_config.numGlobalPaletteEntries = @truncate(quantized.color_table.len / 3);
    std.debug.assert(gif_config.numGlobalPaletteEntries == 256);

    for (0.., frames) |i, *frame| {
        const qframe = quantized.frames[i];
        frame_config.pImageData = qframe.ptr;

        const duration = frame.duration_ms / 10.0;
        const duration_int: u64 = @intFromFloat(@round(duration));
        frame_config.delay = @truncate(duration_int);

        const r = cgif.cgif_addframe(gif, frame_config);
        if (r != 0) {
            std.debug.print("Error: {}\n", .{r});
            return FrametapError.GifConvertFailed;
        }
    }

    const closed = cgif.cgif_close(gif);
    if (closed != 0) {
        return FrametapError.GifFlushFailed;
    }
}

/// Encode a sequence of BGRA frames to a gif file using a local color palette.
/// `frame_config` must be initialized with the desired `genFlags`.
/// duration, palette, and image data can be uninitialized.
fn encodeGifWithLocalPalette(
    allocator: std.mem.Allocator,
    frames: []core.Frame,
    gif: *cgif.CGIF,
    frame_config: *cgif.CGIF_FrameConfig,
) !void {
    const width = frames[0].image.width;
    const height = frames[0].image.height;

    const n_pixels = width * height;
    const rgb_buf = try allocator.alloc(u8, n_pixels * 3);
    defer allocator.free(rgb_buf);

    for (frames) |*frame| {
        const bgra_buf = frame.image.data;
        // convert BGRA buffer to RGB
        for (0..n_pixels) |i| {
            const src_base = i * 4;
            const dst_base = i * 3;

            const b = bgra_buf[src_base];
            const g = bgra_buf[src_base + 1];
            const r = bgra_buf[src_base + 2];

            rgb_buf[dst_base] = r;
            rgb_buf[dst_base + 1] = g;
            rgb_buf[dst_base + 2] = b;
        }

        // quantize the RGB buffer
        const quantized = try quant.quantizeRgbImage(allocator, rgb_buf);
        defer quantized.deinit(allocator);

        // CGIF uses units of 0.01s for frame delay.
        const duration = frame.duration_ms / 10.0;
        const duration_int: u64 = @intFromFloat(@round(duration));

        frame_config.delay = @truncate(duration_int);
        frame_config.pImageData = quantized.image_buffer.ptr;
        frame_config.pLocalPalette = quantized.color_table.ptr;
        frame_config.numLocalPaletteEntries = @intCast(quantized.color_table.len / 3);

        if (cgif.cgif_addframe(gif, frame_config) != 0) {
            return FrametapError.GifConvertFailed;
        }
    }

    const closed = cgif.cgif_close(gif);
    if (closed != 0) {
        return FrametapError.GifFlushFailed;
    }
}

/// convert a sequence of BGRA frames to a gif file.
pub fn encodeGif(allocator: std.mem.Allocator, config: GifEncoderSettings) !void {
    const frames = config.frames;
    const path = config.path;

    const width = frames[0].image.width;
    const height = frames[0].image.height;

    // 1. Initialize the GIF config (as required by the cgif library).
    var gif_config: cgif.CGIF_Config = undefined;
    initGifConfig(&gif_config, path, width, height);
    gif_config.attrFlags = cgif.CGIF_ATTR_IS_ANIMATED;

    // 2. Initialize the frame config (as required by the cgif library).
    var frame_config: cgif.CGIF_FrameConfig = undefined;
    initFrameConfig(&frame_config);
    frame_config.genFlags = cgif.CGIF_FRAME_GEN_USE_TRANSPARENCY | cgif.CGIF_FRAME_GEN_USE_DIFF_WINDOW;

    var gif: *cgif.CGIF = cgif.cgif_newgif(&gif_config) orelse {
        return FrametapError.GifConvertFailed;
    };

    gif = gif; // supress bad zls error in my IDE :(

    if (config.use_global_palette) {
        try encodeGifWithGlobalPalette(allocator, frames, gif, &gif_config, &frame_config);
    } else {
        gif_config.attrFlags |= @intCast(cgif.CGIF_ATTR_NO_GLOBAL_TABLE);
        frame_config.attrFlags |= @intCast(cgif.CGIF_FRAME_ATTR_USE_LOCAL_TABLE);
        try encodeGifWithLocalPalette(allocator, frames, gif, &frame_config);
    }
}
