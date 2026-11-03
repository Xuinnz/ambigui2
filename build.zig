const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Configurable AI options ───────────────────────────────────────────────
    const ai_seed = b.option(u64, "seed", "RNG seed for the game (0 = random each run)") orelse 0;
    const ai_depth = b.option(u32, "depth", "Expectimax search depth in pieces (max 3)") orelse 3;
    const ai_beam = b.option(usize, "beam", "Beam search width") orelse 8;

    const ai_options = b.addOptions();
    ai_options.addOption(u64, "seed", ai_seed);
    ai_options.addOption(u32, "ai_depth", ai_depth);
    ai_options.addOption(usize, "ai_beam_width", ai_beam);

    // data/weights.json, embedded so binaries do not depend on the working directory.
    const weights_files = b.addWriteFiles();
    _ = weights_files.addCopyFile(b.path("data/weights.json"), "weights.json");
    const weights_mod = b.createModule(.{
        .root_source_file = weights_files.add("trained_weights.zig", "pub const json = @embedFile(\"weights.json\");\n"),
    });

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .Wayland,
    });
    const raylib_artifact = raylib_dep.artifact("raylib");

    const Exe = struct {
        name: []const u8,
        src: []const u8,
        step: []const u8,
        description: []const u8,
        raylib: bool = false,
    };
    const exes = [_]Exe{
        .{ .name = "ambigui2", .src = "src/renderer_main.zig", .step = "run", .description = "Run the game", .raylib = true },
        .{ .name = "train", .src = "src/genetic_main.zig", .step = "train", .description = "Run the weight trainer headlessly (pass -- --cmaes for CMA-ES)" },
        .{ .name = "demo", .src = "src/main.zig", .step = "demo", .description = "Run terminal demo" },
        .{ .name = "benchmark", .src = "src/benchmark.zig", .step = "bench", .description = "Benchmark AI strength and speed across seeds" },
        .{ .name = "metrics", .src = "src/metrics.zig", .step = "metrics", .description = "Measure engine performance metrics" },
    };

    for (exes) |spec| {
        const exe = b.addExecutable(.{
            .name = spec.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(spec.src),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        exe.root_module.addOptions("config", ai_options);
        exe.root_module.addImport("trained_weights", weights_mod);
        if (spec.raylib) {
            exe.linkLibrary(raylib_artifact);
            // raylib's static archive lists the system .so files it needs as
            // members; LLD warns about them and Zig 0.15 fails the build on any
            // linker warning. Zig's own ELF linker handles them.
            exe.use_lld = false;
        }
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step(spec.step, spec.description);
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trained_weights", weights_mod);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);

    // ── Web build ─────────────────────────────────────────────────────────────
    // The game logic is compiled by Zig to a wasm object, then linked by emcc
    // against a raylib built for the web (libs/wasm, see README).
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
    wasm.root_module.addImport("trained_weights", weights_mod);
    wasm.addIncludePath(b.path("libs/wasm/include"));

    const wasm_step = b.step("wasm", "Build WASM object file");
    const install_obj = b.addInstallFile(wasm.getEmittedBin(), "lib/game.o");
    wasm_step.dependOn(&install_obj.step);

    const emcc_path = b.option([]const u8, "emcc", "Path to emcc (default: emcc on PATH)") orelse "emcc";
    const emcc = b.addSystemCommand(&.{emcc_path});
    emcc.addFileArg(wasm.getEmittedBin());
    emcc.addFileArg(b.path("libs/wasm/libraylib.a"));
    emcc.addArgs(&.{
        "-sUSE_GLFW=3",
        "-sSTACK_SIZE=1048576",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sEXPORTED_FUNCTIONS=['_game_init','_updateFrame']",
        "-O2",
        "--preload-file",
    });
    // Mounted at /web-assets in the browser's virtual filesystem.
    emcc.addDecoratedDirectoryArg("", b.path("web-assets"), "@/web-assets");
    emcc.addArg("-o");
    const game_js = emcc.addOutputFileArg("game.js");
    // emcc writes game.wasm and game.data next to game.js.
    const web_dir = game_js.dirname();

    const install_web = b.addInstallDirectory(.{
        .source_dir = web_dir,
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    const install_shell = b.addInstallFile(b.path("web/index.html"), "web/index.html");
    const web_step = b.step("web", "Build the browser version into zig-out/web (needs emsdk)");
    web_step.dependOn(&install_web.step);
    web_step.dependOn(&install_shell.step);
}
