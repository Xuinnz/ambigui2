const std = @import("std");
const game_mod = @import("engine/game.zig");
const physics = @import("engine/physics.zig");
const board_mod = @import("engine/board.zig");
const piece_mod = @import("engine/piece.zig");
const expectimax = @import("ai/expectimax.zig");
const heuristics = @import("ai/heuristics.zig");

const GameState = game_mod.GameState;
const Weights = game_mod.Weights;
const Board = board_mod.Board;

const DEPTH: u32 = 5;
const BEAM: usize = 8;
const MOVES_TO_SAMPLE: usize = 200;
const COLLISION_ITERS: usize = 1_000_000;
const LINECLEAR_ITERS: usize = 100_000;

// ── 1. Nodes/sec throughput ───────────────────────────────────────────────────
fn measureNodeThroughput(weights: *const Weights) void {
    var state = GameState.init(42);
    expectimax.node_count = 0;

    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < MOVES_TO_SAMPLE and !state.game_over) : (i += 1) {
        const move = expectimax.bestMoveWithOptions(&state, weights, .{
            .depth = DEPTH,
            .beam_width = BEAM,
        });
        if (move) |m| state.applyMove(&m) else break;
    }

    const elapsed_ns = std.time.nanoTimestamp() - start;
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const nodes_per_sec = @as(f64, @floatFromInt(expectimax.node_count)) / elapsed_sec;
    const ms_per_move = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0 / @as(f64, @floatFromInt(i));

    std.debug.print("=== NODE THROUGHPUT (depth={d} beam={d}) ===\n", .{ DEPTH, BEAM });
    std.debug.print("  Moves sampled:  {d}\n", .{i});
    std.debug.print("  Total nodes:    {d}\n", .{expectimax.node_count});
    std.debug.print("  Elapsed:        {d:.2}s\n", .{elapsed_sec});
    std.debug.print("  Nodes/sec:      {d:.0}k\n", .{nodes_per_sec / 1000.0});
    std.debug.print("  Ms/move:        {d:.1}ms\n\n", .{ms_per_move});
}

// ── 2. Collision check cost ───────────────────────────────────────────────────
fn measureCollisionCost() void {
    var state = GameState.init(42);
    // Fill some rows to make collision non-trivial
    var r: usize = 15;
    while (r < Board.HEIGHT) : (r += 1) {
        state.board.grid[r] = Board.ROW_MASK & 0x00FF; // half-filled rows
    }

    const start = std.time.nanoTimestamp();
    var hits: usize = 0;
    var i: usize = 0;
    while (i < COLLISION_ITERS) : (i += 1) {
        var probe = state.current_piece.state_a;
        probe.y = @as(i8, @intCast(i % 20));
        if (physics.checkCollision(&state.board, &probe)) hits += 1;
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;
    const ns_per_call = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(COLLISION_ITERS));

    std.debug.print("=== COLLISION CHECK COST ===\n", .{});
    std.debug.print("  Iterations:     {d}M\n", .{COLLISION_ITERS / 1_000_000});
    std.debug.print("  ns/call:        {d:.2}ns\n", .{ns_per_call});
    std.debug.print("  us/frame @60Hz: {d:.3}us  (budget=16666us)\n\n", .{ns_per_call * 60.0 / 1000.0});
    // _ = hits; // prevent optimization
}

// ── 3. Line clear cost ────────────────────────────────────────────────────────
fn measureLineClearCost() void {
    const start = std.time.nanoTimestamp();
    var cleared_total: u32 = 0;
    var i: usize = 0;
    while (i < LINECLEAR_ITERS) : (i += 1) {
        var board = board_mod.Board.init();
        // Fill rows 18-19 completely
        board.grid[18] = Board.ROW_MASK;
        board.grid[19] = Board.ROW_MASK;
        cleared_total += board.clearFullLines();
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;
    const ns_per_call = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(LINECLEAR_ITERS));

    std.debug.print("=== LINE CLEAR COST ===\n", .{});
    std.debug.print("  Iterations:     {d}k\n", .{LINECLEAR_ITERS / 1000});
    std.debug.print("  ns/call:        {d:.2}ns\n", .{ns_per_call});
    std.debug.print("  us/frame @60Hz: {d:.4}us  (budget=16666us)\n\n", .{ns_per_call / 1000.0});
    // _ = cleared_total;
}

// ── 4. Random search baseline vs GA ──────────────────────────────────────────
// Simulates what a naive random search finds with the same number of
// candidate evaluations as GA (pop * gens = 100 * 100 = 10,000 candidates,
// each evaluated over 5 games). We run 200 random candidates to estimate
// the trend, then extrapolate.
fn measureRandomBaseline(seeds: []const u64) void {
    var rng = std.Random.Xoshiro256.init(0xDEAD_BEEF);
    var random = rng.random();

    var best_random: f32 = 0;
    var iters: usize = 0;
    const sample_size: usize = 200;

    const start = std.time.nanoTimestamp();

    while (iters < sample_size) : (iters += 1) {
        const w = Weights{
            .w_aggregate = -10.0 * random.float(f32),
            .w_holes = -15.0 * random.float(f32),
            .w_bumpiness = -10.0 * random.float(f32),
            .w_wells = -10.0 * random.float(f32),
            .w_row_transitions = -10.0 * random.float(f32),
            .w_col_transitions = -15.0 * random.float(f32),
        };
        var total: u32 = 0;
        for (seeds) |seed| {
            var state = GameState.init(seed);
            var moves: usize = 0;
            while (!state.game_over and moves < 2000) : (moves += 1) {
                const move = expectimax.bestMoveWithOptions(&state, &w, .{
                    .depth = 3,
                    .beam_width = 10,
                });
                if (move) |m| state.applyMove(&m) else break;
            }
            total += state.lines_cleared;
        }
        const fitness = @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(seeds.len));
        if (fitness > best_random) best_random = fitness;
    }

    const elapsed_ns = std.time.nanoTimestamp() - start;
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    const ga_best: f32 = 59.10; // from your training log
    const improvement_pct = (ga_best - best_random) / best_random * 100.0;

    std.debug.print("=== RANDOM SEARCH BASELINE (n={d} candidates) ===\n", .{sample_size});
    std.debug.print("  Random best fitness:  {d:.2}\n", .{best_random});
    std.debug.print("  GA best fitness:      {d:.2}\n", .{ga_best});
    std.debug.print("  GA improvement:       {d:.1}%\n", .{improvement_pct});
    std.debug.print("  Random elapsed:       {d:.1}s for {d} candidates\n", .{ elapsed_sec, sample_size });
    std.debug.print("  (Extrapolated for 10k candidates: {d:.0}min)\n\n", .{elapsed_sec * 10000.0 / sample_size / 60.0});
}

pub fn main() !void {
    try heuristics.loadTrainedWeights();

    const seeds = [_]u64{ 42, 1337, 999, 12345, 67890 };

    std.debug.print("\nambigui2 — Performance Metrics\n", .{});
    std.debug.print("================================\n\n", .{});

    measureCollisionCost();
    measureLineClearCost();
    measureNodeThroughput(&heuristics.TRAINED_WEIGHTS);
    measureRandomBaseline(&seeds);

    std.debug.print("================================\n", .{});
    std.debug.print("Fill in your project description:\n", .{});
    std.debug.print("  depth={d}, beam={d}\n", .{ DEPTH, BEAM });
    std.debug.print("  generations=100, population=100\n", .{});
}
