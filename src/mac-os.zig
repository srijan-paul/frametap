const std = @import("std");
const c = @cImport(@cInclude("CoreGraphics/CoreGraphics.h"));
const objc = @import("objc");
const core = @import("core.zig");
const screencap = @cImport(@cInclude("screencap.h"));

const JifError = core.JifError;
const CaptureContext = core.Capture;
const Rect = core.Rect;
const CaptureConfig = core.CaptureConfig;
const Platform = core.Platform;

pub const MacOSCaptureContext = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    capture: core.Capture,

    capture_c: *screencap.ScreenCapture,

    /// MacOS specific screenshot implementation.
    fn screenshot(ctx: *core.Capture, rect: ?Rect) !core.Frame {
        const self = @fieldParentPtr(Self, "capture", ctx);

        var c_frame: screencap.Frame = undefined;
        if (rect) |r| {
            const capture_rect = screencap.CaptureRect{
                .topleft_x = r.x,
                .topleft_y = r.y,
                .width = r.width,
                .height = r.height,
            };
            c_frame = screencap.capture_frame(self.capture_c, &capture_rect);
        } else {
            c_frame = screencap.capture_frame(self.capture_c, null);
        }

        const framebuf = try self.allocator.alloc(u8, c_frame.rgba_buf_size);
        const c_buf: [*]u8 = c_frame.rgba_buf;

        @memcpy(framebuf, c_buf);

        return core.Frame{
            .width = c_frame.width,
            .height = c_frame.height,
            .data = framebuf,
        };
    }

    fn startCaptureMacOS(_: *CaptureContext) !void {
        // TODO:
    }

    fn stopCaptureMacOS(_: *CaptureContext) !void {
        // TODO:
    }

    fn takeScreenshot(ctx: *CaptureContext) !void {
        const self = @fieldParentPtr(Self, "ctx", ctx);
        return self.screenshot();
    }

    fn startCapture(ctx: *CaptureContext) !void {
        const self = @fieldParentPtr(Self, "ctx", ctx);
        try self.startCaptureMacOS();
    }

    fn stopCapture(ctx: *CaptureContext) !void {
        const self = @fieldParentPtr(Self, "ctx", ctx);
        self.stopCaptureMacOS();
    }

    /// Initialize a MacOS specific capture context.
    pub fn init(allocator: std.mem.Allocator, rect: ?Rect) JifError!MacOSCaptureContext {
        const maybe_capture_c: ?*screencap.ScreenCapture = screencap.alloc_capture();
        const capture_c = if (maybe_capture_c) |ptr| ptr else return JifError.InternalError;

        const conf = core.CaptureConfig{
            .captureFrameFn = Self.screenshot,
            .rect = rect,
            .stopRecordFn = Self.stopCaptureMacOS,
            .startRecordFn = Self.startCaptureMacOS,
        };

        screencap.init_capture(capture_c, undefined);

        if (rect) |r| {
            const capture_rect = screencap.CaptureRect{
                .topleft_x = r.x,
                .topleft_y = r.y,
                .width = r.width,
                .height = r.height,
            };
            screencap.set_capture_region(capture_c, capture_rect);
        }

        return Self{
            .allocator = allocator,
            .capture_c = capture_c,
            .capture = CaptureContext.init(Platform.MacOS, conf),
        };
    }

    pub fn deinit(self: MacOSCaptureContext) void {
        screencap.deinit_capture(self.capture_c);
    }
};
