// web_main.zig — WASM / Emscripten entry point (solo mode only, no AI thread)
//
// Emscripten cannot run a blocking while-loop: it owns the browser event loop.
// Instead we register `updateFrame` as the per-frame callback via
// emscripten_set_main_loop, then return from main() immediately.
//
// All state that must survive across frames lives in `AppContext`, allocated
// on the heap once during init and stored in the module-level `ctx` pointer.

const std = @import("std");
const rl = @cImport(@cInclude("raylib.h"));
const game_mod = @import("engine/game.zig");
const renderer = @import("ui/web_renderer.zig");
const config = @import("config");

const GameState = game_mod.GameState;
const SEED: u64 = config.seed;

const GRAVITY_MS: i64 = 1000;
const SOFT_DROP_MS: i64 = 60;
extern fn emscripten_get_now() f64;

// ── App states (solo-only subset) ─────────────────────────────────────────────
const AppState = enum {
    Landing,
    Playing,
    GameOver,
};

// ── All per-frame mutable state in one heap struct ─────────────────────────────
const AppContext = struct {
    app_state: AppState,
    player: GameState,
    last_gravity: i64,
};

// Module-level pointer — set once in main(), read every frame in updateFrame()
var ctx: *AppContext = undefined;

// ── Per-frame callback — registered with emscripten_set_main_loop ──────────────
export fn updateFrame() void {
    const now = @as(i64, @intFromFloat(emscripten_get_now()));

    switch (ctx.app_state) {

        // ── Landing page ───────────────────────────────────────────────────────
        .Landing => {
            // drawLandingFrame returns the chosen GameMode on click, else null.
            // We only care about Solo here; VsAI is desktop-only.
            if (renderer.drawLandingFrame()) |_| {
                ctx.player = GameState.init(SEED);
                ctx.last_gravity = now;
                ctx.app_state = .Playing;
            }
        },

        // ── Solo gameplay ──────────────────────────────────────────────────────
        .Playing => {
            if (!ctx.player.game_over) {
                if (rl.IsKeyPressed(rl.KEY_LEFT)) ctx.player.tryMoveHorizontal(-1);
                if (rl.IsKeyPressed(rl.KEY_RIGHT)) ctx.player.tryMoveHorizontal(1);
                if (rl.IsKeyPressed(rl.KEY_UP)) ctx.player.tryRotateCW();
                if (rl.IsKeyPressed(rl.KEY_C)) ctx.player.tryHold();
                if (rl.IsKeyPressed(rl.KEY_SPACE)) ctx.player.hardDrop();

                if (rl.IsKeyDown(rl.KEY_DOWN)) {
                    if (now - ctx.last_gravity >= SOFT_DROP_MS) {
                        _ = ctx.player.tickGravity();
                        ctx.last_gravity = now;
                    }
                } else if (now - ctx.last_gravity >= GRAVITY_MS) {
                    _ = ctx.player.tickGravity();
                    ctx.last_gravity = now;
                }

                if (ctx.player.game_over) {
                    ctx.app_state = .GameOver;
                }
            }

            renderer.drawSoloFrame(&ctx.player);
        },

        // ── Game over — wait for R to return to landing ────────────────────────
        .GameOver => {
            renderer.drawSoloFrame(&ctx.player); // keeps the frozen board visible

            if (rl.IsKeyPressed(rl.KEY_R)) {
                ctx.app_state = .Landing;
            }
        },
    }
}

// ── Emscripten glue (only linked when targeting wasm32-emscripten) ─────────────
extern fn emscripten_set_main_loop(
    func: *const fn () callconv(.C) void,
    fps: c_int,
    simulate_infinite_loop: c_int,
) void;

// ── Entry point ────────────────────────────────────────────────────────────────
export fn game_init() void {
    rl.InitWindow(renderer.WIN_W, renderer.WIN_H, "ambigui2");
    rl.SetTargetFPS(60);
    renderer.preloadAssets();

    ctx = std.heap.page_allocator.create(AppContext) catch return;
    ctx.* = .{
        .app_state = .Landing,
        .player = GameState.init(SEED),
        .last_gravity = @as(i64, @intFromFloat(emscripten_get_now())),
    };
}
