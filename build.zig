const std = @import("std");
const rlz = @import("raylib_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
            .optimize = optimize,
            .target = target,
        }),
    });
    exe.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);

    // Training executable — always ReleaseFast
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
}
