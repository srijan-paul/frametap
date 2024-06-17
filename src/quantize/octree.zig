const std = @import("std");

const q = @import("quantize.zig");
const QuantizedImage = q.QuantizedImage;
const QuantizedFrames = q.QuantizedFrames;
const QuantizerConfig = q.QuantizerConfig;

const OctreeNode = struct {
    depth: usize,
    /// The color that divides the children.
    color: [3]u8,
    /// A node has either 0 or 8 children.
    children: ?[8]*OctreeNode,
    /// Min bounds for each color channel.
    rgb_min: [3]u8,
    /// Max bounds for each color channel.
    rgb_max: [3]u8,
};

const Octree = @compileError("Octree color quantization is not yet implemented");
