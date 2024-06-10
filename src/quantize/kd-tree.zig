const std = @import("std");

const BoundingBox = struct {
    min: [3]u8, // min RGB coords.
    max: [3]u8, // max RGB coords.
};

pub const KDTreeCutNode = struct {
    bounding_box: BoundingBox,
    cut_dim: usize, // 0 = r, 1 = g, 2 = b
    key: [3]u8, // the key that divides the plane in `cut_dim`.
    left: ?*KDTreeNode, // left subtree
    right: ?*KDTreeNode, // right subtree
};

/// A 3-dimensional KD-Tree that stores RGB colors.
pub const KDTreeNode = union(enum) {
    leaf: [3]u8, // RGB
    non_leaf: KDTreeCutNode,
};

fn compareRgb(channel: usize, a: [3]u8, b: [3]u8) bool {
    return a[channel] < b[channel];
}

pub const KDTree = struct {
    const Self = @This();

    root: KDTreeCutNode,
    allocator: std.mem.Allocator,

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

        const root = try constructKdTree(allocator, bb, colors);
        return .{
            .root = root,
            .allocator = allocator,
        };
    }

    fn constructKdTree(
        allocator: std.mem.Allocator,
        bounding_box: BoundingBox,
        colors: [][3]u8,
    ) !KDTreeCutNode {
        std.debug.assert(colors.len > 2);

        var root: KDTreeCutNode = undefined;
        root.cut_dim = 0; // red.
        root.bounding_box = bounding_box;

        std.sort.heap([3]u8, colors, root.cut_dim, compareRgb);

        const median = colors.len / 2;
        root.key = colors[median];

        const left = try allocator.create(KDTreeNode);
        left.* = try constructRecursive(allocator, &root, true, colors[0..median], 1);

        const right = try allocator.create(KDTreeNode);
        right.* = try constructRecursive(allocator, &root, false, colors[median + 1 ..], 1);

        root.left = left;
        root.right = right;
        return root;
    }

    inline fn makeChildBoundingBox(parent: *const KDTreeCutNode, is_left: bool) BoundingBox {
        var bb = parent.bounding_box;
        if (is_left) {
            bb.max[parent.cut_dim] = parent.key[parent.cut_dim];
        } else {
            bb.min[parent.cut_dim] = parent.key[parent.cut_dim];
        }
        return bb;
    }

    fn constructRecursive(
        allocator: std.mem.Allocator,
        parent_node: *const KDTreeCutNode,
        is_left_child: bool,
        colors: [][3]u8,
        depth: usize,
    ) !KDTreeNode {
        std.debug.assert(colors.len > 1);

        var node: KDTreeCutNode = undefined;
        node.cut_dim = depth % 3;
        node.bounding_box = makeChildBoundingBox(parent_node, is_left_child);

        // sort all colors along the cut dimension.
        std.sort.heap([3]u8, colors, node.cut_dim, compareRgb);

        const median = colors.len / 2;
        node.key = colors[median];

        const lower = colors[0..median];
        if (lower.len == 0) {
            node.left = null;
        } else {
            var left = try allocator.create(KDTreeNode);
            if (lower.len == 1) {
                left.leaf = lower[0];
            } else {
                left.* = try constructRecursive(allocator, &node, true, lower, depth + 1);
            }
            node.left = left;
        }

        node.right = null;
        if (median + 1 < colors.len) {
            const higher = colors[median + 1 ..];
            var right = try allocator.create(KDTreeNode);
            if (higher.len == 1) {
                right.leaf = higher[0];
            } else {
                right.* = try constructRecursive(allocator, &node, false, higher, depth + 1);
            }
            node.right = right;
        }

        return KDTreeNode{ .non_leaf = node };
    }

    pub fn deinit(self: *const Self) void {
        if (self.root.left) |left| {
            self.destroyNode(left);
        }

        if (self.root.right) |right| {
            self.destroyNode(right);
        }
    }

    fn destroyNode(self: *const Self, node: *KDTreeNode) void {
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
test "KDTree – construction" {
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
