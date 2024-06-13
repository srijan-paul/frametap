pub const core = @import("frametap");
const std = @import("std");
const zgif = @import("zgif");
const Timer = @import("timer.zig");
const Queue = @import("util/queue.zig").Queue;

const Thread = std.Thread;

const RecordError = error{
    capture_not_started,
};

const GifRecorder = struct {
    const Self = @This();

    const FrameTap = core.FrameTap(*RecorderContext);

    /// Data shared between the children threads of `GifRecorder`.
    const RecorderContext = struct {
        /// This lock must be held when accessing anything in this struct.
        mutex: Thread.Mutex = .{},
        /// Pinged by the producer thread when a new frame is available.
        frame_ready: Thread.Semaphore = .{},
        /// Queue of unprocessed frames.
        unprocessed_frames: Queue(core.Frame),
        /// Set to `true` by the producer when there are no more new frames.
        all_frames_produced: bool = false,
        /// Pinged by the consumer thread when all frames are processed.
        all_frames_consumed: Thread.Semaphore = .{},
        frametap: *FrameTap,
    };

    allocator: std.mem.Allocator,
    context: *RecorderContext,
    capture_thread: ?Thread = null,
    frame_consumer_thread: ?Thread = null,

    // held by the consumer thread
    gif: *zgif.Gif,
    gif_error: *?anyerror = null,

    /// Pop a frame off the queue and add it to the GIF.
    fn processFrame(frame: core.Frame, gif: *zgif.Gif, gif_error: *?anyerror) void {
        gif.addFrame(.{
            .bgra_buf = frame.image.data,
            .duration_ms = @intFromFloat(frame.duration_ms),
        }) catch |err| {
            gif_error.* = err;
        };
    }

    pub fn consumer(
        ctx: *RecorderContext,
        gif: *zgif.Gif,
        gif_error: *?anyerror,
    ) void {
        while (true) {
            ctx.frame_ready.wait();

            ctx.mutex.lock();
            if (ctx.all_frames_produced) {
                break;
            }

            std.debug.assert(!ctx.unprocessed_frames.isEmpty());
            const frame: core.Frame = ctx.unprocessed_frames.pop() catch
                unreachable;
            ctx.mutex.unlock();

            processFrame(frame, gif, gif_error);
        }

        while (!ctx.unprocessed_frames.isEmpty()) {
            const frame: core.Frame = ctx.unprocessed_frames.pop() catch
                unreachable;
            processFrame(frame, gif, gif_error);
        }

        ctx.all_frames_consumed.post();
        ctx.mutex.unlock();

        gif.close() catch |err| {
            gif_error.* = err;
        };
    }

    pub fn init(allocator: std.mem.Allocator, config: zgif.GifConfig) !Self {
        var self: Self = undefined;
        self.allocator = allocator;

        const context = try allocator.create(RecorderContext);
        const frametap = try FrameTap.init(allocator, context, core.Rect{
            .x = 0,
            .y = 51,
            .width = @floatFromInt(config.width),
            .height = @floatFromInt(config.height),
        });
        frametap.onFrame(onFrameReceived);

        context.* = RecorderContext{
            .unprocessed_frames = try Queue(core.Frame).init(allocator),
            .frametap = frametap,
        };

        self.gif = try allocator.create(zgif.Gif);
        self.gif.* = try zgif.Gif.init(allocator, config);

        self.gif_error = try allocator.create(?anyerror);
        self.gif_error.* = null;

        self.context = context;
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.context.frametap.deinit();
        self.gif.deinit();

        self.allocator.destroy(self.gif_error);
        self.allocator.destroy(self.gif);
        self.allocator.destroy(self.context);
    }

    fn onFrameReceived(ctx: *RecorderContext, frame: core.Frame) !void {
        // std.debug.print("got frame {any}\n", .{ctx.mutex});
        ctx.mutex.lock();
        try ctx.unprocessed_frames.push(frame);
        ctx.frame_ready.post();
        ctx.mutex.unlock();
    }

    fn startCaptureImpl(ctx: *RecorderContext) !void {
        try ctx.frametap.capture.begin();
    }

    pub fn startCapture(self: *Self) !void {
        self.capture_thread = try Thread.spawn(.{}, Self.startCaptureImpl, .{self.context});
        self.frame_consumer_thread = try Thread.spawn(.{}, Self.consumer, .{
            self.context,
            self.gif,
            self.gif_error,
        });
    }

    pub fn endCapture(self: *Self) !void {
        var capture_thread: Thread = self.capture_thread orelse
            return RecordError.capture_not_started;
        var consumer_thread = self.frame_consumer_thread orelse
            return RecordError.capture_not_started;

        std.debug.print("end capture requested\n", .{});
        self.context.mutex.lock();

        try self.context.frametap.capture.end();
        capture_thread.join();
        self.context.all_frames_produced = true;

        self.context.mutex.unlock();
        self.context.frame_ready.post();

        std.debug.print("waiting for consumer thread\n", .{});
        consumer_thread.join();

        if (self.gif_error.*) |err| {
            return err;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const gif_config = zgif.GifConfig{
        .width = 466,
        .height = 264 - 51,
        .path = "out.gif",
    };

    var recorder = try GifRecorder.init(allocator, gif_config);
    defer recorder.deinit();

    try recorder.startCapture();
    std.time.sleep(std.time.ns_per_s * 6);
    recorder.endCapture() catch |err| {
        std.debug.print("error: {}\n", .{err});
    };
}
