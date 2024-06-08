const std = @import("std");
const dither = @import("dither.zig");

// Implements the color quantization algorithm described here:
// https://dl.acm.org/doi/pdf/10.1145/965145.801294
// Color Image Quantization for frame buffer display.
// Paul Heckbert, Computer Graphics lab, New York Institute of Technology.
//
// Used this as reference: https://github.com/mirrorer/giflib/blob/master/lib/quantize.c

/// A single RGB image represented as a list of indices
/// into a color table.
pub const QuantizedImage = struct {
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

/// A list of frames that are represented as arrays of indices into
/// a common global color table.
pub const QuantizedFrames = struct {
    const Self = @This();
    /// RGBRGBRGB... * 256
    color_table: []u8,
    /// A list of frames where each frame is a
    /// list of indices into the color table.
    frames: [][]u8,

    /// The allocator used to allocate the color table and the frames.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, table: []u8, frames: [][]u8) !Self {
        return Self{
            .allocator = allocator,
            .color_table = table,
            .frames = frames,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.allocator.free(self.color_table);
        for (self.frames) |frame| {
            self.allocator.free(frame);
        }
        self.allocator.free(self.frames);
    }
};

// The color array maps a color index to a "Color" object that contains:
// the RGB value of the color and its frequency in the original image.
// We use 5 bits per color channel, so we can represent 32 levels of each color.
pub const color_array_size: comptime_int = 32768; // (2 ^ 5) ^ 3

pub const QuantizedColor = struct {
    /// RGB color value.
    RGB: [3]u8,
    /// Frequency of the color in the original image.
    frequency: usize,
    /// Index into the color-space partitions array.
    new_index: u8,
    /// Next color in the linked list.
    next: ?*QuantizedColor,
};

/// A subdivison of the color space produced by the median cut algorithm.
const ColorSpace = struct {
    const Self = @This();

    /// The color channel in this partition with the highest range
    widest_channel: Channel,
    // width of the widest channel in this partition.
    rgb_width: i32,
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
    const sort_channel: usize = @intFromEnum(channel);

    const a_hash = @as(usize, a.RGB[sort_channel]) * 256 * 256 +
        @as(usize, a.RGB[(sort_channel + 1) % 3]) * 256 +
        @as(usize, a.RGB[(sort_channel + 2) % 3]);

    const b_hash = @as(usize, b.RGB[sort_channel]) * 256 * 256 +
        @as(usize, b.RGB[(sort_channel + 1) % 3]) * 256 +
        @as(usize, b.RGB[(sort_channel + 2) % 3]);

    return a_hash < b_hash;
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
        try std.testing.expectEqual(want[i], input[i]);
    }
}

const bits_per_prim_color = 5; // 5 bits per color channel.
const max_prim_color = 0b11111;
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

/// Convert an RGB color to an index in the global color array table
/// which contains all colors in the R5G5B5 space.
pub inline fn rgbToGlobalIndex(r: usize, g: usize, b: usize) usize {
    const r_mask = (r >> shift) << (2 * bits_per_prim_color);
    const g_mask = (g >> shift) << bits_per_prim_color;
    const b_mask = b >> shift;
    return r_mask | g_mask | b_mask;
}

/// Quantize a list of raw BGRA frames such that all frames share the same global color table.
pub fn quantizeBgraFrames(
    allocator: std.mem.Allocator,
    bgra_bufs: []const []const u8,
    width: usize,
    use_dithering: bool,
) !QuantizedFrames {
    // Initialize the color array table with all possible colors in the R5G5B5 space.
    var all_colors: [color_array_size]QuantizedColor = undefined;

    for (0.., &all_colors) |i, *color| {
        color.frequency = 0;
        color.new_index = 0;
        // The RGB values are packed in the lower 15 bits of its index
        // 0x--(RRRRR)(GGGGG)(BBBBB)
        color.RGB[0] = @truncate(i >> (2 * bits_per_prim_color)); // R: upper 5 bits
        color.RGB[1] = @truncate((i >> bits_per_prim_color) & max_prim_color); // G: middle 5 bits
        color.RGB[2] = @truncate(i & max_prim_color); // B: lower 5 bits.
    }

    // 1. Prepare a frequency histogram of all colors in the clip.
    for (bgra_bufs) |buf| {
        const npixels = buf.len / 4;
        for (0..npixels) |i| {
            const base = i * 4;
            const b = buf[base];
            const g = buf[base + 1];
            const r = buf[base + 2];

            const index = rgbToGlobalIndex(r, g, b);
            all_colors[index].frequency += 1;
        }
    }

    // 2. Quantize the histogram to 256 colors.
    const total_px_count = bgra_bufs.len * bgra_bufs[0].len / 4;
    const color_table = try quantizeHistogram(allocator, &all_colors, total_px_count);

    // 3. Go over each frame in the input, and replace every pixel with an index into
    // the color table.
    const quantized_frames = try allocator.alloc([]u8, bgra_bufs.len);
    for (0.., bgra_bufs) |i, bgra_frame| {
        const npixels = bgra_frame.len / 4;
        const quantized_frame = try allocator.alloc(u8, npixels);

        for (0..npixels) |j| {
            const b = bgra_frame[j * 4];
            const g = bgra_frame[j * 4 + 1];
            const r = bgra_frame[j * 4 + 2];

            const index = rgbToGlobalIndex(r, g, b);
            quantized_frame[j] = all_colors[index].new_index;
        }

        if (use_dithering) {
            try dither.ditherBgraImage(
                allocator,
                bgra_frame,
                .{ .quantized_buf = quantized_frame, .color_table = color_table },
                width,
                &all_colors,
            );
        }

        quantized_frames[i] = quantized_frame;
    }

    return QuantizedFrames.init(allocator, color_table, quantized_frames);
}

/// Given a buffer of RGB pixels, quantize the colors in the image to 256 colors.
pub fn quantizeBgraImage(
    allocator: std.mem.Allocator,
    image: []u8,
    width: usize,
    use_dithering: bool,
) !QuantizedImage {
    const n_pixels = image.len / 4;
    std.debug.assert(image.len % 4 == 0);

    // Initialize the color array table with all possible colors in the R5G5B5 space.
    var all_colors: [color_array_size]QuantizedColor = undefined;
    for (0.., &all_colors) |i, *color| {
        color.frequency = 0;
        color.new_index = 0;
        // The RGB values are packed in the lower 15 bits of its index
        // 0x--(RRRRR)(GGGGG)(BBBBB)
        color.RGB[0] = @truncate(i >> (2 * bits_per_prim_color)); // R: upper 5 bits
        color.RGB[1] = @truncate((i >> bits_per_prim_color) & max_prim_color); // G: middle 5 bits
        color.RGB[2] = @truncate(i & max_prim_color); // B: lower 5 bits.
    }

    // Sample all colors in the image, and count their frequency.
    for (0..n_pixels) |i| {
        const base = i * 4;

        const b = image[base];
        const g = image[base + 1];
        const r = image[base + 2];

        const r_mask = @as(usize, r >> shift) << (2 * bits_per_prim_color);
        const g_mask = @as(usize, g >> shift) << bits_per_prim_color;
        const b_mask = @as(usize, b >> shift);

        const index = r_mask | g_mask | b_mask;
        all_colors[index].frequency += 1;
    }

    const color_table = try quantizeHistogram(allocator, &all_colors, n_pixels);

    // Now go over the input image, and replace each pixel with the index of the partition
    var image_buf = try allocator.alloc(u8, n_pixels);
    for (0..n_pixels) |i| {
        const b = image[i * 4];
        const g = image[i * 4 + 1];
        const r = image[i * 4 + 2];

        const r_mask = @as(usize, r >> shift) << (2 * bits_per_prim_color);
        const g_mask = @as(usize, g >> shift) << bits_per_prim_color;
        const b_mask = @as(usize, b >> shift);
        const index: usize = r_mask | g_mask | b_mask;

        image_buf[i] = all_colors[index].new_index;
    }

    if (use_dithering) {
        try dither.ditherBgraImage(
            allocator,
            image,
            .{ .quantized_buf = image_buf, .color_table = color_table },
            width,
            &all_colors,
        );
    }

    return QuantizedImage.init(color_table, image_buf);
}

/// Given a list of colors with their respective frequencies,
/// produce a color table with 256 colors that best represent the histogram.
fn quantizeHistogram(
    allocator: std.mem.Allocator,
    all_colors: *[color_array_size]QuantizedColor,
    n_pixels: usize,
) ![]u8 {
    // Find all colors in the color table that are used at least once, and chain them.
    var head: *QuantizedColor = undefined;
    for (all_colors) |*color| {
        if (color.frequency > 0) {
            head = color;
            break;
        }
    }

    var qcolor = head;
    var color_count: usize = 1;
    for (all_colors) |*color| {
        if (color != head and color.frequency > 0) {
            qcolor.next = color;
            qcolor = color;
            color_count += 1;
        }
    }
    qcolor.next = null;

    var first_partition = try allocator.create(ColorSpace);
    first_partition.colors = head;
    first_partition.num_colors = color_count;
    first_partition.num_pixels = n_pixels;

    std.debug.assert(n_pixels == countPixels(first_partition));

    findWidestChannel(first_partition);

    const partitions = try medianCut(allocator, first_partition, 8);

    defer {
        for (partitions) |p| {
            allocator.destroy(p);
        }
        allocator.free(partitions);
    }

    const color_table = try allocator.alloc(u8, partitions.len * 3);
    for (0.., partitions) |i, partition| {
        if (partition.num_colors == 0) continue;

        // This loop does two things:
        // 1. Find the average color of this partition.
        // 2. Point all colors in this partition to the index of this partition.
        var color = partition.colors;
        var rgb_sum: [3]usize = .{ 0, 0, 0 };
        for (0..partition.num_colors) |j| {
            color.new_index = @truncate(i);

            rgb_sum[0] += color.RGB[0];
            rgb_sum[1] += color.RGB[1];
            rgb_sum[2] += color.RGB[2];

            if (color.next) |next| {
                color = next;
            } else {
                std.debug.assert(j == partition.num_colors - 1);
                break;
            }
        }

        color_table[i * 3] = @intCast((rgb_sum[0] << shift) / partition.num_colors);
        color_table[i * 3 + 1] = @intCast((rgb_sum[1] << shift) / partition.num_colors);
        color_table[i * 3 + 2] = @intCast((rgb_sum[2] << shift) / partition.num_colors);
    }

    return color_table;
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
        partition.rgb_width = max[0] - min[0];
        return;
    }

    if (rgb_ranges[1] > rgb_ranges[0] and rgb_ranges[1] > rgb_ranges[2]) {
        partition.rgb_width = max[1] - min[1];
        partition.widest_channel = Channel.Green;
        return;
    }

    partition.rgb_width = max[2] - min[2];
    partition.widest_channel = Channel.Blue;
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

/// Copy all the colors in a partition into an array,
/// then sort that array along the widest channel of the partition, and return it.
/// The array contains pointers to the original colors in the partition.
/// The array is owned by the caller, and must be kept alive at least as long as the partition itself.
fn sortPartition(allocator: std.mem.Allocator, partition: *const ColorSpace) ![]*QuantizedColor {
    var sorted_colors = try allocator.alloc(*QuantizedColor, partition.num_colors);
    var color = partition.colors;
    for (0..partition.num_colors) |i| {
        std.debug.assert(@as(?*QuantizedColor, color) != null);
        sorted_colors[i] = color;
        if (color.next) |next| {
            color = next;
        } else {
            std.debug.assert(i == partition.num_colors - 1);
            break;
        }
    }

    std.sort.heap(
        *QuantizedColor,
        sorted_colors,
        partition.widest_channel,
        colorLessThan,
    );

    for (0..sorted_colors.len - 1) |i| {
        sorted_colors[i].next = sorted_colors[i + 1];
    }
    sorted_colors[sorted_colors.len - 1].next = null;
    return sorted_colors;
}

/// Given a list of partitions,
/// find the partition that varies the most in RGB width, and return its index.
fn findPartitionToSplit(partitions: []*ColorSpace) ?usize {
    var max_size: i32 = 0;
    var split_index: ?usize = null;
    for (0..partitions.len) |i| {
        const partition = partitions[i];
        if (partition.rgb_width > max_size and partition.num_colors > 1) {
            max_size = partition.rgb_width;
            split_index = i;
        }
    }
    return split_index;
}

/// Recursively split the colorspace into smaller partitions until 2^depth partitions are created.
fn medianCut(allocator: std.mem.Allocator, first_partition: *ColorSpace, depth: u4) ![]*ColorSpace {
    const total_partitions = std.math.pow(usize, 2, depth);

    var parts = try allocator.alloc(*ColorSpace, total_partitions);
    parts[0] = first_partition;

    var n_partitions: usize = 1; // we're starting with 1 large partition.
    while (n_partitions < total_partitions) : (n_partitions += 1) {
        // Look for the partition that has the largest variance in RGB width.
        const split_index_ = findPartitionToSplit(parts[0..n_partitions]);
        const split_index = if (split_index_) |index| index else break;

        // We found the partition that varies the most in either of the 3 color channels.
        const partition_to_split = parts[split_index];
        // sort the colors in that partition along the widest channel.
        const sorted_colors = try sortPartition(allocator, partition_to_split);
        defer allocator.free(sorted_colors);
        // Now the colors in the partition are sorted along the widest channel.
        partition_to_split.colors = sorted_colors[0];
        // Create a new partition. We will populate this struct below.
        const new_partition = try allocator.create(ColorSpace);

        // Next, we find the *median* color in the sorted list of colors.
        // NOTE: The median is NOT the middle element, since we're not sorting by frequency.
        // We want the color that divides the partitions such that both halves
        // contribute roughly the same pixel-frequency.
        // AKA sum([color.frequency for color in left]) =  sum(color.frequency for color in right).
        var color = partition_to_split.colors;

        // # of pixels that should remain in the current partition (left half).
        // The first color in the current partition will remain in it.
        const target_pixel_count = partition_to_split.num_pixels / 2;
        var remaining_pixel_count: usize = color.frequency; // # of pixels that will remain in the current partition.
        var remaining_color_count: usize = 1; // # of colors that will remain in the current partition.

        // At the end of this loop, `color` will point to the last color that will remain
        // in the current partition, and `color.next` will be the first color in the new partition.
        while (true) {
            // Stop if we are on the second last item in the linked list.
            const next_color = if (color.next) |c| c else break;
            if (next_color.next == null) {
                break;
            }

            color = next_color;
            remaining_color_count += 1;
            remaining_pixel_count += next_color.frequency;

            // We've reached the target pixel freuqency for the left half (remaining parition).
            if (remaining_pixel_count >= target_pixel_count) break;
        }

        // At this point, `color` is the last color in the left partition.
        const last_of_left = color;
        const first_of_right = if (last_of_left.next) |c| c else unreachable;

        // Set up the new partition (right half).
        new_partition.colors = first_of_right;
        last_of_left.next = null; // unlink the two partitions.

        new_partition.num_pixels = partition_to_split.num_pixels - remaining_pixel_count;
        new_partition.num_colors = partition_to_split.num_colors - remaining_color_count;

        partition_to_split.num_colors = remaining_color_count;
        partition_to_split.num_pixels = remaining_pixel_count;

        // Update the bounding boxes of the two partitions.
        // TODO: can I optimize this somehow? GIFLIB seems to use some kind of a trick here.
        findWidestChannel(partition_to_split);
        findWidestChannel(new_partition);

        // Add the new partition to the partitions array.
        parts[n_partitions] = new_partition;

        std.debug.assert(partition_to_split.num_pixels == countPixels(partition_to_split));
        std.debug.assert(new_partition.num_pixels == countPixels(new_partition));
    }

    if (n_partitions != total_partitions) {
        return try allocator.realloc(parts, n_partitions);
    }

    return parts;
}

/// Returns the sum of frequencies of all colors in the partition.
fn countPixels(partition: *ColorSpace) usize {
    var color = partition.colors;
    var count: usize = 0;
    const ncolors = partition.num_colors;
    for (0..ncolors) |i| {
        count += color.frequency;
        if (color.next) |next| {
            color = next;
        } else {
            if (ncolors != i + 1) {
                std.debug.panic(
                    "expected {} colors, got {}\n",
                    .{ ncolors, i + 1 },
                );
            }
            break;
        }
    }

    std.debug.assert(color.next == null);
    return count;
}
