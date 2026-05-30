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
const LINE_CLEAR_REWARD: f32 = 1.0;
const SHAPE_NONE: u64 = 7;
//false when training, true for live env
const tt_toggle: bool = false;

const NodeKind = enum(u8) { max, chance };

const TT_SIZE: usize = 1 << 20;
const TT_MASK: usize = TT_SIZE - 1;
const TT_PROBE_LIMIT: usize = 8;

const TTEntry = struct {
    key: u64,
    value: f32,
    gen: u32,
};

var tt: [TT_SIZE]TTEntry = [_]TTEntry{.{ .key = 0, .value = 0, .gen = 0 }} ** TT_SIZE;
var tt_generation: u32 = 1;

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

pub fn resetTranspositionTable() void {
    if (!tt_toggle) return;

    tt_generation +%= 1;
    if (tt_generation == 0) {
        var i: usize = 0;
        while (i < tt.len) : (i += 1) {
            tt[i].gen = 0;
        }
        tt_generation = 1;
    }
}

fn maxNode(state: *const GameState, weights: *const Weights, depth: u32, beam_width: usize) f32 {
    if (state.game_over) return GAME_OVER_SCORE;
    if (depth == 0) return scoreLeaf(state, weights);

    const key = stateKey(state, depth, .max);
    if (ttProbe(key)) |cached| return cached;

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

        ttStore(key, best_score);
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

    ttStore(key, best_score);
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
        scoreLeaf(&branch_a, weights)
    else
        maxNode(&branch_a, weights, depth - 1, beam_width);

    var branch_b = state.clone();
    branch_b.applyMoveDeterministic(move, false, true);
    const score_b = if (branch_b.game_over)
        GAME_OVER_SCORE
    else if (depth == 0)
        scoreLeaf(&branch_b, weights)
    else
        maxNode(&branch_b, weights, depth - 1, beam_width);

    return (prob_a * score_a) + (prob_b * score_b);
}

fn stateKey(state: *const GameState, depth: u32, kind: NodeKind) u64 {
    var key = mix64(state.zobrist_hash);
    key = mixCombine(key, shapeTag(state.current_piece.state_a.shape_type));
    key = mixCombine(key, shapeTag(state.current_piece.state_b.shape_type));
    key = mixCombine(key, shapeTag(state.next_piece.state_a.shape_type));
    key = mixCombine(key, shapeTag(state.next_piece.state_b.shape_type));

    if (state.held_piece) |held| {
        key = mixCombine(key, shapeTag(held.state_a.shape_type));
        key = mixCombine(key, shapeTag(held.state_b.shape_type));
    } else {
        key = mixCombine(key, SHAPE_NONE);
        key = mixCombine(key, SHAPE_NONE);
    }

    key = mixCombine(key, @as(u64, @intFromBool(state.hold_used)));
    key = mixCombine(key, @as(u64, @intCast(state.bag_index)));
    key = mixCombine(key, @as(u64, depth));
    key = mixCombine(key, @as(u64, @intFromEnum(kind)));
    return key;
}

fn shapeTag(shape: anytype) u64 {
    return @as(u64, @intFromEnum(shape));
}

fn mixCombine(key: u64, value: u64) u64 {
    return mix64(key ^ value);
}

fn mix64(seed: u64) u64 {
    var z = seed +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn ttProbe(key: u64) ?f32 {
    if (!tt_toggle) return null;

    const start: usize = @as(usize, @intCast(key)) & TT_MASK;
    var i: usize = 0;
    while (i < TT_PROBE_LIMIT) : (i += 1) {
        const idx = (start + i) & TT_MASK;
        const entry = tt[idx];
        if (entry.gen != tt_generation) return null;
        if (entry.key == key) return entry.value;
    }
    return null;
}

fn ttStore(key: u64, value: f32) void {
    if (!tt_toggle) return;

    const start: usize = @as(usize, @intCast(key)) & TT_MASK;
    var i: usize = 0;
    while (i < TT_PROBE_LIMIT) : (i += 1) {
        const idx = (start + i) & TT_MASK;
        if (tt[idx].gen != tt_generation or tt[idx].key == key) {
            tt[idx].key = key;
            tt[idx].value = value;
            tt[idx].gen = tt_generation;
            return;
        }
    }

    tt[start].key = key;
    tt[start].value = value;
    tt[start].gen = tt_generation;
}

fn estimateMoveValue(state: *const GameState, move: *const Move, weights: *const Weights) f32 {
    const prob_a = state.current_piece.prob_a;
    const prob_b = 1.0 - prob_a;

    var branch_a = state.clone();
    branch_a.applyMoveDeterministic(move, true, true);
    const score_a = if (branch_a.game_over) GAME_OVER_SCORE else scoreLeaf(&branch_a, weights);

    var branch_b = state.clone();
    branch_b.applyMoveDeterministic(move, false, true);
    const score_b = if (branch_b.game_over) GAME_OVER_SCORE else scoreLeaf(&branch_b, weights);

    return (prob_a * score_a) + (prob_b * score_b);
}

fn scoreLeaf(state: *const GameState, weights: *const Weights) f32 {
    const base = heuristics.score(state, weights);
    const reward = LINE_CLEAR_REWARD * @as(f32, @floatFromInt(state.lines_cleared));
    return base + reward;
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
