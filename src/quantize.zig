const std = @import("std");
const core = @import("core");

// Implements the color quantization algorithm described here:
// https://dl.acm.org/doi/pdf/10.1145/965145.801294
// Color Image Quantization for frame buffer display.
// Paul Heckbert, Computer Graphics lab, New York Institute of Technology.

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

// The color array maps a color index to a "Color" object that contains:
// 1. The RGB value of the color and its frequency in the original image.
// We use 5 bits per color channel, so we can represent 32 levels of each color.
const color_array_size = (2 ** 5) ** 3; // 32768

const QuantizedColor = struct {
    /// RGB color value.
    RGB: [3]u8,
    /// Frequency of the color in the original image.
    frequency: usize,
    /// Index into the color subdivion array.
    new_index: u8,
    /// Next color in the linked list.
    next: ?*QuantizedColor,
};

/// A subdivison of the color space produced by the median cut algorithm.
const ColorSpace = struct {
    /// The color channel in this partition with the highest range
    widest_channel: Channel,
    // width of the widest channel in this partition.
    rgb_width: usize,
    /// The minimum values of the respective RGB channels in this partition.
    rgb_min: [3]i32,
    /// The maximum values of the respective RGB channels in this partition.
    rgb_max: [3]i32,
    /// linked list of colors in this partition.
    colors: *QuantizedColor,
    /// number of colors in the linked list
    num_colors: usize,
    /// Number of pixels that this partition accounts for.
    num_pixels: usize,
};

const Channel = enum(u5) { Red = 0, Blue = 1, Green = 2 };

/// A function that compares two pixels based on a color channel.
fn colorLessThan(channel: Channel, a: *QuantizedColor, b: *QuantizedColor) bool {
    const a_color = a.RGB[@intFromEnum(channel)];
    const b_color = b.RGB[@intFromEnum(channel)];
    return a_color < b_color;
}

test "pixel comparison function" {
    var a: QuantizedColor = undefined;
    var b: QuantizedColor = undefined;

    a.RGB = [3]u8{ 0, 1, 1 };
    b.RGB = [3]u8{ 1, 1, 0 };

    try std.testing.expectEqual(true, colorLessThan(Channel.Red, &a, &b));
    try std.testing.expectEqual(false, colorLessThan(Channel.Green, &a, &b));
    try std.testing.expectEqual(false, colorLessThan(Channel.Blue, &a, &b));
}

const Pixel = packed struct {
    r: u8,
    g: u8,
    b: u8,
    _: u8 = undefined, // padding to fit in u32
    comptime {
        std.debug.assert(@sizeOf(Pixel) == @sizeOf(u32));
    }
};

fn colorFromRGB(r: u8, g: u8, b: u8) QuantizedColor {
    return QuantizedColor{
        .RGB = [3]u8{ r, g, b },
        .frequency = 0,
        .new_index = 0,
        .next = null,
    };
}

test "sorting pixels by color channel" {
    var a = colorFromRGB(15, 50, 20);
    var b = colorFromRGB(19, 40, 40);
    var c = colorFromRGB(13, 30, 50);
    var d = colorFromRGB(200, 100, 60);
    var e = colorFromRGB(5, 20, 10);

    var input = [_]*QuantizedColor{ &a, &b, &c, &d, &e };
    const want = [_]*QuantizedColor{ &e, &c, &a, &b, &d };

    std.sort.heap(*QuantizedColor, &input, Channel.Red, colorLessThan);
    for (0..input.len) |i| {
        try std.testing.expectEqual(want[i].RGB, input[i].RGB);
    }
}

const bits_per_prim_color = 5;
const max_prim_color = (2 ** bits_per_prim_color) - 1;
const shift = 8 - bits_per_prim_color;

const RGB5 = struct {
    b: u5,
    g: u5,
    r: u5,
    _: std.builtin.Type.Int(@sizeOf(usize) - 3 * @sizeOf(u5)),
    comptime {
        std.debug.assert(@sizeOf(RGB5) == @sizeOf(usize));
    }
};

pub fn quantize(allocator: std.mem.Allocator, rgb_buf: []u8) !QuantizeResult {
    const n_pixels = rgb_buf.len / 3;
    std.debug.assert(rgb_buf.len % 3 == 0);

    // Initiale the color array table with all possible colors in the R5G5B5 space.
    const all_colors = try allocator.alloc(QuantizedColor, color_array_size);
    for (0.., all_colors) |i, *color| {
        color.frequency = 0;
        // The RGB values are a color stored in the lower 15 bits of its index
        // 0x--(RRRRR)(GGGGG)(BBBBB)
        color.RGB[0] = i >> (2 * bits_per_prim_color); // R: upper 5 bits
        color.RGB[1] = (i >> bits_per_prim_color) & max_prim_color; // G: middle 5 bits
        color.RGB[2] = i & max_prim_color; // B: lower 5 bits.
        color.new_index = i;
    }

    // Sample all colors in the image, and count their frequency.
    for (0..n_pixels) |i| {
        const base = i * 3;

        const r = rgb_buf[base];
        const g = rgb_buf[base + 1];
        const b = rgb_buf[base + 2];

        const r_mask = @as(usize, r >> shift) << (2 * bits_per_prim_color);
        const g_mask = @as(usize, g >> shift) << bits_per_prim_color;
        const b_mask = @as(usize, b >> shift);

        const index = r_mask | g_mask | b_mask;
        all_colors[index].frequency += 1;
        all_colors[index].RGB[0] = r;
        all_colors[index].RGB[1] = g;
        all_colors[index].RGB[2] = b;
    }

    // Find all colors in the color table that are used at least once, and chain them.
    var head: *QuantizedColor = null;
    for (all_colors) |*color| {
        if (color.frequency > 0) {
            head = color;
            break;
        }
    }
    std.debug.assert(head != null);

    var qcolor = head;
    var color_count: usize = 0;
    // minimum/maximum values of R,G, and B in this partition respectively
    for (all_colors) |*color| {
        if (color.frequency > 0) {
            qcolor.next = color;
            qcolor = color;
            color_count += 1;
        }
    }
    qcolor.next = null;

    const partitions = try allocator.alloc(ColorSpace, 2 ** 3);
    defer allocator.free(partitions);
    for (partitions) |*partition| {
        partition.colors = null;
        partition.num_colors = 0;
    }

    var first_partition = &partitions[0];
    first_partition.head = head;
    first_partition.num_colors = color_count;
    first_partition.widest_channel = findWidestChannel(head);
    first_partition.num_pixels = n_pixels;
    try medianCut(allocator, all_colors, &partitions[0], 3);
}

/// Find the color channel with the largest range in the given parition.
/// Mutates `rgb_min`, `rgb_max`, `rgb_width`, and `widest_channel`.
fn findWidestChannel(partition: *ColorSpace) void {
    var min = [3]i32{ 255, 255, 255 };
    var max = [3]i32{ 0, 0, 0 };

    var color: ?*QuantizedColor = partition.colors;
    for (0..partition.num_colors) |_| {
        std.debug.assert(color != null);
        const color_ptr = if (color) |c| c else unreachable;
        for (0..3) |i| {
            min[i] = @min(color_ptr.RGB[i], min[i]);
            max[i] = @max(color_ptr.RGB[i], max[i]);
        }
        color = color_ptr.next;
    }

    partition.rgb_min = min;
    partition.rgb_max = max;

    const rgb_ranges = [3]i32{ max[0] - min[0], max[1] - min[1], max[2] - min[2] };
    if (rgb_ranges[0] > rgb_ranges[1] and rgb_ranges[0] > rgb_ranges[2]) {
        partition.widest_channel = Channel.Red;
        partition.rgb_width = @intCast(rgb_ranges[0]);
        return;
    }

    if (rgb_ranges[1] > rgb_ranges[0] and rgb_ranges[1] > rgb_ranges[2]) {
        partition.widest_channel = Channel.Green;
        partition.rgb_width = @intCast(rgb_ranges[1]);
        return;
    }

    partition.widest_channel = Channel.Blue;
    partition.rgb_width = @intCast(rgb_ranges[2]);
}

test "findWidestChannel" {
    var yellow = QuantizedColor{
        .RGB = [3]u8{ 255, 255, 0 },
        .frequency = 0,
        .new_index = 0,
        .next = null,
    };

    var purple = QuantizedColor{
        .RGB = [3]u8{ 250, 0, 250 },
        .frequency = 0,
        .new_index = 0,
        .next = &yellow,
    };

    var colorspace = ColorSpace{
        .widest_channel = undefined,
        .rgb_width = undefined,
        .rgb_min = undefined,
        .rgb_max = undefined,
        .colors = &purple,
        .num_colors = 2,
        .num_pixels = 0,
    };
    findWidestChannel(&colorspace);
    try std.testing.expect(std.mem.eql(i32, &colorspace.rgb_min, &[3]i32{ 250, 0, 0 }));
    try std.testing.expect(std.mem.eql(i32, &colorspace.rgb_max, &[3]i32{ 255, 255, 250 }));
    try std.testing.expectEqual(.Green, colorspace.widest_channel);
}

fn medianCut(allocator: std.mem.Allocator, first_partition: *ColorSpace, depth: u3) !void {
    const total_partitions = 2 ** depth;

    var parts = try allocator.alloc(*ColorSpace, total_partitions);
    parts[0] = first_partition;

    var n_partitions = 1; // we're starting with 1 large partition.
    while (n_partitions != total_partitions) : (n_partitions += 1) {
        // Look for the partition that has the largest variance in RGB width.
        // Then split that into two halves.
        var max_size = 0;
        var split_index = parts.len + 1;
        var found = false;
        for (0..n_partitions) |i| {
            const partition = parts[i];
            if (max_size < partition.rgb_width and partition.num_colors > 1) {
                max_size = partition.rgb_width;
                split_index = i;
                found = true;
            }
        }

        if (!found) {
            break;
        }

        // We found the partition that varies the most in either of the 3 color channels.
        const partition = parts[split_index];
        const sort_channel = partition.widest_channel;

        // Create an array with all the colors in the partition, then sort it by the widest channel.
        var sorted_colors = try allocator.alloc(*QuantizedColor, partition.num_colors);
        defer allocator.free(sorted_colors);

        // Copy all the colors in this partition into the array for sorting.
        var color = partition.colors;
        var j = 0;
        while (color != null and j < sorted_colors.len) : (color = color.next) {
            sorted_colors[j] = &color;
            j += 1;
        }

        // Sort the colors!
        std.sort.heap(
            *QuantizedColor,
            sorted_colors,
            sort_channel,
            colorLessThan,
        );

        // Re-link the sorted colors in their new order.
        for (0..sorted_colors.len - 1) |i| {
            sorted_colors[i].next = sorted_colors[i + 1];
        }
        sorted_colors[sorted_colors.len - 1].next = null;

        // The first half of the sorted array will remain in the current partition.
        partition.colors = sorted_colors[0];

        // Create a new partition. We will populate this struct below.
        const new_partition = try allocator.create(ColorSpace);
        parts[n_partitions] = new_partition;

        // Next, we find the *median* color in the sorted list of colors.
        // NOTE: The median is NOT the middle element.
        // Rather, its the element that divides the array such that both halves
        // have roughly the same pixel-frequency.
        // AKA sum([color.frequency for color in left]) =  sum(color.frequency for color in right).
        color = partition.colors;
        const target_pixel_count = partition.num_pixels / 2;
        var remaining_pixel_count = 0; // # of pixels that will remain in the current partition.
        var remaining_color_count = 0; // # of colors that will remain in the current partition.
        while (color.next != null) : (color = color.next) {
            remaining_color_count += 1;
            remaining_pixel_count += color.frequency;
            if (remaining_pixel_count >= target_pixel_count) break;
        }

        // ounding box for the new partition.
        new_partition.rgb_min = partition.rgb_max;

        // Set up the new partition
        new_partition.colors = color.next;
        new_partition.num_pixels = partition.num_pixels - remaining_pixel_count;
        new_partition.num_colors = partition.num_colors - remaining_color_count;

        partition.num_colors = remaining_color_count;
        partition.num_pixels = remaining_pixel_count;

        color.next = null;

        std.debug.assert(partition.num_pixels == countPixels(partition, partition.num_colors));
        std.debug.assert(new_partition.num_pixels == countPixels(new_partition, new_partition.num_colors));

        // Update the bounding box of the current partition.

    }
}

fn countPixels(partition: *ColorSpace, ncolors: usize) usize {
    var count = 0;
    var color = partition.colors;
    for (0..ncolors) |_| {
        std.debug.assert(color != null);
        count += color.frequency;
        color = color.next;
    }
    return count;
}
