const std = @import("std");
const quantize = @import("quantize");
const clap = @import("clap");
// A c wrapper around Sean Barrett's stb_image.h
const stb = @cImport(@cInclude("load_image.h"));

const io = std.io;

const ArgError = error{
    missing_input_path,
    failed_to_load_image,
    failed_to_write_image,
};

const RgbImage = struct {
    rgb: []u8,
    width: usize,
    height: usize,
    _c_ptr: *stb.StbImage,

    pub fn fromFile(path: [:0]const u8) !RgbImage {
        const maybe_img: ?*stb.StbImage = stb.load_image_from_file(path.ptr);
        const img = maybe_img orelse return ArgError.failed_to_load_image;
        const size = img.width * img.height * 3;

        return .{
            ._c_ptr = img,
            .rgb = img.data[0..size],
            .width = img.width,
            .height = img.height,
        };
    }

    pub fn writeToFile(self: *const RgbImage, path: [:0]const u8) !void {
        // try std.fs.cwd().writeFile("out.rgb", self.rgb);
        const ok = stb.write_image_to_png(path.ptr, self.rgb.ptr, self.width, self.height);
        if (!ok) {
            return ArgError.failed_to_write_image;
        }
    }

    pub fn deinit(self: *const RgbImage) void {
        stb.free_image(self._c_ptr);
    }
};

/// Configuration options passed from the command line.
const CliConfig = struct {
    allocator: std.mem.Allocator,
    img_path: [:0]const u8,
    out_path: [:0]const u8,
    ncolors: u16 = 16,
    dither: bool = false,

    pub fn deinit(self: *const CliConfig) void {
        self.allocator.free(self.out_path);
    }
};

pub fn parseArguments(allocator: std.mem.Allocator) !?CliConfig {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this message and exit.
        \\-o, --output     <str>    Set the output filepath (default: out.png).
        \\-n, --ncolors    <u16>    Set the number of colors in the output image (default: 16).
        \\-d, --dither     <u16>    Enable or disable dithering.
        \\<str>...
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

    if (res.args.help != 0) {
        try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        return null;
    }

    const output = res.args.output orelse "out.png";
    const output_owned = try allocator.dupeZ(u8, output);

    const ncolors = res.args.ncolors orelse 16;

    var img_path: ?[:0]const u8 = null;
    for (res.positionals) |pos| {
        img_path = try allocator.dupeZ(u8, pos);
        break;
    }

    const input_path = img_path orelse return ArgError.missing_input_path;

    return CliConfig{
        .allocator = allocator,
        .out_path = output_owned,
        .ncolors = ncolors,
        .img_path = input_path,
        .dither = (res.args.dither orelse 1) > 0,
    };
}

pub fn doQuantization(
    allocator: std.mem.Allocator,
    image: *RgbImage,
    ncolors: u16,
    dither: bool,
) !void {
    const size = (image.width * image.height);
    const bgra = try allocator.alloc(u8, size * 4);
    defer allocator.free(bgra);

    for (0..size) |i| {
        const r = image.rgb[i * 3 + 0];
        const g = image.rgb[i * 3 + 1];
        const b = image.rgb[i * 3 + 2];

        bgra[i * 4 + 0] = b;
        bgra[i * 4 + 1] = g;
        bgra[i * 4 + 2] = r;
        bgra[i * 4 + 3] = 255;
    }

    const q = try quantize.reduceColors(
        allocator,
        bgra,
        image.width,
        image.height,
        ncolors,
        dither,
    );
    defer q.deinit(allocator);

    for (0..size) |i| {
        const ct_index = @as(usize, q.image_buffer[i]) * 3;
        const r = q.color_table[ct_index + 0];
        const g = q.color_table[ct_index + 1];
        const b = q.color_table[ct_index + 2];

        image.rgb[i * 3 + 0] = r;
        image.rgb[i * 3 + 1] = g;
        image.rgb[i * 3 + 2] = b;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const maybe_config = parseArguments(allocator) catch |err| {
        switch (err) {
            ArgError.missing_input_path => {
                _ = try io.getStdErr().write("Missing input image path\n");
                return;
            },

            else => return err,
        }
    };

    const config = maybe_config orelse return;
    defer config.deinit();

    var image = RgbImage.fromFile(config.img_path) catch |err| {
        switch (err) {
            ArgError.failed_to_load_image => {
                _ = try io.getStdErr().write("Failed to load image\n");
                return;
            },

            else => return err,
        }
    };
    defer image.deinit();

    try doQuantization(allocator, &image, config.ncolors, config.dither);
    try image.writeToFile("out.png");
    std.debug.print("Wrote image with dimensions: {}x{}\n", .{ image.width, image.height });
}
