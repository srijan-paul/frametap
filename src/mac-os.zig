const std = @import("std");
const c = @cImport(@cInclude("CoreGraphics/CoreGraphics.h"));
const objc = @import("objc");
const core = @import("core.zig");

const JifError = core.JifError;
const CaptureContext = core.CaptureContext;
const Rect = core.Rect;

pub const MacOSCaptureContext = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    ctx: core.CaptureContext,

    displayID: u32,
    color_space: c.CGColorSpaceRef,
    cg_rect: c.CGRect,
    cg_bitmap_context: c.CGContextRef,

    // CoreGraphics class handles from Objective-C runtime.
    NSString: objc.Class,
    NSBitmapImageRep: objc.Class,
    NSDictionary: objc.Class,

    pub fn captureFrame(self: *Self) !void {
        const imageRef = c.CGWindowListCreateImage(
            self.cg_rect,
            c.kCGWindowListOptionOnScreenOnly,
            c.kCGNullWindowID,
            c.kCGWindowImageDefault,
        ) orelse return JifError.ImageCreationFailed;

        var bitmap = self.NSBitmapImageRep.msgSend(objc.Object, "alloc", .{});
        bitmap = bitmap.msgSend(objc.Object, "initWithCGImage:", .{imageRef});

        const emptyDict = self.NSDictionary.msgSend(objc.Object, "dictionary", .{});
        const NSFileTypeGIF: u64 = 4;
        const gifData = bitmap.msgSend(
            objc.Object,
            "representationUsingType:properties:",
            .{ NSFileTypeGIF, emptyDict },
        );
        defer gifData.msgSend(void, "release", .{});

        const length = gifData.msgSend(u64, "length", .{});
        const bytes = gifData.msgSend([*c]u8, "bytes", .{});
        const buf = try self.allocator.alloc(u8, length);

        for (0..length) |i| {
            buf[i] = bytes[i];
        }

        return self.ctx.frames.append(buf);
    }

    fn capture(ctx: *CaptureContext) !void {
        const self = @fieldParentPtr(Self, "ctx", ctx);
        return self.captureFrame();
    }

    fn record(ctx: *CaptureContext, _: u32) !void {
        const self = @fieldParentPtr(Self, "ctx", ctx);
        _ = self;
    }

    pub fn init(rect: Rect, allocator: std.mem.Allocator) JifError!MacOSCaptureContext {
        const nsstring = objc.getClass("NSString") orelse return JifError.NSStringClassNotFound;
        const nsbitmapimagerep = objc.getClass("NSBitmapImageRep") orelse return JifError.NSBitmapImageRepClassNotFound;
        const nsdictionary = objc.getClass("NSDictionary") orelse return JifError.NSDictionaryClassNotFound;

        const colorspace = c.CGColorSpaceCreateDeviceRGB();
        const cg_rect = c.CGRectMake(rect.x, rect.y, rect.width, rect.height);
        return MacOSCaptureContext{
            .allocator = allocator,
            .ctx = CaptureContext.init(rect, capture, record, allocator),
            .displayID = c.CGMainDisplayID(),
            .color_space = colorspace,
            .NSString = nsstring,
            .NSBitmapImageRep = nsbitmapimagerep,
            .NSDictionary = nsdictionary,
            .cg_rect = cg_rect,
            .cg_bitmap_context = c.CGBitmapContextCreate(
                null,
                @intFromFloat(rect.width),
                @intFromFloat(rect.height),
                8,
                0,
                colorspace,
                c.kCGImageAlphaPremultipliedLast,
            ),
        };
    }

    pub fn deinit(self: MacOSCaptureContext) void {
        c.CGColorSpaceRelease(self.color_space);
        c.CGContextRelease(self.cg_bitmap_context);
    }
};
