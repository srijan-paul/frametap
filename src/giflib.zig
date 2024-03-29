// A Zig wrapper for the GIFLIB project.
// Only supports the functionality needed by this this project.

const std = @import("std");
const gifc = @cImport(@cInclude("giflib.h"));
const JifError = @import("./core.zig").JifError;

const byte = gifc.GifByteType;
const GifFile = gifc.GifFileType;
const ColorMapObject = gifc.ColorMapObject;

pub const RGBFrame = struct { []byte, []byte, []byte };
pub const FrameData = struct {
    frames: []RGBFrame,
    width: usize,
    height: usize,
};

fn bgra_to_rgb(
    bgra_buf: [*c]u8,
    frame: RGBFrame,
    size: usize,
) !void {
    const red = frame[0];
    const blue = frame[1];
    const green = frame[2];

    var i: u32 = 0;
    while (i < size) : (i += 4) {
        const b = bgra_buf[4 * i];
        const g = bgra_buf[4 * i + 1];
        const r = bgra_buf[4 * i + 2];
        red[i] = r;
        blue[i] = b;
        green[i] = g;
    }
}

pub fn bgra_frames_to_gif(
    allocator: std.mem.Allocator,
    dst_file: [:0]u8,
    frames: [][]u8,
    width: usize,
    height: usize,
) !void {
    var err: c_int = 0;
    const giffile = gifc.EGifOpenFileName(dst_file, false, &err);
    if (giffile == null) {
        // TODO: handle
    }

    gifc.EGifSetGifVersion(giffile, true);

    const frame_size = width * height;
    const frame = RGBFrame{
        try allocator.alloc(byte, frame_size),
        try allocator.alloc(byte, frame_size),
        try allocator.alloc(byte, frame_size),
    };

    for (0.., frames) |i, bgra_frame| {
        try bgra_to_rgb(
            allocator,
            bgra_frame,
            frame,
            frame_size,
        );

        const colormap = gifc.GifMakeMapObject(256, null);
        if (gifc.GifQuantizeBuffer(
            width,
            height,
            colormap.color_count,
            frame.rbuf,
            frame.gbuf,
            frame.bbuf,
            giffile.SColorMap.Colors,
        ) == gifc.GIF_ERROR) {
            return JifError.GifQuantizeFailed;
        }

        if (gifc.EGifPutImageDesc(
            giffile,
            0,
            0,
            width,
            height,
            false,
            colormap,
        ) == gifc.GIF_ERROR) {
            return JifError.GifConvertFailed;
        }

        for (0..height) |y| {
            if (gifc.EGifPutLine(
                giffile,
                giffile.SavedImages[i].RasterBits[y * width],
                width,
            ) == gifc.GIF_ERROR) {
                return JifError.GifWriteLineFailed;
            }
        }

        gifc.GifFreeMapObject(colormap);
    }
}
