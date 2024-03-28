pub const core = @import("core.zig");
const mac = @import("mac-os.zig");

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var context = try mac.MacOSCaptureContext.init(
        core.Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        allocator,
    );
    defer context.deinit();

    const then = std.time.milliTimestamp();

    for (0..20) |_| {
        try context.captureFrame();
    }
    const now = std.time.milliTimestamp();

    const delta = now - then;
    std.debug.print("Took {} snapshots in {}ms\n", .{
        context.ctx.frames.items.len,
        delta,
    });

    const dir = std.fs.cwd();

    const file = try dir.createFile("zif.png", .{ .read = true });
    try file.writeAll(context.ctx.frames.items[0]);
}
