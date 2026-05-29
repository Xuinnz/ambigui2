const game_mod = @import("../engine/game.zig");
const expectimax = @import("expectimax.zig");

pub const GameState = game_mod.GameState;
pub const Move = game_mod.Move;
pub const MoveList = game_mod.MoveList;
pub const Weights = game_mod.Weights;

pub const SearchOptions = expectimax.SearchOptions;
pub const bestMove = expectimax.bestMove;
pub const bestMoveWithOptions = expectimax.bestMoveWithOptions;

pub fn getMoves(state: *const GameState) MoveList {
    return state.getMoves();
}
