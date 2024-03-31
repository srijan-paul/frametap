const std = @import("std");

pub const QuantizeResult = struct {
    const Self = @This();
    /// RGBRGBRGB...
    color_table: []u8,
    /// indices into the color table
    image_buffer: []u8,

    pub fn init(color_table: []u8, image_buffer: []u8) Self {
        return .{ .color_table = color_table, .image_buffer = image_buffer };
    }

    pub fn deinit(self: *const Self, allocator: std.mem.Allocator) void {
        allocator.free(self.color_table);
        allocator.free(self.image_buffer);
    }
};

pub fn quantize(allocator: std.mem.Allocator, rgb_buf: []u8) !QuantizeResult {
    const n_pixels = rgb_buf.len / 3;
    std.debug.assert(rgb_buf.len % 3 == 0);

    const color_table = try allocator.alloc(u8, 256 * 3);
    const image_buffer = try allocator.alloc(u8, n_pixels);

    for (0..256) |i| {
        color_table[i] = 200;
        color_table[i + 1] = 200;
        color_table[i + 2] = 100;
    }

    for (0..image_buffer.len) |i| {
        image_buffer[i] = 1;
    }

    return QuantizeResult.init(color_table, image_buffer);
}
