const std = @import("std");
const png = @cImport(@cInclude("lodepng.h"));
const setjmp = @cImport(@cInclude("setjmp.h"));
const core = @import("core.zig");
const cstdlib = @cImport(@cInclude("stdlib.h"));

const JifError = core.JifError;

pub fn writeRgbaToPng(
    buf: []u8,
    width: usize,
    height: usize,
    file_path: []const u8,
) !void {
    var state: png.LodePNGState = undefined;
    png.lodepng_state_init(&state);
    defer png.lodepng_state_cleanup(&state);

    var pngsize: usize = undefined;
    var pngbuf: [*c]u8 = undefined;

    const err = png.lodepng_encode(
        &pngbuf,
        &pngsize,
        buf.ptr,
        @intCast(width),
        @intCast(height),
        &state,
    );

    if (err != 0) {
        return JifError.PNGConvertFailed;
    }

    defer cstdlib.free(pngbuf);

    // if (png.lodepng_save_file(pngbuf, pngsize, file_path.ptr) != 0) {
    //     return JifError.PNGConvertFailed;
    // }

    const pngdata = pngbuf[0..pngsize];
    std.fs.cwd().writeFile(file_path, pngdata) catch {
        return JifError.PNGConvertFailed;
    };
}
