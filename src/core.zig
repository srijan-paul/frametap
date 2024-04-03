const std = @import("std");
const objc = @import("objc");
const c = @cImport(@cInclude("CoreGraphics/CoreGraphics.h"));
const macos = @import("./mac-os.zig");

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

pub const CaptureConfig = struct {
    rect: ?Rect,
    captureFrameFn: ScreenshotFn,
    startRecordFn: StartRecordFn,
    stopRecordFn: StopRecordFn,
};

const builtin = @import("builtin");

pub const Frame = struct {
    data: []u8,
    width: usize,
    height: usize,
};

pub const Capture = struct {
    const Self = @This();
    rect: ?Rect,
    screenshotFn: ScreenshotFn,
    startRecordFn: StartRecordFn,
    stopRecordFn: StopRecordFn,
    platform: Platform,

    pub fn init(
        platform: Platform,
        config: CaptureConfig,
    ) Self {
        return Self{
            .platform = platform,
            .rect = config.rect,
            .screenshotFn = config.captureFrameFn,
            .startRecordFn = config.startRecordFn,
            .stopRecordFn = config.stopRecordFn,
        };
    }

    /// Create a new capture object.
    pub fn create(allocator: std.mem.Allocator, rect: ?Rect) !*Capture {
        if (builtin.os.tag == .macos) {
            var macos_capture = try macos.MacOSCaptureContext.init(allocator, rect);
            return &macos_capture.capture;
        }

        return JifError.PlatformNotSupported;
    }

    pub fn destroy(self: *Self) void {
        if (builtin.os.tag == .macos) {
            const macos_capture = @fieldParentPtr(macos.MacOSCaptureContext, "capture", self);
            macos_capture.deinit();
            return;
        }

        unreachable;
    }

    /// Capture a screenshot of the screen.
    /// If `rect` is `null`, the rect area specified while initializing the capture object will be used.
    /// If that is `null` too, the entire screen will be captured.
    pub fn screenshot(self: *Self, rect: ?Rect) anyerror!Frame {
        return self.screenshotFn(self, rect);
    }

    pub fn begin(self: *Self) !void {
        self.startRecordFn(self);
    }

    pub fn end(self: *Self) !void {
        self.endRecordFn(self);
    }
};

pub const JifError = error{
    ImageCreationFailed,
    PlatformNotSupported,
    PNGConvertFailed,
    GifConvertFailed,
    InternalError,
    /// Failed to write to the GIF file.
    GifFlushFailed,
};
