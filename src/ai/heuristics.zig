const game_mod = @import("../engine/game.zig");
const GameState = game_mod.GameState;
const Weights = game_mod.Weights;

pub const DEFAULT_WEIGHTS = Weights{
    .w_aggregate = -0.5,
    .w_holes = -3.0,
    .w_bumpiness = -0.2,
};

pub fn score(state: *const GameState, weights: *const Weights) f32 {
    return state.evaluate(weights);
}

pub fn scoreDefault(state: *const GameState) f32 {
    return state.evaluate(&DEFAULT_WEIGHTS);
}
