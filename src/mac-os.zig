const std = @import("std");
const core_graphics = @cImport(@cInclude("CoreGraphics/CoreGraphics.h"));
const objc = @import("objc");
const core = @import("core.zig");
const screencap = @cImport(@cInclude("screencap.h"));

const JifError = core.JifError;
const Capturer = core.Capture;
const Rect = core.Rect;
const CaptureConfig = core.CaptureConfig;
const Platform = core.Platform;

pub const MacOSScreenCapture = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    capture: core.Capture,

    capture_c: *screencap.ScreenCapture,
    frametap: *anyopaque,

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

        defer screencap.deinit_frame(&c_frame);

        const framebuf = try self.allocator.alloc(u8, c_frame.rgba_buf_size);
        const c_buf: [*]u8 = c_frame.rgba_buf;

        @memcpy(framebuf, c_buf);
        return core.Frame{
            .width = c_frame.width,
            .height = c_frame.height,
            .data = framebuf,
        };
    }

    export fn processCFrame(
        data: [*c]u8,
        width: usize,
        height: usize,
        bytes_per_row: usize,
        maybe_capture_ptr: ?*anyopaque,
    ) void {
        std.debug.assert(maybe_capture_ptr != null);
        std.debug.assert(bytes_per_row == width * 4);

        const capture_ptr = maybe_capture_ptr orelse unreachable;
        const capture: *Capturer = @ptrCast(@alignCast(capture_ptr));

        const self = @fieldParentPtr(Self, "capture", capture);
        const framebuf = self.allocator.alloc(u8, bytes_per_row * height) catch return;

        @memcpy(framebuf, @as([*]u8, data));
        const frame = core.Frame{
            .width = width,
            .height = height,
            .data = framebuf,
        };

        capture.onFrameReceived(self.frametap, frame) catch return;
    }

    /// MacOS specific screen capture implementation
    fn startCaptureMacOS(ctx: *Capturer) !void {
        const self = @fieldParentPtr(Self, "capture", ctx);
        var frame_processor: screencap.FrameProcessor = undefined;
        frame_processor.other_data = &self.capture;
        frame_processor.process_fn = &Self.processCFrame;
        screencap.set_on_frame_handler(self.capture_c, frame_processor);
        // TODO: handle the return
        _ = screencap.start_capture_and_wait(self.capture_c);
    }

    /// MacOS specific screen capture implementation
    fn stopCaptureMacOS(capturer: *Capturer) !void {
        const self = @fieldParentPtr(Self, "capture", capturer);
        // TODO: handle the return value
        _ = screencap.stop_capture(self.capture_c);
    }

    /// Initialize a MacOS specific capture context.
    pub fn init(
        allocator: std.mem.Allocator,
        rect: ?Rect,
        frametap: *anyopaque,
    ) JifError!MacOSScreenCapture {
        const maybe_capture_c: ?*screencap.ScreenCapture = screencap.alloc_capture();
        const capture_c = if (maybe_capture_c) |ptr| ptr else return JifError.InternalError;

        const conf = core.CaptureConfig{
            .rect = rect,
            .screenshotFn = Self.screenshot,
            .stopRecordFn = Self.stopCaptureMacOS,
            .startRecordFn = Self.startCaptureMacOS,
            .onFrameReceived = null,
        };

        screencap.init_capture(capture_c);

        if (rect) |r| {
            const capture_rect = screencap.CaptureRect{
                .topleft_x = r.x,
                .topleft_y = r.y,
                .width = r.width,
                .height = r.height,
            };
            screencap.set_capture_region(capture_c, capture_rect);
        }

        const capture = Capturer.init(conf);
        return Self{
            .allocator = allocator,
            .capture_c = capture_c,
            .capture = capture,
            .frametap = frametap,
        };
    }

    pub fn deinit(self: MacOSScreenCapture) void {
        _ = screencap.deinit_capture(self.capture_c);
    }
};
