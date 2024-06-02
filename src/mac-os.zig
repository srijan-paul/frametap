const std = @import("std");
const core_graphics = @cImport(@cInclude("CoreGraphics/CoreGraphics.h"));
const objc = @import("objc");
const core = @import("core.zig");
const screencap = @cImport(@cInclude("screencap.h"));

const CaptureError = core.FrametapError;
const Capturer = core.ICapturer;
const Rect = core.Rect;
const CaptureConfig = core.CaptureConfig;
const Platform = core.Platform;

pub const MacOSScreenCapture = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    capture: core.ICapturer,

    capture_c: *screencap.ScreenCapture,

    /// Pointer to the user-facing `frametap` struct that contains the user provided
    /// `onFrame` callback.
    frametap: *anyopaque,

    /// MacOS specific screenshot implementation.
    fn screenshot(ctx: *core.ICapturer, rect: ?Rect) !core.ImageData {
        const self = @fieldParentPtr(Self, "capture", ctx);

        var image: screencap.ImageData = undefined;
        if (rect) |r| {
            const capture_rect = screencap.CaptureRect{
                .topleft_x = r.x,
                .topleft_y = r.y,
                .width = r.width,
                .height = r.height,
            };
            image = screencap.grab_screen(self.capture_c, &capture_rect);
        } else {
            image = screencap.grab_screen(self.capture_c, null);
        }

        defer screencap.deinit_imagedata(&image);

        const bufsize: usize = image.width * image.height * 4;
        const framebuf = try self.allocator.alloc(u8, bufsize);
        const c_buf: [*]u8 = image.rgba_buf;

        @memcpy(framebuf, c_buf);
        return core.ImageData{
            .width = image.width,
            .height = image.height,
            .data = framebuf,
        };
    }

    /// The callback that runs everytime a frame is received on MacOS.
    export fn processCFrame(
        cframe: screencap.Frame,
        maybe_capture_ptr: ?*anyopaque,
    ) void {
        std.debug.assert(maybe_capture_ptr != null);
        const width = cframe.image.width;
        const height = cframe.image.height;

        // The capture object is passed back to us as an opaque pointer from C.
        const capture_ptr = maybe_capture_ptr orelse unreachable;
        const capture: *Capturer = @ptrCast(@alignCast(capture_ptr));

        // From the cpature object, we can get a `self` pointer to this struct.
        const self = @fieldParentPtr(Self, "capture", capture);
        const framebuf = self.allocator.alloc(u8, width * height * 4) catch return;
        @memcpy(framebuf, @as([*]u8, cframe.image.rgba_buf));

        const image = core.ImageData{
            .width = width,
            .height = height,
            .data = framebuf,
        };

        const frame = core.Frame{
            .image = image,
            .duration_ms = cframe.duration_in_ms,
        };

        capture.onFrameReceived(self.frametap, frame) catch return;
    }

    /// MacOS specific screen capture function.
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

    /// Initialize a MacOS specific capturer.
    pub fn init(
        allocator: std.mem.Allocator,
        rect: ?Rect,
        frametap: *anyopaque,
    ) CaptureError!MacOSScreenCapture {
        const maybe_capture_c: ?*screencap.ScreenCapture = screencap.alloc_capture();
        const capture_c = if (maybe_capture_c) |ptr| ptr else return CaptureError.InternalError;

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
