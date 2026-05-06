const game_mod = @import("../engine/game.zig");

pub const GameState = game_mod.GameState;
pub const Move = game_mod.Move;
pub const MoveList = game_mod.MoveList;

pub fn getMoves(state: *const GameState) MoveList {
    return state.getMoves();
}
