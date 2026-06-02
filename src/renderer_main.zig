const std = @import("std");
const rl = @import("raylib");
const game_mod = @import("engine/game.zig");
const renderer = @import("ui/renderer.zig");
const ai_worker_mod = @import("ai/worker.zig");
const heuristics = @import("ai/heuristics.zig");
const config = @import("config");
const SEED: u64 = config.seed;

const GameState = game_mod.GameState;
const Weights = game_mod.Weights;
const AiWorker = ai_worker_mod.AiWorker;
const AiGameConfig = renderer.AiGameConfig;
const Difficulty = renderer.Difficulty;
const GameMode = renderer.GameMode;

const GRAVITY_MS: i64 = 500;
const SOFT_DROP_MS: i64 = 60;

const ZERO_WEIGHTS = Weights{
    .w_aggregate = 0,
    .w_holes = 0,
    .w_bumpiness = 0,
    .w_wells = 0,
    .w_row_transitions = 0,
    .w_col_transitions = 0,
};

fn makeConfig(diff: Difficulty, trained: Weights) AiGameConfig {
    return switch (diff) {
        .Easy => .{
            .weights = ZERO_WEIGHTS,
            .depth = 1,
            .beam_width = 1,
            .step_ms = 1000,
        },
        .Medium => .{
            .weights = trained,
            .depth = 1,
            .beam_width = 1,
            .step_ms = 500,
        },
        .Hard => .{
            .weights = trained,
            .depth = 5,
            .beam_width = 20,
            .step_ms = 0,
        },
    };
}

const AppState = enum {
    Landing,
    DifficultySelect,
    PlayingVsAI,
    PlayingSolo,
    BothGameOver,
};

pub fn main() !void {
    rl.initWindow(renderer.WIN_W, renderer.WIN_H, "ambigui2");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    // Preload ALL assets before the game loop — no mid-game freezes
    renderer.preloadAssets();

    // Load trained weights from file (used by Medium and Hard)
    try heuristics.loadTrainedWeights();
    const trained = heuristics.TRAINED_WEIGHTS;

    var app_state: AppState = .Landing;
    var game_mode: GameMode = .VsAI;
    var ai_cfg: AiGameConfig = makeConfig(.Medium, trained);

    var player = GameState.init(SEED);
    var ai = GameState.init(SEED);

    // AI worker — initially with medium config; reconfigured on difficulty select
    var worker = AiWorker.init(ai_cfg.depth, ai_cfg.beam_width, ai_cfg.weights);
    const ai_thread = try std.Thread.spawn(.{}, ai_worker_mod.aiThreadEntry, .{&worker});
    defer {
        worker.stop();
        ai_thread.join();
    }

    var last_gravity: i64 = std.time.milliTimestamp();
    var last_ai_step: i64 = std.time.milliTimestamp();
    var show_winner: bool = false;

    while (!rl.windowShouldClose()) {
        const now = std.time.milliTimestamp();

        switch (app_state) {

            // ── Landing page ──────────────────────────────────────────────────
            .Landing => {
                if (renderer.drawLandingFrame()) |mode| {
                    game_mode = mode;
                    app_state = .DifficultySelect;
                }
            },

            // ── Difficulty select ─────────────────────────────────────────────
            .DifficultySelect => {
                if (renderer.drawDifficultyFrame()) |diff| {
                    ai_cfg = makeConfig(diff, trained);

                    player = GameState.init(SEED);
                    ai = GameState.init(SEED);
                    last_gravity = now;
                    last_ai_step = now;
                    show_winner = false;

                    // Reconfigure the AI worker for the chosen difficulty
                    worker.reconfigure(ai_cfg.depth, ai_cfg.beam_width, ai_cfg.weights);
                    worker.post(&ai);

                    app_state = switch (game_mode) {
                        .VsAI => .PlayingVsAI,
                        .Solo => .PlayingSolo,
                    };
                }
            },

            // ── VS AI gameplay ────────────────────────────────────────────────
            .PlayingVsAI => {
                // Player input
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
                }

                // AI step — never blocks render thread
                if (!ai.game_over) {
                    if (now - last_ai_step >= ai_cfg.step_ms) {
                        if (worker.poll()) |maybe_move| {
                            last_ai_step = now;
                            if (maybe_move) |move| {
                                ai.applyMove(&move);
                                worker.post(&ai);
                            } else {
                                ai.game_over = true;
                            }
                        }
                    }
                }

                // Wait for BOTH to die before showing winner
                if (player.game_over and ai.game_over) {
                    show_winner = true;
                    app_state = .BothGameOver;
                }

                renderer.drawVsAiFrame(&player, &ai, false);
            },

            // ── Solo gameplay ─────────────────────────────────────────────────
            .PlayingSolo => {
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
                    // FIX: R goes back to landing page, not restarts the game
                    app_state = .Landing;
                }

                renderer.drawSoloFrame(&player);
            },

            // ── Both game over — show winner ───────────────────────────────────
            .BothGameOver => {
                renderer.drawVsAiFrame(&player, &ai, true);

                // FIX: R goes back to landing page, not difficulty select
                if (rl.isKeyPressed(.r)) {
                    show_winner = false;
                    app_state = .Landing;
                }
            },
        }
    }
}
