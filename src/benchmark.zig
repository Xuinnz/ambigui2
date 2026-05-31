const std = @import("std");
const game_mod = @import("../src/engine/game.zig");
const expectimax = @import("../src/ai/expectimax.zig");
const heuristics = @import("../src/ai/heuristics.zig");
const config = @import("config");

const GameState = game_mod.GameState;
const Weights = game_mod.Weights;

const SEED: u64 = config.seed;
const AI_DEPTH: u32 = config.ai_depth;
const AI_BEAM_WIDTH: usize = config.ai_beam_width;
pub fn main() !void {
    const test_seeds = [_]u64{ 42, 1337, 999, 12345, 67890, 111, 222, 333, 444, 555 };
    var total: u64 = 0;

    try heuristics.loadTrainedWeights();
    for (test_seeds) |seed| {
        var state = GameState.init(seed);
        var moves: usize = 0;
        while (!state.game_over and moves < 5000) : (moves += 1) {
            const move = expectimax.bestMoveWithOptions(&state, &heuristics.TRAINED_WEIGHTS, .{
                AI_DEPTH,
                AI_BEAM_WIDTH,
            });
            if (move) |m| state.applyMove(&m) else break;
        }
        std.debug.print("seed {d}: score={d} lines={d}\n", .{
            seed, state.score, state.lines_cleared,
        });
        total += state.score;
    }
    std.debug.print("average score: {d}\n", .{total / test_seeds.len});
}
