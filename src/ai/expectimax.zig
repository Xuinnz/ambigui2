const game_mod = @import("../engine/game.zig");
const heuristics = @import("heuristics.zig");

pub const GameState = game_mod.GameState;
pub const Move = game_mod.Move;
pub const MoveList = game_mod.MoveList;
pub const Weights = game_mod.Weights;

pub const SearchOptions = struct {
    depth: u32,
    beam_width: usize,
};

const GAME_OVER_SCORE: f32 = -1.0e9;

const MoveArrayType = @typeInfo(MoveList).@"struct".fields[0].type;
const MAX_MOVES: usize = @typeInfo(MoveArrayType).array.len;

const MoveScore = struct {
    move: Move,
    score: f32,
};

pub fn bestMove(state: *const GameState, weights: *const Weights, depth: u32) ?Move {
    return bestMoveWithOptions(state, weights, .{ .depth = depth, .beam_width = 0 });
}

pub fn bestMoveWithOptions(state: *const GameState, weights: *const Weights, options: SearchOptions) ?Move {
    if (state.game_over) return null;
    if (options.depth == 0) return null;

    const moves = state.getMoves();
    if (moves.len == 0) return null;

    var best_move: ?Move = null;
    var best_score: f32 = GAME_OVER_SCORE;

    if (options.beam_width > 0 and moves.len > options.beam_width) {
        var beam: [MAX_MOVES]MoveScore = undefined;
        var beam_len: usize = 0;

        var i: usize = 0;
        while (i < moves.len) : (i += 1) {
            const candidate = moves.items[i];
            const estimate = estimateMoveValue(state, &candidate, weights);
            pushBeam(&beam, &beam_len, options.beam_width, .{ .move = candidate, .score = estimate });
        }

        i = 0;
        while (i < beam_len) : (i += 1) {
            const entry = beam[i];
            const value = chanceNode(state, &entry.move, weights, options.depth - 1, options.beam_width);
            if (value > best_score or best_move == null) {
                best_score = value;
                best_move = entry.move;
            }
        }

        return best_move;
    }

    var i: usize = 0;
    while (i < moves.len) : (i += 1) {
        const candidate = moves.items[i];
        const value = chanceNode(state, &candidate, weights, options.depth - 1, options.beam_width);
        if (value > best_score or best_move == null) {
            best_score = value;
            best_move = candidate;
        }
    }

    return best_move;
}

fn maxNode(state: *const GameState, weights: *const Weights, depth: u32, beam_width: usize) f32 {
    if (state.game_over) return GAME_OVER_SCORE;
    if (depth == 0) return heuristics.score(state, weights);

    const moves = state.getMoves();
    if (moves.len == 0) return GAME_OVER_SCORE;

    var best_score: f32 = GAME_OVER_SCORE;

    if (beam_width > 0 and moves.len > beam_width) {
        var beam: [MAX_MOVES]MoveScore = undefined;
        var beam_len: usize = 0;

        var i: usize = 0;
        while (i < moves.len) : (i += 1) {
            const candidate = moves.items[i];
            const estimate = estimateMoveValue(state, &candidate, weights);
            pushBeam(&beam, &beam_len, beam_width, .{ .move = candidate, .score = estimate });
        }

        i = 0;
        while (i < beam_len) : (i += 1) {
            const entry = beam[i];
            const value = chanceNode(state, &entry.move, weights, depth - 1, beam_width);
            if (value > best_score) {
                best_score = value;
            }
        }

        return best_score;
    }

    var i: usize = 0;
    while (i < moves.len) : (i += 1) {
        const candidate = moves.items[i];
        const value = chanceNode(state, &candidate, weights, depth - 1, beam_width);
        if (value > best_score) {
            best_score = value;
        }
    }

    return best_score;
}

fn chanceNode(state: *const GameState, move: *const Move, weights: *const Weights, depth: u32, beam_width: usize) f32 {
    if (state.game_over) return GAME_OVER_SCORE;

    const prob_a = state.current_piece.prob_a;
    const prob_b = 1.0 - prob_a;

    var branch_a = state.clone();
    branch_a.applyMoveDeterministic(move, true, true);
    const score_a = if (branch_a.game_over)
        GAME_OVER_SCORE
    else if (depth == 0)
        heuristics.score(&branch_a, weights)
    else
        maxNode(&branch_a, weights, depth - 1, beam_width);

    var branch_b = state.clone();
    branch_b.applyMoveDeterministic(move, false, true);
    const score_b = if (branch_b.game_over)
        GAME_OVER_SCORE
    else if (depth == 0)
        heuristics.score(&branch_b, weights)
    else
        maxNode(&branch_b, weights, depth - 1, beam_width);

    return (prob_a * score_a) + (prob_b * score_b);
}

fn estimateMoveValue(state: *const GameState, move: *const Move, weights: *const Weights) f32 {
    const prob_a = state.current_piece.prob_a;
    const prob_b = 1.0 - prob_a;

    var branch_a = state.clone();
    branch_a.applyMoveDeterministic(move, true, true);
    const score_a = if (branch_a.game_over) GAME_OVER_SCORE else heuristics.score(&branch_a, weights);

    var branch_b = state.clone();
    branch_b.applyMoveDeterministic(move, false, true);
    const score_b = if (branch_b.game_over) GAME_OVER_SCORE else heuristics.score(&branch_b, weights);

    return (prob_a * score_a) + (prob_b * score_b);
}

fn pushBeam(beam: *[MAX_MOVES]MoveScore, beam_len: *usize, beam_width: usize, candidate: MoveScore) void {
    if (beam_width == 0) {
        beam[beam_len.*] = candidate;
        beam_len.* += 1;
        return;
    }

    if (beam_len.* < beam_width) {
        beam[beam_len.*] = candidate;
        beam_len.* += 1;
        return;
    }

    var worst_idx: usize = 0;
    var worst_score = beam[0].score;
    var i: usize = 1;
    while (i < beam_len.*) : (i += 1) {
        if (beam[i].score < worst_score) {
            worst_score = beam[i].score;
            worst_idx = i;
        }
    }

    if (candidate.score > worst_score) {
        beam[worst_idx] = candidate;
    }
}
