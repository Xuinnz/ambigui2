//Micro-benchmarks of the engine hot paths and the search.
const std = @import("std");
const game_mod = @import("engine/game.zig");
const physics = @import("engine/physics.zig");
const board_mod = @import("engine/board.zig");
const expectimax = @import("ai/expectimax.zig");
const heuristics = @import("ai/heuristics.zig");

const GameState = game_mod.GameState;
const Weights = game_mod.Weights;
const Board = board_mod.Board;

const DEPTH: u32 = 3;
const BEAM: usize = 8;
const MOVES_TO_SAMPLE: usize = 200;
const COLLISION_ITERS: usize = 1_000_000;
const LINECLEAR_ITERS: usize = 100_000;
const EVAL_ITERS: usize = 1_000_000;

// ── 1. Nodes/sec throughput ───────────────────────────────────────────────────
fn measureNodeThroughput(weights: *const Weights) void {
    var state = GameState.init(42);
    expectimax.node_count = 0;

    var timer = std.time.Timer.start() catch unreachable;

    var i: usize = 0;
    while (i < MOVES_TO_SAMPLE and !state.game_over) : (i += 1) {
        const move = expectimax.bestMoveWithOptions(&state, weights, .{
            .depth = DEPTH,
            .beam_width = BEAM,
        });
        if (move) |m| state.applyMove(&m) else break;
    }

    const elapsed_ns = timer.read();
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const nodes_per_sec = @as(f64, @floatFromInt(expectimax.node_count)) / elapsed_sec;
    const ms_per_move = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0 / @as(f64, @floatFromInt(@max(i, 1)));

    std.debug.print("=== NODE THROUGHPUT (depth={d} beam={d}, hold on) ===\n", .{ DEPTH, BEAM });
    std.debug.print("  Moves sampled:  {d}\n", .{i});
    std.debug.print("  Total nodes:    {d}\n", .{expectimax.node_count});
    std.debug.print("  Elapsed:        {d:.2}s\n", .{elapsed_sec});
    std.debug.print("  Nodes/sec:      {d:.0}k\n", .{nodes_per_sec / 1000.0});
    std.debug.print("  Ms/move:        {d:.2}ms\n\n", .{ms_per_move});
}

// ── 2. Collision check cost ───────────────────────────────────────────────────
fn measureCollisionCost() void {
    var state = GameState.init(42);
    // Fill some rows to make collision non-trivial
    var r: usize = 15;
    while (r < Board.HEIGHT) : (r += 1) {
        state.board.grid[r] = Board.ROW_MASK & 0x00FF; // half-filled rows
    }

    var timer = std.time.Timer.start() catch unreachable;
    var hits: usize = 0;
    var i: usize = 0;
    while (i < COLLISION_ITERS) : (i += 1) {
        var probe = state.current_piece.state_a;
        probe.y = @as(i8, @intCast(i % 20));
        if (physics.checkCollision(&state.board, &probe)) hits += 1;
    }
    std.mem.doNotOptimizeAway(hits);
    const ns_per_call = @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(COLLISION_ITERS));

    std.debug.print("=== COLLISION CHECK COST ===\n", .{});
    std.debug.print("  ns/call:        {d:.2}ns\n\n", .{ns_per_call});
}

// ── 3. Line clear cost ────────────────────────────────────────────────────────
fn measureLineClearCost() void {
    var timer = std.time.Timer.start() catch unreachable;
    var cleared_total: u32 = 0;
    var i: usize = 0;
    while (i < LINECLEAR_ITERS) : (i += 1) {
        var board = Board.init();
        // Fill rows 18-19 completely
        board.grid[18] = Board.ROW_MASK;
        board.grid[19] = Board.ROW_MASK;
        std.mem.doNotOptimizeAway(&board);
        cleared_total += board.clearFullLines();
    }
    std.mem.doNotOptimizeAway(cleared_total);
    const ns_per_call = @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(LINECLEAR_ITERS));

    std.debug.print("=== LINE CLEAR COST ===\n", .{});
    std.debug.print("  ns/call:        {d:.2}ns\n\n", .{ns_per_call});
}

// ── 4. Board evaluation cost ──────────────────────────────────────────────────
fn measureEvalCost() void {
    var rng = std.Random.Xoshiro256.init(1);
    var board = Board.init();
    for (8..Board.HEIGHT) |row| board.grid[row] = rng.random().int(u16) & Board.ROW_MASK;

    var cache = game_mod.EvalCache.init();
    var timer = std.time.Timer.start() catch unreachable;
    var i: usize = 0;
    while (i < EVAL_ITERS) : (i += 1) {
        std.mem.doNotOptimizeAway(&board);
        cache.recompute(&board);
        std.mem.doNotOptimizeAway(&cache);
    }
    const ns_per_call = @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(EVAL_ITERS));

    std.debug.print("=== BOARD FEATURE RECOMPUTE ===\n", .{});
    std.debug.print("  ns/call:        {d:.2}ns\n\n", .{ns_per_call});
}

pub fn main() !void {
    std.debug.print("\nambigui2 — Performance Metrics\n", .{});
    std.debug.print("================================\n\n", .{});

    measureCollisionCost();
    measureLineClearCost();
    measureEvalCost();
    const weights = heuristics.trainedWeights();
    measureNodeThroughput(&weights);
}
