//Public face of the AI: everything a frontend needs to ask for a move.
const game_mod = @import("../engine/game.zig");
const expectimax = @import("expectimax.zig");
const heuristics = @import("heuristics.zig");

pub const GameState = game_mod.GameState;
pub const Move = game_mod.Move;
pub const Weights = game_mod.Weights;

pub const SearchOptions = expectimax.SearchOptions;
pub const Search = expectimax.Search;
pub const bestMoveWithOptions = expectimax.bestMoveWithOptions;
pub const trainedWeights = heuristics.trainedWeights;
pub const DEFAULT_WEIGHTS = heuristics.DEFAULT_WEIGHTS;

pub const Difficulty = enum { Easy, Medium, Hard };

/// How strong the opponent plays and how fast it moves.
pub const Profile = struct {
    weights: Weights,
    search: SearchOptions,
    /// Minimum time between AI placements.
    step_ms: i64,
};

const ZERO_WEIGHTS = Weights.fromArray(@splat(0));

pub fn profileFor(difficulty: Difficulty) Profile {
    return switch (difficulty) {
        // No board evaluation: only the line-clear bonus separates placements.
        .Easy => .{ .weights = ZERO_WEIGHTS, .search = .{ .depth = 1, .beam_width = 1, .use_hold = false }, .step_ms = 1000 },
        .Medium => .{ .weights = trainedWeights(), .search = .{ .depth = 1, .beam_width = 1, .use_hold = false }, .step_ms = 500 },
        .Hard => .{ .weights = trainedWeights(), .search = .{ .depth = 3, .beam_width = 8 }, .step_ms = 0 },
    };
}
