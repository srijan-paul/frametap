const std = @import("std");
const objc = @import("objc");
const c = @cImport(@cInclude("CoreGraphics/CoreGraphics.h"));

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const CaptureContext = struct {
    const Self = @This();
    const CaptureFun = *const (fn (*Self) anyerror!void);
    const RecordFun = *const (fn (*Self, u32) anyerror!void);

    allocator: std.mem.Allocator,
    rect: Rect,
    frames: std.ArrayList([]u8),
    captureFn: CaptureFun,
    recordFn: RecordFun,

    pub fn init(
        rect: Rect,
        captureFn: CaptureFun,
        recordFn: RecordFun,
        allocator: std.mem.Allocator,
    ) Self {
        return Self{
            .allocator = allocator,
            .rect = rect,
            .frames = std.ArrayList([]u8).init(allocator),
            .captureFn = captureFn,
            .recordFn = recordFn,
        };
    }

    pub fn captureFrame(self: *Self) void {
        self.captureFn(self);
    }

    pub fn record(self: *Self, duration: u32) void {
        self.recordFn(self, duration);
    }
};

pub const JifError = error{
    NSStringClassNotFound,
    NSBitmapImageRepClassNotFound,
    NSDictionaryClassNotFound,
    ImageCreationFailed,
    PNGConvertFailed,
    GifConvertFailed,
    /// Failed to write to the GIF file.
    GifFlushFailed,
};
