const std = @import("std");
const rl = @import("raylib");
const game_mod = @import("engine/game.zig");
const renderer = @import("ui/renderer.zig");
const ai_worker_mod = @import("ai/worker.zig");

const GameState = game_mod.GameState;
const AiWorker = ai_worker_mod.AiWorker;
const heuristics = @import("ai/heuristics.zig");
const config = @import("config");

const AI_STEP_MS: i64 = 1000; // minimum time between moves (visual pacing)
const AI_RESTART_MS: i64 = 2000;
const AI_GRAVITY_MS: i64 = 500;
const GRAVITY_MS: i64 = 500;
const SOFT_DROP_MS: i64 = 60;
const SEED: u64 = config.seed;
const AI_DEPTH: u32 = config.ai_depth;
const AI_BEAM_WIDTH: usize = config.ai_beam_width;

const LANDING_ASSET: [:0]const u8 = "assets/landing_page/resized_main_page.png";
const LANDING_BG = rl.Color{ .r = 18, .g = 18, .b = 18, .a = 255 };

// Normalized hit box on main_page.png for the "Player vs AI" pill
const PVP_HIT_X_NORM: f32 = 0.40;
const PVP_HIT_Y_NORM: f32 = 0.685;
const PVP_HIT_W_NORM: f32 = 0.20;
const PVP_HIT_H_NORM: f32 = 0.08;

var landing_texture: ?rl.Texture2D = null;
var show_landing_page: bool = true;

fn initLandingTexture() void {
    if (landing_texture != null) return;
    landing_texture = rl.loadTexture(LANDING_ASSET) catch null;
    if (landing_texture) |tex| {
        rl.setTextureFilter(tex, .bilinear);
    }
}

fn pvpHitRect() rl.Rectangle {
    const w = @as(f32, @floatFromInt(renderer.WIN_W));
    const h = @as(f32, @floatFromInt(renderer.WIN_H));
    return .{
        .x = w * PVP_HIT_X_NORM,
        .y = h * PVP_HIT_Y_NORM,
        .width = w * PVP_HIT_W_NORM,
        .height = h * PVP_HIT_H_NORM,
    };
}

fn drawLandingPage() void {
    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(LANDING_BG);

    const tex = landing_texture orelse return;
    const src: rl.Rectangle = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(tex.width),
        .height = @floatFromInt(tex.height),
    };
    const dest: rl.Rectangle = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(renderer.WIN_W),
        .height = @floatFromInt(renderer.WIN_H),
    };
    rl.drawTexturePro(tex, src, dest, .{ .x = 0, .y = 0 }, 0, rl.Color.white);

    const mouse = rl.getMousePosition();
    if (rl.isMouseButtonPressed(rl.MouseButton.left) and rl.checkCollisionPointRec(mouse, pvpHitRect())) {
        show_landing_page = false;
        renderer.enterDifficultySelect();
    }
}

pub fn main() !void {
    rl.initWindow(renderer.WIN_W, renderer.WIN_H, "ambigui2");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    initLandingTexture();

    var player = GameState.init(SEED);
    var ai = GameState.init(SEED);

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
    var last_ai_gravity: i64 = std.time.milliTimestamp();
    var last_ai_step: i64 = std.time.milliTimestamp();
    var ai_death_time: i64 = 0;

    while (!rl.windowShouldClose()) {
        if (show_landing_page) {
            drawLandingPage();
            continue;
        }

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

        // ── AI gravity ──────────────────────────────────────────────────
        if (!ai.game_over and now - last_ai_gravity >= AI_GRAVITY_MS) {
            _ = ai.tickGravity();
            last_ai_gravity = now;
            worker.post(&ai);
        }

        // ── AI step — never blocks render ─────────────────────────────────
        if (!ai.game_over) {
            // Only consume result if minimum display time has passed
            if (now - last_ai_step >= AI_STEP_MS) {
                if (worker.poll()) |maybe_move| {
                    last_ai_step = now;
                    if (maybe_move) |move| {
                        ai.applyMove(&move);
                        last_ai_gravity = now;
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
                last_ai_gravity = now;
                ai_death_time = 0;
                worker.post(&ai);
            }
        }

        renderer.drawFrame(&player, &ai);
    }
}
