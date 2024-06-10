const std = @import("std");

const BoundingBox = struct {
    min: [3]u8, // min RGB coords.
    max: [3]u8, // max RGB coords.
};

/// A non-leaf node in a KD Tree separates the 3-dimensional
/// RGB space into two sub-spaces along a plain parallel one of the axes (R/G/B)
/// that contains the `key` point.
pub const KdNonLeafNode = struct {
    bounding_box: BoundingBox,
    cut_dim: usize, // 0 = r, 1 = g, 2 = b
    key: [3]u8, // the key that divides the plane in `cut_dim`.
    left: ?*KdNode, // left subtree
    right: ?*KdNode, // right subtree
};

pub const KdNode = union(enum) {
    leaf: [3]u8, // R-G-B
    non_leaf: KdNonLeafNode,
};

fn compareRgb(channel: usize, a: [3]u8, b: [3]u8) bool {
    return a[channel] < b[channel];
}

/// A 3-dimensional KD-Tree that stores colors in the RGB space.
pub const KDTree = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// `depth` is the maximum distance between the root and any leaf.
    /// Depth of the root is 0, and depth of a child is `1 + depth(parent)`.
    depth: usize,

    /// Root node if the KD Tree.
    root: KdNonLeafNode,

    pub fn init(allocator: std.mem.Allocator, color_table: []const u8) !KDTree {
        std.debug.assert(color_table.len % 3 == 0);
        const ncolors = color_table.len / 3;
        const colors = try allocator.alloc([3]u8, ncolors);
        defer allocator.free(colors);

        // Also compute the bounding box of the root node of the KD Tree.
        var bb_min = [3]u8{ 255, 255, 255 };
        var bb_max = [3]u8{ 0, 0, 0 };

        for (0..ncolors) |i| {
            colors[i] = .{
                color_table[i * 3 + 0], // r
                color_table[i * 3 + 1], // g
                color_table[i * 3 + 2], // b
            };

            for (0..3) |j| {
                bb_min[j] = @min(bb_min[j], colors[i][j]);
                bb_max[j] = @max(bb_max[j], colors[i][j]);
            }
        }

        const bb = BoundingBox{ .min = bb_min, .max = bb_max };

        const tree = try constructKdTree(allocator, bb, colors);
        return .{
            .root = tree.root,
            .depth = tree.depth,
            .allocator = allocator,
        };
    }

    pub fn findNearestColor(self: *const Self, color: [3]u8) [3]u8 {
        _ = color;
        _ = self;
    }

    fn constructKdTree(
        allocator: std.mem.Allocator,
        bounding_box: BoundingBox,
        colors: [][3]u8,
    ) !struct { root: KdNonLeafNode, depth: usize } {
        std.debug.assert(colors.len > 4);

        var root: KdNonLeafNode = undefined;
        root.cut_dim = 0; // red.
        root.bounding_box = bounding_box;

        std.sort.heap([3]u8, colors, root.cut_dim, compareRgb);

        const median = colors.len / 2;
        root.key = colors[median];

        var depth: usize = 1;

        const left = try allocator.create(KdNode);
        left.* = try constructRecursive(allocator, &root, true, colors[0..median], 1, &depth);

        const right = try allocator.create(KdNode);
        right.* = try constructRecursive(allocator, &root, false, colors[median + 1 ..], 1, &depth);

        root.left = left;
        root.right = right;

        return .{ .root = root, .depth = depth };
    }

    /// Constructs a bounding box for the child node from its parent's bounding box.
    inline fn makeChildBoundingBox(parent: *const KdNonLeafNode, is_left: bool) BoundingBox {
        var bb = parent.bounding_box;
        if (is_left) {
            bb.max[parent.cut_dim] = parent.key[parent.cut_dim];
        } else {
            bb.min[parent.cut_dim] = parent.key[parent.cut_dim];
        }
        return bb;
    }

    /// Recursively constructs a KD Tree from a list of colors and a root node.
    /// `parent_node`: Parent of the current node being constructed.
    /// `is_left_child`: True if the current node is the left child of `parent_node`.
    /// `colors`: List of colors to be partitioned by the current one.
    /// `current_depth`: Depth of the current node.
    /// `total_depth`: An in-out parameter that is updated with the depth of the tree.
    fn constructRecursive(
        allocator: std.mem.Allocator,
        parent_node: *const KdNonLeafNode,
        is_left_child: bool,
        colors: [][3]u8,
        current_depth: usize,
        total_depth: *usize,
    ) !KdNode {
        std.debug.assert(colors.len > 1);

        total_depth.* = @max(total_depth.*, current_depth);

        var node: KdNonLeafNode = undefined;
        node.cut_dim = current_depth % 3;
        node.bounding_box = makeChildBoundingBox(parent_node, is_left_child);

        // sort all colors along the cut dimension.
        std.sort.heap([3]u8, colors, node.cut_dim, compareRgb);

        const median = colors.len / 2;
        node.key = colors[median];

        const lower = colors[0..median];
        if (lower.len == 0) {
            node.left = null;
        } else {
            var left = try allocator.create(KdNode);
            if (lower.len == 1) {
                total_depth.* = @max(total_depth.*, current_depth + 1);
                left.leaf = lower[0];
            } else {
                left.* = try constructRecursive(
                    allocator,
                    &node,
                    true,
                    lower,
                    current_depth + 1,
                    total_depth,
                );
            }
            node.left = left;
        }

        node.right = null;
        if (median + 1 < colors.len) {
            const higher = colors[median + 1 ..];
            var right = try allocator.create(KdNode);
            if (higher.len == 1) {
                total_depth.* = @max(total_depth.*, current_depth + 1);
                right.leaf = higher[0];
            } else {
                right.* = try constructRecursive(
                    allocator,
                    &node,
                    false,
                    higher,
                    current_depth + 1,
                    total_depth,
                );
            }
            node.right = right;
        }

        return KdNode{ .non_leaf = node };
    }

    pub fn deinit(self: *const Self) void {
        if (self.root.left) |left| {
            self.destroyNode(left);
        }

        if (self.root.right) |right| {
            self.destroyNode(right);
        }
    }

    fn destroyNode(self: *const Self, node: *KdNode) void {
        switch (node.*) {
            .non_leaf => {
                if (node.non_leaf.left) |left| {
                    self.destroyNode(left);
                }

                if (node.non_leaf.right) |right| {
                    self.destroyNode(right);
                }
            },
            else => {},
        }

        self.allocator.destroy(node);
    }
};

const t = std.testing;
test "KDTree construction" {
    const allocator = t.allocator;
    const color_table = [_]u8{
        200, 0,   0,
        100, 1,   200,
        80,  100, 0,

        50,  200, 100,
        0,   100, 22,
        0,   55,  100,
    };

    const tree = try KDTree.init(allocator, &color_table);
    defer tree.deinit();

    try t.expectEqual(2, tree.depth);

    try t.expectEqual(0, tree.root.cut_dim);
    try t.expectEqualDeep([3]u8{ 80, 100, 0 }, tree.root.key);
    try t.expectEqualDeep([3]u8{ 0, 0, 0 }, tree.root.bounding_box.min);
    try t.expectEqualDeep([3]u8{ 200, 200, 200 }, tree.root.bounding_box.max);

    const left_of_root = tree.root.left.?.non_leaf;
    try t.expect(left_of_root.cut_dim == 1);
    try t.expectEqualDeep([3]u8{ 0, 100, 22 }, left_of_root.key);
    try t.expectEqualDeep([3]u8{ 0, 0, 0 }, left_of_root.bounding_box.min);
    try t.expectEqualDeep([3]u8{ 80, 200, 200 }, left_of_root.bounding_box.max);

    const left_left = left_of_root.left.?.leaf;
    try t.expectEqualDeep([3]u8{ 0, 55, 100 }, left_left);

    const right_of_root = tree.root.right.?.non_leaf;
    try t.expectEqual(1, right_of_root.cut_dim);
    try t.expectEqualDeep([3]u8{ 100, 1, 200 }, right_of_root.key);
    try t.expectEqualDeep([3]u8{ 80, 0, 0 }, right_of_root.bounding_box.min);
    try t.expectEqualDeep([3]u8{ 200, 200, 200 }, right_of_root.bounding_box.max);
}
