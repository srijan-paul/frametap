const std = @import("std");

const Allocator = std.mem.Allocator;

pub const QueueError = error{
    empty,
};

pub fn Queue(comptime ItemType: type) type {
    return struct {
        const Self = @This();

        const min_capacity: usize = 8;

        allocator: Allocator,

        items: []ItemType = undefined,
        back_ptr: usize = 0, // points one past the last item.
        front_ptr: usize = 0, // points to the first item.

        pub fn init(allocator: Allocator) !Self {
            const items = try allocator.alloc(ItemType, min_capacity);
            return Self{ .allocator = allocator, .items = items };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        pub inline fn isEmpty(self: *const Self) bool {
            return self.back_ptr == self.front_ptr;
        }

        pub inline fn size(self: *const Self) usize {
            return self.back_ptr - self.front_ptr;
        }

        pub fn push(self: *Self, item: ItemType) !void {
            if (self.back_ptr == self.items.len) {
                const new_cap = self.items.len * 2;
                const new_items = try self.allocator.realloc(self.items, new_cap);
                self.items = new_items;
            }

            self.items[self.back_ptr] = item;
            self.back_ptr += 1;
        }

        pub fn pop(self: *Self) QueueError!ItemType {
            if (self.front_ptr == self.back_ptr) {
                return QueueError.empty;
            }

            self.front_ptr += 1;
            return self.items[self.front_ptr - 1];
        }
    };
}

const t = std.testing;
test "Queue" {
    const allocator = t.allocator;
    var queue = try Queue(i32).init(allocator);
    defer queue.deinit();

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);

    try t.expectEqual(1, try queue.pop());
    try t.expectEqual(2, try queue.pop());
    try t.expectEqual(3, try queue.pop());

    try t.expectError(QueueError.empty, queue.pop());

    try queue.push(4);
    try t.expectEqual(4, try queue.pop());
}

test "Queue – growing the buffer" {
    const allocator = t.allocator;
    var queue = try Queue(i32).init(allocator);
    defer queue.deinit();

    const numbers = try allocator.alloc(i32, 10_000_000);
    defer allocator.free(numbers);

    for (0..numbers.len) |i| {
        numbers[i] = @intCast(i);
    }

    for (numbers) |n| {
        try queue.push(n);
    }

    for (numbers) |n| {
        try t.expectEqual(n, try queue.pop());
    }
}
