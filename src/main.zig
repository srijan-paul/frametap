const std = @import("std");
const clap = @import("clap");

const io = std.io;

const ArgError = error{
    bad_resolution,
    no_resolution,
    no_duration,
};

pub fn parseResolution(resolution_str: []const u8) ![2]usize {
    var index_of_x: ?usize = null;
    for (0.., resolution_str) |i, char| {
        if (char == 'x') {
            index_of_x = i;
            break;
        }
    }

    const x_index = index_of_x orelse
        return ArgError.bad_resolution;

    const width_str = resolution_str[0..x_index];
    const height_str = resolution_str[x_index + 1 ..];

    const width = std.fmt.parseInt(usize, width_str, 10) catch
        return ArgError.bad_resolution;
    const height = std.fmt.parseInt(usize, height_str, 10) catch
        return ArgError.bad_resolution;

    return .{ width, height };
}

/// Configuration options passed from the command line.
const CliConfig = struct {
    allocator: std.mem.Allocator,

    x: usize = 0,
    y: usize = 0,
    gif_width: usize,
    gif_height: usize,

    duration_seconds: f64,
    out_path: []const u8,

    pub fn deinit(self: *const CliConfig) void {
        self.allocator.free(self.out_path);
    }
};

pub fn parseArguments(allocator: std.mem.Allocator) !CliConfig {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\-r, --resolution <str>    <width>x<height> Set the dimensions of the image.
        \\-d, --duration   <f64>    Set the duration of the GIF (in seconds).
        \\-o, --output     <str>    Set the output file (default – out.gif).
    );

    var diag = clap.Diagnostic{};

    const res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    const resolution = if (res.args.resolution) |res_str|
        try parseResolution(res_str)
    else {
        _ = try io.getStdErr().write("Resolution is required (e.g -r 400x400)\n");
        return ArgError.no_resolution;
    };

    const duration = if (res.args.duration) |dur| dur else {
        _ = try io.getStdErr().write("Duration is required (e.g -d 100)\n");
        return ArgError.no_duration;
    };

    const output = res.args.output orelse "out.gif";
    const output_owned = try allocator.dupe(u8, output);

    return CliConfig{
        .allocator = allocator,
        .x = 0,
        .y = 0,
        .gif_width = resolution[0],
        .gif_height = resolution[1],
        .duration_seconds = duration,
        .out_path = output_owned,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try parseArguments(allocator);
    defer args.deinit();

    std.debug.print("args: {s}\n", .{args.out_path});
}
