const std = @import("std");
const objc = @import("objc");
const c = @cImport(@cInclude("CoreGraphics/CoreGraphics.h"));
const macos = @import("./mac-os.zig");
const png = @import("./png.zig");
const builtin = @import("builtin");

// The mental model of the capture system is as follows:
//
//     +----------+
// +-->| Frametap | <-----+
// |   +----------+       |
// |        |             |
// |        |             |
// |   +----------+       |
// +---| Capturer |<----+ |
//     +----------+     | |
//          |           | |
//          |           | |
//  +----------------+  | |
//  | OS Capturer    |--|-+
//  +----------------+--+
//
// # Frametap
//
// The `Frametap` struct is the user facing API that allows the user to set
// a callback function to run on every-frame.
// This callback function might need some additional data, for example,
// an array into which the callback stores the frames.
// This additional data is called a "context", and the `Frametap` struct
// is therefore a generic struct that takes a type parameter `TContext`.
// Example:
// `FrameTap([10]Frame)` is the type of a frametap struct
// has an array to store the ten most recent frames of a capture.
//
// # Capturer
//
// The `Frametap` struct contains a `Capturer` as a member,
// which is a wrapper for the internal APIs that we use to capture the screen.
// The capturer object contains a pointer to  its parent `Frametap` object.
// Whenever a frame is received, the capturer calls the parent's `onFrame`
// function.
//
// The `Capturer` is more of an *interface*, than a struct.
// Each OS will have its own implementation of `Capturer`.
// Since Zig does not have interfaces, we use a struct with function pointers.
// As an example, We use a `MacOSCapturer` struct on MacOS.
// This struct is an "implementation" if the `Capturer` interface in the sense
// that it has stores a `Capturer` with the appropriate function pointers
// assigned.
//

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

const ScreenshotFn = *const (fn (*ICapturer, rect: ?Rect) anyerror!ImageData);
const StartRecordFn = *const (fn (*ICapturer) anyerror!void);
const StopRecordFn = *const (fn (*ICapturer) anyerror!void);

pub const OpaqueFrameHandler = *const fn (*anyopaque, Frame) anyerror!void;

pub const CaptureConfig = struct {
    rect: ?Rect,
    screenshotFn: ScreenshotFn,
    startRecordFn: StartRecordFn,
    stopRecordFn: StopRecordFn,
    onFrameReceived: ?OpaqueFrameHandler,
};

fn defaultFrameHandler(_: *anyopaque, _: Frame) !void {
    std.debug.panic("No frame handler set. Call 'setFrameHandler'\n", .{});
}

/// An RGBA Image buffer.
pub const ImageData = struct {
    /// An buffer containing the frame info as RGBARBGARGBA...
    /// `data.len = width * height * 4`.
    data: []u8,
    /// Width of the frame pixels.
    width: usize,
    /// Height of the frame in pixels.
    height: usize,

    /// Export the frame as a PNG file.
    pub fn writePng(self: *const ImageData, filepath: [:0]const u8) !void {
        try png.writeRgbaToPng(self.data, self.width, self.height, filepath);
    }
};

/// A single frame of a video feed.
pub const Frame = struct {
    image: ImageData,
    duration_ms: f64,
};

pub const ICapturer = struct {
    const Self = @This();
    rect: ?Rect,
    /// A function pointer to a platform specific function that captures a screenshot.
    screenshotFn: ScreenshotFn,
    /// A function pointer to a platform specific function that starts recording the screen.
    startRecordFn: StartRecordFn,
    /// A function pointer to a platform specific function that stops recording the screen.
    stopRecordFn: StopRecordFn,

    // A callback function to call when a frame is received.
    // This is not be set explicitly by the user, rather by the Frametap(T) struct below.
    onFrameReceived: *const fn (*anyopaque, Frame) anyerror!void,

    pub fn setFrameHandler(self: *Self, frameHandler: *const fn (*anyopaque, Frame) anyerror!void) void {
        self.onFrameReceived = frameHandler;
    }

    pub fn init(
        config: CaptureConfig,
    ) Self {
        return Self{
            .rect = config.rect,
            .screenshotFn = config.screenshotFn,
            .startRecordFn = config.startRecordFn,
            .stopRecordFn = config.stopRecordFn,
            .onFrameReceived = config.onFrameReceived orelse defaultFrameHandler,
        };
    }

    /// Create a new capture object.
    pub fn create(
        allocator: std.mem.Allocator,
        rect: ?Rect,
        frametap: *anyopaque,
    ) !*ICapturer {
        if (builtin.os.tag == .macos) {
            var macos_capture = try allocator.create(macos.MacOSScreenCapture);
            macos_capture.* = try macos.MacOSScreenCapture.init(
                allocator,
                rect,
                frametap,
            );
            return &macos_capture.capture;
        }

        return FrametapError.PlatformNotSupported;
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
    pub fn screenshot(self: *Self, rect: ?Rect) !ImageData {
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

        capture: *ICapturer,
        context: TContext,
        processFrame: FrameHandler,

        // By default, the frame handle panics and asks the user to explicitly set
        // a callback function to handle the frames.
        fn defaultFrameHandler(_: TContext, _: Frame) !void {
            std.debug.panic("No frame handler set. Set a callback with 'onFrame'\n", .{});
        }

        fn onFrameCallback(ptr: *anyopaque, frame: Frame) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.processFrame(self.context, frame);
        }

        /// Set a callback function that will receive and process the frame.
        pub fn onFrame(self: *Self, callback: FrameHandler) void {
            self.processFrame = callback;
        }

        pub fn init(allocator: std.mem.Allocator, context: TContext, rect: ?Rect) !*Self {
            const self = try allocator.create(Self);
            const capture = try ICapturer.create(allocator, rect, self);
            capture.setFrameHandler(&Self.onFrameCallback);
            self.* = Self{
                .capture = capture,
                .context = context,
                .processFrame = Self.defaultFrameHandler,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.capture.destroy();
        }
    };
}

pub const FrametapError = error{
    ImageCreationFailed,
    PlatformNotSupported,
    PNGConvertFailed,
    GifConvertFailed,
    InternalError,
    /// Failed to write to the GIF file.
    GifFlushFailed,
};
