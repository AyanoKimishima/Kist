const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/kist.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library
    const lib = b.addLibrary(.{
        .name = "kist",
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Tests
    const lib_tests = b.addTest(.{
        .root_module = lib_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // Benchmark
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kist", .module = lib_module },
        },
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmark");
    bench_step.dependOn(&run_bench.step);

    // Multi-threaded benchmark
    const bench_mt_module = b.createModule(.{
        .root_source_file = b.path("src/bench_mt.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kist", .module = lib_module },
        },
    });
    const bench_mt_exe = b.addExecutable(.{
        .name = "bench_mt",
        .root_module = bench_mt_module,
    });
    b.installArtifact(bench_mt_exe);
    const run_bench_mt = b.addRunArtifact(bench_mt_exe);
    const bench_mt_step = b.step("bench-mt", "Run multi-threaded benchmark");
    bench_mt_step.dependOn(&run_bench_mt.step);
}
