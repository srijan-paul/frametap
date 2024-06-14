const core = @import("frametap");
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
    };

    allocator: std.mem.Allocator,
    context: *RecorderContext,
    producer_thread: ?Thread = null,
    consumer_thread: ?Thread = null,

    // held by the consumer thread
    gif: *zgif.Gif,
    gif_error: *?anyerror,

    frametap: *FrameTap,

    /// Pop a frame off the queue and add it to the GIF.
    fn processFrame(
        imgbuf: []const u8,
        duration: f64,
        gif: *zgif.Gif,
        gif_error: *?anyerror,
    ) void {
        gif.addFrame(.{
            .bgra_buf = imgbuf,
            .duration_ms = @as(u64, @intFromFloat(duration)),
        }) catch |err| {
            gif_error.* = err;
        };
    }

    pub fn consumer(
        ctx: *RecorderContext,
        gif: *zgif.Gif,
        gif_error: *?anyerror,
    ) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();

        var frame_copy: ?[]u8 = null;
        defer {
            if (frame_copy) |buf|
                allocator.free(buf);
        }

        while (true) {
            ctx.frame_ready.wait();
            ctx.mutex.lock();

            if (ctx.all_frames_produced) {
                break;
            }

            std.debug.assert(!ctx.unprocessed_frames.isEmpty());
            const frame: core.Frame = ctx.unprocessed_frames.pop() catch
                unreachable;

            const frame_buffer = frame.image.data;

            // copy the frame to a buffer. Or the reference will be invalidated
            // as the queue re-allocates in memory.
            const buf = if (frame_copy) |buf| buf else blk: {
                const size = frame_buffer.len;
                const buf = try allocator.alloc(u8, size);
                frame_copy = buf;
                break :blk buf;
            };

            @memcpy(buf, frame_buffer);
            const duration = frame.duration_ms;

            // Now that we have a copy of the frame,
            // We no longer need anything in `ctx`, and can release the lock.
            ctx.mutex.unlock();
            processFrame(buf, duration, gif, gif_error);
        }

        while (!ctx.unprocessed_frames.isEmpty()) {
            const frame: core.Frame = ctx.unprocessed_frames.pop() catch
                unreachable;
            processFrame(frame.image.data, frame.duration_ms, gif, gif_error);
        }

        gif.close() catch |err| {
            gif_error.* = err;
        };

        ctx.mutex.unlock();
        ctx.all_frames_consumed.post();
    }

    pub fn init(allocator: std.mem.Allocator, config: zgif.GifConfig) !Self {
        const context = try allocator.create(RecorderContext);
        const frametap = try FrameTap.init(allocator, context, core.Rect{
            .x = 0,
            .y = 51,
            .width = @floatFromInt(config.width),
            .height = @floatFromInt(config.height),
        });

        frametap.onFrame(produceFrame);

        context.* = RecorderContext{ .unprocessed_frames = try Queue(core.Frame).init(allocator) };

        const gif = try allocator.create(zgif.Gif);
        gif.* = try zgif.Gif.init(allocator, config);

        const gif_error = try allocator.create(?anyerror);
        gif_error.* = null;

        return Self{
            .allocator = allocator,
            .context = context,
            .frametap = frametap,
            .gif = gif,
            .gif_error = gif_error,
        };
    }

    pub fn deinit(self: *Self) void {
        self.frametap.deinit();
        self.gif.deinit();

        self.allocator.destroy(self.gif_error);
        self.allocator.destroy(self.gif);
        self.allocator.destroy(self.context);
    }

    fn produceFrame(ctx: *RecorderContext, frame: core.Frame) !void {
        ctx.mutex.lock();
        try ctx.unprocessed_frames.push(frame);
        ctx.mutex.unlock();

        ctx.frame_ready.post();
    }

    fn startCaptureImpl(frametap: *FrameTap) !void {
        try frametap.capture.begin();
    }

    pub fn startCapture(self: *Self) !void {
        self.producer_thread = try Thread.spawn(.{}, startCaptureImpl, .{self.frametap});
        self.consumer_thread = try Thread.spawn(.{}, consumer, .{
            self.context,
            self.gif,
            self.gif_error,
        });
    }

    pub fn endCapture(self: *Self) !void {
        std.debug.print("endCapture\n", .{});

        var capture_thread: Thread = self.producer_thread orelse
            return RecordError.capture_not_started;
        std.debug.print("consumer thread: {?}\n", .{self.consumer_thread});
        var consumer_thread = self.consumer_thread orelse
            return RecordError.capture_not_started;

        std.debug.print("consumer thread: {?} {?}\n", .{ self.consumer_thread, consumer_thread });

        self.context.mutex.lock();
        try self.frametap.capture.end();
        capture_thread.join();
        self.context.all_frames_produced = true;

        self.context.mutex.unlock();
        self.context.frame_ready.post();

        std.debug.print("capture finished, waiting for encoder to finish\n", .{});
        var t = Timer{};
        t.start();

        self.context.all_frames_consumed.wait();
        consumer_thread.join();

        const time = t.end();
        std.debug.print("encoder finished in {} ms\n", .{time});

        if (self.gif_error.*) |err| {
            return err;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const gif_config = zgif.GifConfig{
        .width = 1000,
        .height = 1000,
        .path = "out.gif",
    };

    var recorder = try GifRecorder.init(allocator, gif_config);
    defer recorder.deinit();

    try recorder.startCapture();
    std.time.sleep(std.time.ns_per_s * 6);
    recorder.endCapture() catch |err| {
        std.debug.panic("error: {}\n", .{err});
    };
}
