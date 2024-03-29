const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "jif",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "main",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const objc = b.dependency("zig-objc", .{});
    exe.root_module.addImport("objc", objc.module("objc"));
    exe.linkSystemLibrary("objc");
    exe.linkFramework("Foundation");
    exe.linkFramework("AppKit");
    exe.linkFramework("ScreenCaptureKit");
    exe.linkFramework("CoreVideo");
    exe.linkFramework("CoreMedia");

    exe.addIncludePath(std.Build.LazyPath.relative("native"));
    exe.addObjectFile(std.Build.LazyPath.relative("native/screencap.o"));

    const giflib_objects = [_][:0]const u8{
        "vendor/giflib/lib/egif_lib.o",
        "vendor/giflib/lib/dgif_lib.o",
        "vendor/giflib/lib/gifalloc.o",
        "vendor/giflib/lib/gif_err.o",
        "vendor/giflib/lib/gif_hash.o",
        "vendor/giflib/lib/quantize.o",
        "vendor/giflib/lib/openbsd-reallocarray.o",
    };

    exe.addIncludePath(std.Build.LazyPath.relative("vendor/giflib/lib"));
    for (giflib_objects) |objpath| {
        exe.addObjectFile(std.Build.LazyPath.relative(objpath));
    }

    lib.root_module.addImport("objc", objc.module("objc"));
    lib.linkSystemLibrary("objc");
    lib.linkFramework("Foundation");
    lib.linkFramework("AppKit");
    lib.addIncludePath(std.Build.LazyPath.relative("native"));

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_exe.step);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);
    b.installArtifact(exe);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
