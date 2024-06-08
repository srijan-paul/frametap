const quantize = @import("quantize.zig");
const std = @import("std");
const QuantizedColor = quantize.QuantizedColor;

pub const QuantizedBuf = struct {
    color_table: []const u8,
    quantized_buf: []u8,
};

const ErrDiffusion = struct {
    offset: [2]i64,
    factor: f64,
};

const floyd_steinberg = [_]ErrDiffusion{
    .{ .offset = .{ 1, 0 }, .factor = 7.0 / 16.0 },
    .{ .offset = .{ -1, 1 }, .factor = 3.0 / 16.0 },
    .{ .offset = .{ 0, 1 }, .factor = 5.0 / 16.0 },
    .{ .offset = .{ 1, 1 }, .factor = 1.0 / 16.0 },
};

pub fn ditherBgraImage(
    allocator: std.mem.Allocator,
    image: []const u8,
    quantized: QuantizedBuf,
    width: usize,
    height: usize,
    all_colors: *const [quantize.color_array_size]QuantizedColor,
) !void {
    // create a copy of the image to avoid modifying the original.
    const bgra = try allocator.alloc(u8, image.len);
    defer allocator.free(bgra);

    @memcpy(bgra, image);

    const quantized_buf = quantized.quantized_buf;

    for (0..height) |row| {
        for (0..width) |col| {
            const i = row * width + col;
            // 1. replace the pixel with the closest color.
            const global_color_index = quantize.rgbToGlobalIndex(
                bgra[i * 4 + 2], // r
                bgra[i * 4 + 1], // g
                bgra[i * 4 + 0], // b
            );
            const newindex = all_colors[global_color_index].new_index;
            quantized_buf[i] = newindex;

            // 2. Find the quantization error for this pixel.
            const err = quantizationError(bgra, &quantized, i);

            // 3. Diffuse (spread) the error to the neighboring pixels.
            for (floyd_steinberg) |diff| {
                const offset = diff.offset;
                const next_row_ = @as(i64, @intCast(row)) + offset[0];
                const next_col_ = @as(i64, @intCast(col)) + offset[1];

                if (next_row_ < 0 or next_row_ >= height or next_col_ < 0 or next_col_ >= width) {
                    continue;
                }

                const factor = diff.factor;

                const next_row: usize = @intCast(next_row_);
                const next_col: usize = @intCast(next_col_);
                const j = next_row * width + next_col;

                const old_b = bgra[j * 4 + 0];
                const old_g = bgra[j * 4 + 1];
                const old_r = bgra[j * 4 + 2];

                const new_r = addError(old_r, err[0], factor);
                const new_g = addError(old_g, err[1], factor);
                const new_b = addError(old_b, err[2], factor);

                bgra[j * 4 + 0] = new_b;
                bgra[j * 4 + 1] = new_g;
                bgra[j * 4 + 2] = new_r;
            }
        }
    }
}

/// Adds the quantization error to the color value and returns the new color.
inline fn addError(color: usize, err: f64, multiplier: f64) u8 {
    const color_f: f64 = @floatFromInt(color);
    const new_color = @round(color_f + err * multiplier);
    return @intFromFloat(@max(
        0,
        @min(new_color, 255),
    ));
}

inline fn quantizationError(
    bgra: []const u8,
    quantized: *const QuantizedBuf,
    i: usize,
) [3]f64 {
    const b: f64 = @floatFromInt(bgra[i * 4 + 0]);
    const g: f64 = @floatFromInt(bgra[i * 4 + 1]);
    const r: f64 = @floatFromInt(bgra[i * 4 + 2]);

    const qcolor_table = quantized.color_table;
    const q_image = quantized.quantized_buf;

    const index_in_ct: usize = q_image[i];
    const qr: f64 = @floatFromInt(qcolor_table[index_in_ct * 3]);
    const qg: f64 = @floatFromInt(qcolor_table[index_in_ct * 3 + 1]);
    const qb: f64 = @floatFromInt(qcolor_table[index_in_ct * 3 + 2]);

    return .{ r - qr, g - qg, b - qb };
}

inline fn rowColToIndex(row: i64, col: i64, width: usize, height: usize) i64 {
    if (row < 0 or row >= height or col < 0 or col >= width) {
        return -1;
    }
    return (row * @as(i64, @intCast(width)) + col);
}

const t = std.testing;
test "quantize and dither" {
    const allocator = t.allocator;

    // input is a 2x2 grayscale image.
    const bgra = [_]u8{
        60, 60, 60, 255, // (0, 0)
        60, 60, 60, 255, // (0, 1)
        0, 0, 0, 255, // (1, 0)
        0, 0, 0, 255, // (1, 1)
    };
    // prepare a mock quantization result.
    var all_colors: [quantize.color_array_size]QuantizedColor = undefined;
    for (0.., &all_colors) |i, *color| {
        // The RGB values are packed in the lower 15 bits of its index
        // 0x--(RRRRR)(GGGGG)(BBBBB)
        var r = (i >> 10) & 0b111_11;
        var g = (i >> 5) & 0b111_11;
        var b = i & 0b111_11;

        r <<= 3;
        g <<= 3;
        b <<= 3;

        const grey_value: i64 = @intCast((r + g + b) / 3);
        const d100 = @abs(grey_value - 100);
        const d0 = @abs(grey_value - 0);
        color.new_index = if (d0 < d100) 0 else 1;

        if (color.new_index == 0) {
            r = 0;
            g = 0;
            b = 0;
        } else {
            r = 100;
            g = 100;
            b = 100;
        }

        color.RGB = .{ @intCast(r), @intCast(g), @intCast(b) };
    }

    const color_table = [_]u8{
        0,   0,   0,
        100, 100, 100,
    };

    std.debug.print("\n", .{});

    var quantized = [_]u8{ 1, 1, 0, 0 };
    try ditherBgraImage(
        allocator,
        &bgra,
        .{ .quantized_buf = &quantized, .color_table = &color_table },
        2,
        2,
        &all_colors,
    );

    try t.expectEqualDeep([_]u8{ 1, 0, 0, 0 }, quantized);
}
