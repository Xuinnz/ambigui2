// web_main.zig — WASM / Emscripten entry point
//
// Emscripten cannot run a blocking while-loop: it owns the browser event loop.
// The page (web/index.html) calls `game_init` once and then `updateFrame`
// every animation frame. Browsers give us no threads here, so the AI runs a
// time-boxed slice of its search each frame instead (see IncrementalAi).
//
// All state lives in statics: nothing is heap allocated.

const rl = @import("ui/rl.zig").c;
const renderer = @import("ui/renderer.zig");
const app_mod = @import("ui/app.zig");
const config = @import("config");

extern fn emscripten_get_now() f64;
extern fn emscripten_random() f32;

fn nowMs() f64 {
    return emscripten_get_now();
}

fn randomSeed() u64 {
    // Two random draws mixed with the clock; good enough to vary piece sequences.
    const hi: u64 = @intFromFloat(emscripten_random() * 4294967295.0);
    const lo: u64 = @intFromFloat(emscripten_random() * 4294967295.0);
    const clock: u64 = @intFromFloat(emscripten_get_now() * 1000.0);
    return ((hi << 32) | lo) ^ clock;
}

const WebAi = app_mod.IncrementalAi(nowMs);
const WebApp = app_mod.App(WebAi);

var ai: WebAi = .{};
var app: WebApp = undefined;

// ── Per-frame callback, driven by requestAnimationFrame ──────────────────────
export fn updateFrame() void {
    app.frame(@intFromFloat(nowMs()));
}

// ── Entry point ────────────────────────────────────────────────────────────────
export fn game_init() void {
    rl.InitWindow(renderer.WIN_W, renderer.WIN_H, "ambigui2");
    renderer.preloadAssets();
    app = WebApp.init(&ai, config.seed, randomSeed);
}
