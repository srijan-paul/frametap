const std = @import("std");
const png = @cImport(@cInclude("lodepng.h"));
const setjmp = @cImport(@cInclude("setjmp.h"));
const core = @import("core.zig");
const cstdlib = @cImport(@cInclude("stdlib.h"));

const JifError = core.JifError;

pub fn writeBgraAsPng(
    allocator: std.mem.Allocator,
    buf: []u8,
    width: c_uint,
    height: c_uint,
    dst_dir: []const u8,
    frame_number: usize,
) !void {
    const file_name = try std.fmt.allocPrintZ(
        allocator,
        "frame_{d}.png",
        .{frame_number},
    );
    defer allocator.free(file_name);

    std.fs.cwd().access(dst_dir, .{ .mode = .read_write }) catch {
        try std.fs.cwd().makeDir(dst_dir);
    };

    const parts = [_][]const u8{ dst_dir, file_name };
    const file_path = try std.fs.path.join(allocator, &parts);
    defer allocator.free(file_path);

    // convert bgra to rgba
    for (0..width * height) |i| {
        const base = i * 4;
        const b = buf[base];
        const g = buf[base + 1];
        const r = buf[base + 2];
        const a = buf[base + 3];

        buf[base] = r;
        buf[base + 1] = g;
        buf[base + 2] = b;
        buf[base + 3] = a;
    }

    var state: png.LodePNGState = undefined;
    png.lodepng_state_init(&state);
    defer png.lodepng_state_cleanup(&state);

    var pngsize: usize = undefined;
    var pngbuf: [*c]u8 = undefined;

    const err = png.lodepng_encode(
        &pngbuf,
        &pngsize,
        buf.ptr,
        width,
        height,
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

pub fn writeBGRAFramesAsPNG(
    allocator: std.mem.Allocator,
    frames: [][]u8,
    width: c_uint,
    height: c_uint,
) !void {
    const dst_dir = "frames";

    for (0.., frames) |i, frame| {
        try writeBgraAsPng(
            allocator,
            frame,
            width,
            height,
            dst_dir,
            i,
        );
    }
}
