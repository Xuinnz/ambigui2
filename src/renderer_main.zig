//Desktop entry point: raylib window, AI searching on a background thread.
const std = @import("std");
const rl = @import("ui/rl.zig").c;
const renderer = @import("ui/renderer.zig");
const app_mod = @import("ui/app.zig");
const agent = @import("ai/agent.zig");
const ai_worker_mod = @import("ai/worker.zig");
const config = @import("config");

const GameState = agent.GameState;
const AiWorker = ai_worker_mod.AiWorker;

/// Adapts the threaded worker to the interface `App` expects.
const ThreadedAi = struct {
    worker: AiWorker,

    pub fn configure(self: *ThreadedAi, profile: agent.Profile) void {
        self.worker.reconfigure(profile.search, profile.weights);
    }

    pub fn post(self: *ThreadedAi, state: *const GameState) void {
        self.worker.post(state);
    }

    pub fn poll(self: *ThreadedAi) ??agent.Move {
        return self.worker.poll();
    }

    pub fn update(_: *ThreadedAi) void {}
};

fn randomSeed() u64 {
    return std.crypto.random.int(u64);
}

pub fn main() !void {
    rl.InitWindow(renderer.WIN_W, renderer.WIN_H, "ambigui2");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // Preload ALL assets before the game loop — no mid-game freezes
    renderer.preloadAssets();

    const medium = agent.profileFor(.Medium);
    var ai = ThreadedAi{ .worker = AiWorker.init(medium.search, medium.weights) };
    const ai_thread = try std.Thread.spawn(.{}, ai_worker_mod.aiThreadEntry, .{&ai.worker});
    defer {
        ai.worker.stop();
        ai_thread.join();
    }

    var app = app_mod.App(ThreadedAi).init(&ai, config.seed, randomSeed);
    while (!rl.WindowShouldClose()) {
        app.frame(std.time.milliTimestamp());
    }
}
