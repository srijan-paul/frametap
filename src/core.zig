const std = @import("std");
const objc = @import("objc");
const c = @cImport(@cInclude("CoreGraphics/CoreGraphics.h"));
const macos = @import("./mac-os.zig");
const png = @import("./png.zig");

pub const Platform = enum {
    MacOS,
    Windows,
    Linux,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

const ScreenshotFn = *const (fn (*Capture, rect: ?Rect) anyerror!Frame);
const StartRecordFn = *const (fn (*Capture) anyerror!void);
const StopRecordFn = *const (fn (*Capture) anyerror!void);

pub const OpaqueFrameHandler = *const fn (*anyopaque, Frame) anyerror!void;

pub const CaptureConfig = struct {
    rect: ?Rect,
    screenshotFn: ScreenshotFn,
    startRecordFn: StartRecordFn,
    stopRecordFn: StopRecordFn,
    onFrameReceived: OpaqueFrameHandler,
};

const builtin = @import("builtin");

/// A single frame of a video.
pub const Frame = struct {
    /// An buffer containing the frame info as RGBARBGARGBA...
    /// `data.len = width * height * 4`.
    data: []u8,
    /// Width of the frame pixels.
    width: usize,
    /// Height of the frame in pixels.
    height: usize,

    /// Export the frame as a PNG file.
    pub fn writePNG(self: *const Frame, filepath: [:0]const u8) !void {
        try png.writeRgbaToPng(self.data, self.width, self.height, filepath);
    }
};

pub const Capture = struct {
    const Self = @This();
    rect: ?Rect,
    screenshotFn: ScreenshotFn,
    startRecordFn: StartRecordFn,
    stopRecordFn: StopRecordFn,

    // A callback function to call when a frame is received.
    // This is not be set explicitly by the user, rather by the Frametap(T) struct below.
    onFrameReceived: *const fn (*anyopaque, Frame) anyerror!void,

    pub fn init(
        config: CaptureConfig,
    ) Self {
        return Self{
            .rect = config.rect,
            .screenshotFn = config.screenshotFn,
            .startRecordFn = config.startRecordFn,
            .stopRecordFn = config.stopRecordFn,
            .onFrameReceived = config.onFrameReceived,
        };
    }

    /// Create a new capture object.
    pub fn create(
        allocator: std.mem.Allocator,
        rect: ?Rect,
        onFrameReceived: OpaqueFrameHandler,
        frametap: *anyopaque,
    ) !*Capture {
        if (builtin.os.tag == .macos) {
            var macos_capture = try allocator.create(macos.MacOSScreenCapture);
            macos_capture.* = try macos.MacOSScreenCapture.init(
                allocator,
                rect,
                onFrameReceived,
                frametap,
            );
            return &macos_capture.capture;
        }

        return JifError.PlatformNotSupported;
    }

    pub fn destroy(self: *Self) void {
        if (builtin.os.tag == .macos) {
            const macos_capture: *macos.MacOSScreenCapture = @fieldParentPtr(
                macos.MacOSScreenCapture,
                "capture",
                self,
            );
            macos_capture.deinit();
            macos_capture.allocator.destroy(macos_capture);
            return;
        }

        unreachable;
    }

    /// Capture a screenshot of the screen.
    /// If `rect` is `null`, the rect area specified while initializing the capture object will be used.
    /// If that is `null` too, the entire screen will be captured.
    pub fn screenshot(self: *Self, rect: ?Rect) !Frame {
        // verify alginment.
        std.debug.assert((@intFromPtr(self) % @alignOf(Self)) == 0);
        return self.screenshotFn(self, rect);
    }

    pub fn begin(self: *Self) !void {
        try self.startRecordFn(self);
    }

    pub fn end(self: *Self) !void {
        try self.stopRecordFn(self);
    }
};

pub fn FrameTap(comptime TContext: type) type {
    return struct {
        pub const FrameHandler = *const fn (TContext, Frame) anyerror!void;
        const Self = @This();

        capture: *Capture,
        context: TContext,
        processFrame: FrameHandler,

        fn onFrameCallback(ptr: *anyopaque, frame: Frame) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.processFrame(self.context, frame);
        }

        pub fn init(allocator: std.mem.Allocator, context: TContext, processFrame: FrameHandler) !*Self {
            const self = try allocator.create(Self);
            const capture = try Capture.create(
                allocator,
                null,
                onFrameCallback,
                self,
            );

            self.* = Self{
                .capture = capture,
                .context = context,
                .processFrame = processFrame,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.capture.destroy();
        }
    };
}

pub const JifError = error{
    ImageCreationFailed,
    PlatformNotSupported,
    PNGConvertFailed,
    GifConvertFailed,
    InternalError,
    /// Failed to write to the GIF file.
    GifFlushFailed,
};
