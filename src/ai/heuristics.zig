const std = @import("std");
const game_mod = @import("../engine/game.zig");
const GameState = game_mod.GameState;
const Weights = game_mod.Weights;

pub const DEFAULT_WEIGHTS = Weights{
    .w_aggregate = -0.5,
    .w_holes = -7.9,
    .w_bumpiness = -1.8,
    .w_wells = -3.4,
    .w_row_transitions = -3.4,
    .w_col_transitions = -5.2,
};

//weights will automatically be parsed from data/weights.json
//if weights.json doesnt exist, app will fail
pub var TRAINED_WEIGHTS: Weights = Weights{
    .w_aggregate = 0,
    .w_holes = 0,
    .w_bumpiness = 0,
    .w_wells = 0,
    .w_row_transitions = 0,
    .w_col_transitions = 0,
};

pub fn loadTrainedWeights() !void {
    const allocator = std.heap.page_allocator;
    const data = try std.fs.cwd().readFileAlloc(allocator, "data/weights.json", 65536);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(Weights, allocator, data, .{});
    defer parsed.deinit();

    TRAINED_WEIGHTS = parsed.value;
}

pub fn score(state: *const GameState, weights: *const Weights) f32 {
    return state.evaluate(weights);
}

pub fn scoreDefault(state: *const GameState) f32 {
    return state.evaluate(&DEFAULT_WEIGHTS);
}
