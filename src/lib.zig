// C ABI compatible functions for taking screenshots.

const std = @import("std");
pub const core = @import("./core.zig");

const CFrame = extern struct {
    data: [*c]u8,
    width: usize,
    height: usize,
};

export fn releaseFrame(frame: CFrame) void {
    const allocator = std.heap.page_allocator;
    if (frame.data != null) {
        allocator.free(frame.data);
    }
}

export fn captureFrame(x: f32, y: f32, width: f32, height: f32) CFrame {
    const allocator = std.heap.page_allocator;
    const FrameTap = core.FrameTap(?*anyopaque);
    var frametap = FrameTap.init(allocator, null) catch {
        return CFrame{ .data = null, .width = 0, .height = 0 };
    };

    const area = core.Rect{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };

    const frame = frametap.capture.screenshot(area) catch {
        return CFrame{ .data = null, .width = 0, .height = 0 };
    };

    return CFrame{
        .data = frame.data.ptr,
        .width = frame.width,
        .height = frame.height,
    };
}
