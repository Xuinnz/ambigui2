const std = @import("std");
const rlz = @import("raylib_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Configurable AI options ───────────────────────────────────────────────
    const ai_seed = b.option(u64, "seed", "RNG seed for the game") orelse 444;
    const ai_depth = b.option(u32, "depth", "Expectimax search depth") orelse 5;
    const ai_beam = b.option(usize, "beam", "Beam search width") orelse 8;

    const ai_options = b.addOptions();
    ai_options.addOption(u64, "seed", ai_seed);
    ai_options.addOption(u32, "ai_depth", ai_depth);
    ai_options.addOption(usize, "ai_beam_width", ai_beam);

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .Wayland,
    });
    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    // Game executable
    const exe = b.addExecutable(.{
        .name = "ambigui2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/renderer_main.zig"),
            .optimize = .ReleaseFast,
            .target = target,
        }),
    });
    exe.root_module.addOptions("config", ai_options);
    exe.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);

    // Training executable
    const train_exe = b.addExecutable(.{
        .name = "train",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/genetic_main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(train_exe);

    const train_cmd = b.addRunArtifact(train_exe);
    const train_step = b.step("train", "Run genetic trainer headlessly");
    train_step.dependOn(&train_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);

    // Demo
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    demo.root_module.addOptions("config", ai_options);
    b.installArtifact(demo);

    const demo_cmd = b.addRunArtifact(demo);
    const demo_step = b.step("demo", "Run terminal demo");
    demo_step.dependOn(&demo_cmd.step);

    // Benchmark
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_exe.root_module.addOptions("config", ai_options);
    b.installArtifact(bench_exe);
    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Benchmark AI across seeds");
    bench_step.dependOn(&bench_cmd.step);

    const metrics_exe = b.addExecutable(.{
        .name = "metrics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/metrics.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(metrics_exe);
    const metrics_cmd = b.addRunArtifact(metrics_exe);
    const metrics_step = b.step("metrics", "Measure performance metrics");
    metrics_step.dependOn(&metrics_cmd.step);

    // ── WASM Build Target ─────────────────────────────────────────────────────
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm = b.addObject(.{
        .name = "game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.root_module.addOptions("config", ai_options);
    wasm.addIncludePath(b.path("libs/wasm/include"));

    const wasm_step = b.step("wasm", "Build WASM object file");
    const install_obj = b.addInstallFile(wasm.getEmittedBin(), "lib/game.o");
    wasm_step.dependOn(&install_obj.step);
}
