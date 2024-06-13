const std = @import("std");
const builtin = @import("builtin");

const Step = std.Build.Step;

fn addCaptureLib(compile: *Step.Compile) void {
    compile.addIncludePath(std.Build.LazyPath.relative("native"));
    compile.addObjectFile(std.Build.LazyPath.relative("native/screencap.o"));
}

fn addCGif(compile: *Step.Compile) void {
    compile.addIncludePath(std.Build.LazyPath.relative("vendor/cgif/inc"));
    compile.addCSourceFile(.{ .file = std.Build.LazyPath.relative("vendor/cgif/src/cgif.c") });
    compile.addCSourceFile(.{ .file = std.Build.LazyPath.relative("vendor/cgif/src/cgif_raw.c") });
}

fn addPngLib(compile: *Step.Compile) void {
    compile.addIncludePath(std.Build.LazyPath.relative("vendor/lodepng"));
    compile.addObjectFile(std.Build.LazyPath.relative("vendor/lodepng/lodepng.o"));
}

fn addMacosDeps(b: *std.Build, compile: *Step.Compile) void {
    const objc = b.dependency("zig-objc", .{});
    compile.root_module.addImport("objc", objc.module("objc"));
    compile.linkSystemLibrary("objc");
    compile.linkFramework("Foundation");
    compile.linkFramework("AppKit");
    compile.linkFramework("ScreenCaptureKit");
    compile.linkFramework("CoreVideo");
    compile.linkFramework("CoreMedia");
}

fn addImport(
    compile: *Step.Compile,
    name: [:0]const u8,
    module: *std.Build.Module,
) void {
    compile.root_module.addImport(name, module);
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const timerModule = b.addModule("timer", .{ .root_source_file = .{ .path = "src/timer.zig" } });

    const quantizeLib = b.addStaticLibrary(.{
        .name = "quantize",
        .root_source_file = .{ .path = "src/quantize/quantize.zig" },
        .target = target,
        .optimize = optimize,
    });
    addImport(quantizeLib, "timer", timerModule);

    const quantizeModule = &quantizeLib.root_module;

    const zgifLibrary = b.addStaticLibrary(.{
        .name = "zgif",
        .root_source_file = .{ .path = "src/gif/gif.zig" },
        .target = target,
        .optimize = optimize,
    });
    addCGif(zgifLibrary);
    addImport(zgifLibrary, "quantize", quantizeModule);

    const zgifModule = &zgifLibrary.root_module;

    const library = b.addStaticLibrary(.{
        .name = "frametap",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/lib/core.zig" },
        .target = target,
        .optimize = optimize,
    });

    addImport(library, "zgif", zgifModule);
    addCaptureLib(library);
    addPngLib(library);
    b.installArtifact(library);

    {
        const exe = b.addExecutable(.{
            .name = "main",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
        });

        addImport(exe, "zgif", zgifModule);
        addImport(exe, "frametap", &library.root_module);
        addMacosDeps(b, exe);

        b.installArtifact(exe);

        const run_exe = b.addRunArtifact(exe);
        const run_step = b.step("run", "Run the executable");
        run_step.dependOn(&run_exe.step);
    }

    {
        const benchmark_exe = b.addExecutable(.{
            .name = "benchmark",
            .root_source_file = .{ .path = "src/quantize/kdtree-benchmark.zig" },
            .target = target,
            .optimize = std.builtin.OptimizeMode.ReleaseFast,
        });

        addImport(benchmark_exe, "timer", timerModule);
        b.installArtifact(benchmark_exe);
    }

    // TODO: re-add the C library
    // {
    //     const dll = b.addSharedLibrary(.{
    //         .name = "frametap",
    //         .root_source_file = .{ .path = "src/lib.zig" },
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //
    //     addMacosDeps(b, dll);
    //     addCaptureLib(dll);
    //
    //     const dll_artifact = b.addInstallArtifact(dll, .{});
    //     const dll_step = b.step("dll", "Make shared library");
    //     dll_step.dependOn(&dll_artifact.step);
    //
    //     b.installArtifact(dll);
    // }
    //
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
