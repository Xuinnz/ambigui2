const std = @import("std");
const rl = @import("raylib");
const game_mod = @import("engine/game.zig");
const renderer = @import("ui/renderer.zig");
const ai_worker_mod = @import("ai/worker.zig");

const GameState = game_mod.GameState;
const AiWorker = ai_worker_mod.AiWorker;
const heuristics = @import("ai/heuristics.zig");

const AI_DEPTH: u32 = 3;
const AI_BEAM_WIDTH: usize = 5;
const AI_STEP_MS: i64 = 0; // minimum time between moves (visual pacing)
const AI_RESTART_MS: i64 = 2000;
const GRAVITY_MS: i64 = 500;
const SOFT_DROP_MS: i64 = 60;

pub fn main() !void {
    rl.initWindow(renderer.WIN_W, renderer.WIN_H, "ambigui2");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var player = GameState.init(42);
    var ai = GameState.init(42);

    // Load trained weights if present
    try heuristics.loadTrainedWeights();

    // Spawn AI worker thread
    var worker = AiWorker.init(AI_DEPTH, AI_BEAM_WIDTH);
    const ai_thread = try std.Thread.spawn(.{}, ai_worker_mod.aiThreadEntry, .{&worker});
    defer {
        worker.stop();
        ai_thread.join();
    }

    // Kick off first computation immediately
    worker.post(&ai);

    var last_gravity: i64 = std.time.milliTimestamp();
    var last_ai_step: i64 = std.time.milliTimestamp();
    var ai_death_time: i64 = 0;

    while (!rl.windowShouldClose()) {
        const now = std.time.milliTimestamp();

        // ── Player input ──────────────────────────────────────────────────
        if (!player.game_over) {
            if (rl.isKeyPressed(.left)) player.tryMoveHorizontal(-1);
            if (rl.isKeyPressed(.right)) player.tryMoveHorizontal(1);
            if (rl.isKeyPressed(.up)) player.tryRotateCW();
            if (rl.isKeyPressed(.c)) player.tryHold();
            if (rl.isKeyPressed(.space)) player.hardDrop();

            if (rl.isKeyDown(.down)) {
                if (now - last_gravity >= SOFT_DROP_MS) {
                    _ = player.tickGravity();
                    last_gravity = now;
                }
            } else if (now - last_gravity >= GRAVITY_MS) {
                _ = player.tickGravity();
                last_gravity = now;
            }
        } else if (rl.isKeyPressed(.r)) {
            player = GameState.init(@as(u64, @intCast(now)));
            last_gravity = now;
        }

        // ── AI step — never blocks render ─────────────────────────────────
        if (!ai.game_over) {
            // Only consume result if minimum display time has passed
            if (now - last_ai_step >= AI_STEP_MS) {
                if (worker.poll()) |maybe_move| {
                    last_ai_step = now;
                    if (maybe_move) |move| {
                        ai.applyMove(&move);
                        worker.post(&ai); // start next computation immediately
                    } else {
                        ai.game_over = true;
                    }
                }
                // null = still computing, renderer keeps running at 60fps
            }
        } else {
            if (ai_death_time == 0) ai_death_time = now;
            if (now - ai_death_time >= AI_RESTART_MS) {
                ai = GameState.init(@as(u64, @intCast(now)));
                last_ai_step = now;
                ai_death_time = 0;
                worker.post(&ai);
            }
        }

        renderer.drawFrame(&player, &ai);
    }
}
