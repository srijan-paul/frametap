const quantize = @import("quantize.zig");
const std = @import("std");
const QuantizedColor = quantize.QuantizedColor;

pub const QuantizedBuf = struct {
    color_table: []const u8,
    quantized_buf: []u8,
};

pub fn ditherBgraImage(
    allocator: std.mem.Allocator,
    image: []const u8,
    quantized: QuantizedBuf,
    width: usize,
    all_colors: *const [quantize.color_array_size]QuantizedColor,
) !void {
    // create a copy of the image to avoid modifying the original.
    const bgra_buf = try allocator.alloc(u8, image.len);
    defer allocator.free(bgra_buf);
    @memcpy(bgra_buf, image);

    const quantized_img = quantized.quantized_buf;
    const npixels = image.len / 4;
    for (0..npixels) |i| {
        const px_index = i * 4;

        const row: i64 = @intCast(px_index / width);
        const col: i64 = @intCast(px_index % width);

        const dither_factors = [_]struct { i64, f64 }{
            .{ rowColToIndex(row, col + 1, width), 7 / 16 },
            .{ rowColToIndex(row + 1, col - 1, width), 3 / 16 },
            .{ rowColToIndex(row + 1, col, width), 5 / 16 },
            .{ rowColToIndex(row + 1, col + 1, width), 1 / 16 },
        };

        // First, update the color of this pixel in the quantized buffer.
        const global_index_of_color = quantize.rgbToGlobalIndex(
            bgra_buf[px_index + 2], // r
            bgra_buf[px_index + 1], // g
            bgra_buf[px_index + 0], // b
        );
        const color = all_colors[global_index_of_color];
        // std.debug.print(
        //     "pixel#{d}: color-{d} ({d}, {d}, {d})\n",
        //     .{ i, color.new_index, color.RGB[0], color.RGB[1], color.RGB[2] },
        // );
        quantized_img[i] = color.new_index;

        const err = quantizationError(bgra_buf, &quantized, i);

        // diffuse (spread) the error in this pixel to its neighbors.
        for (dither_factors) |d| {
            const index = d[0];
            const factor = d[1];

            if (index < 0 or index >= npixels) {
                continue;
            }

            // Get the RGB color of the neighboring pixel.
            const base: usize = @intCast(index * 4);
            const b: f64 = @floatFromInt(bgra_buf[base]);
            const g: f64 = @floatFromInt(bgra_buf[base + 1]);
            const r: f64 = @floatFromInt(bgra_buf[base + 2]);

            // compute its new RGB values after error diffusion.
            const new_r = adjustQuantizationError(err[0], r, factor);
            const new_g = adjustQuantizationError(err[1], g, factor);
            const new_b = adjustQuantizationError(err[2], b, factor);

            // Update the pixel with new RGB values.
            bgra_buf[base] = @truncate(new_b);
            bgra_buf[base + 1] = @truncate(new_g);
            bgra_buf[base + 2] = @truncate(new_r);
        }
    }
}

inline fn adjustQuantizationError(err: f64, value: f64, factor: f64) u8 {
    var new_color: i64 = @intFromFloat(@round(value + err * factor));
    new_color = @max(0, @min(255, new_color));
    return @intCast(new_color);
}

inline fn quantizationError(
    bgra_image: []const u8,
    quantized: *const QuantizedBuf,
    i: usize,
) [3]f64 {
    const r: f64 = @floatFromInt(bgra_image[i * 4 + 2]);
    const g: f64 = @floatFromInt(bgra_image[i * 4 + 1]);
    const b: f64 = @floatFromInt(bgra_image[i * 4 + 0]);

    const qcolor_table = quantized.color_table;
    const q_image = quantized.quantized_buf;

    const j: usize = q_image[i];
    const qr: f64 = @floatFromInt(qcolor_table[j]);
    const qg: f64 = @floatFromInt(qcolor_table[j + 1]);
    const qb: f64 = @floatFromInt(qcolor_table[j + 2]);

    const err = .{ r - qr, g - qg, b - qb };
    return err;
}

inline fn rowColToIndex(row: i64, col: i64, width: usize) i64 {
    return row * @as(i64, @intCast(width)) + col;
}

const t = std.testing;
test "quantize and dither" {
    const allocator = t.allocator;

    // input is a 2x2 grayscale image.
    const in = [_]u8{
        60, 60, 60, 255, // (0, 0)
        60, 60, 60, 255, // (0, 1)
        0, 0, 0, 255, // (1, 0)
        0, 0, 0, 255, // (1, 1)
    };
    // prepare a mock quantization result.
    var all_colors: [quantize.color_array_size]QuantizedColor = undefined;
    for (0.., &all_colors) |i, *color| {
        color.frequency = 0;
        color.new_index = 0;
        const r = (i >> 10) & 0b11111;
        const g = (i >> 5) & 0b11111;
        const b = i & 0b11111;
        // The RGB values are packed in the lower 15 bits of its index
        // 0x--(RRRRR)(GGGGG)(BBBBB)
        color.RGB[0] = @truncate(r); // R: upper 5 bits
        color.RGB[1] = @truncate(g); // G: middle 5 bits
        color.RGB[2] = @truncate(b); // B: lower 5 bits.

        const grey_value: i64 = @intCast((r + g + b) / 3);
        const d100 = @abs(grey_value - 100);
        const d0 = @abs(grey_value - 0);
        color.new_index = if (d0 < d100) 0 else 1;
    }

    const color_table = [_]u8{
        0,   0,   0,
        100, 100, 100,
    };

    var out = [_]u8{ 1, 1, 0, 0 };
    try ditherBgraImage(
        allocator,
        &in,
        .{ .quantized_buf = &out, .color_table = &color_table },
        2,
        &all_colors,
    );

    try t.expectEqualDeep([_]u8{ 1, 0, 0, 0 }, out);
}
