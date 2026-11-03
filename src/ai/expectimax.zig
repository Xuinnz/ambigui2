//Implementation of Expectimax Search Algorithm with Beam Search Pruning.
//
//The tree alternates between max nodes (the AI picks a placement, optionally
//after using hold) and chance nodes (the dual-state piece collapses into
//state A with prob_a, or state B otherwise).
//
//`SearchOptions.depth` is the number of pieces placed along a line of play.
//The search never places a piece the player could not see at the root
//(anything after the next-piece preview), so the AI does not peek at the
//hidden RNG stream. With hold that allows up to 3 placements: current, next and held.
const std = @import("std");
const game_mod = @import("../engine/game.zig");
const QuantumPiece = @import("../engine/piece.zig").QuantumPiece;
const heuristics = @import("heuristics.zig");

pub const GameState = game_mod.GameState;
pub const Move = game_mod.Move;
pub const MoveList = game_mod.MoveList;
pub const Weights = game_mod.Weights;

//search configurations. depth for look ahead and beam_width for pruning
pub const SearchOptions = struct {
    /// Pieces to place (plies). Capped at MAX_DEPTH.
    depth: u32,
    /// Candidates kept per max node after a 1-ply estimate; 0 disables pruning.
    /// Capped at MAX_BEAM.
    beam_width: usize,
    /// Also consider swapping with the hold slot before placing.
    use_hold: bool = true,
};

pub const MAX_DEPTH: u32 = 3;
pub const MAX_BEAM: usize = 32;

/// Nodes visited by the calling thread; reset it yourself before measuring.
pub threadlocal var node_count: u64 = 0;

//game over has biggest penalty, line clear will give reward
const GAME_OVER_SCORE: f32 = -1.0e9;
const LINE_CLEAR_REWARD: f32 = 1.0;

const MAX_MOVES: usize = @typeInfo(@FieldType(MoveList, "items")).array.len;
const MAX_CANDIDATES: usize = 2 * MAX_MOVES;

//one placement option: a move of either the current piece (base 0)
//or of the piece that comes out of hold (base 1)
const Candidate = struct {
    move: Move,
    base: u1,
};

//every option available at a max node
const Expansion = struct {
    bases: [2]GameState,
    candidates: [MAX_CANDIDATES]Candidate,
    len: usize,
    //false when every piece we could place is beyond the knowledge horizon
    any_known: bool,
};

//the two collapsed futures of one candidate
const Branches = struct {
    a: GameState,
    b: GameState,
    prob_a: f32,
    prev_lines: u32,
};

//used by beam pruning. keeps the simulated branches so the
//winners are not simulated a second time.
const BeamEntry = struct {
    candidate: usize,
    score: f32,
    branches: Branches,
};

const Ply = struct {
    expansion: Expansion,
    beam: [MAX_BEAM]BeamEntry,
};

const Context = struct {
    weights: *const Weights,
    beam_width: usize,
    use_hold: bool,
    /// Pieces with a serial above this were not visible at the root.
    horizon: u32,
    tt_generation: u32,
};

//scratch space for the max nodes below the root, one per ply. kept out of
//the call stack so deep searches fit in small (WASM) stacks.
threadlocal var plies: [MAX_DEPTH]Ply = undefined;

// ── Transposition table ───────────────────────────────────────────────────────
// Different placements often lead to the same position (for example two moves
// that only differ in where state B lands share the same A branch). Max node
// values are cached per search, keyed by a hash of everything that decides them.
const TT_BITS = 14;
const TT_SIZE = 1 << TT_BITS;

const TtEntry = struct {
    key: u64 = 0,
    value: f32 = 0,
    generation: u32 = 0,
};

threadlocal var tt: [TT_SIZE]TtEntry = [_]TtEntry{.{}} ** TT_SIZE;
threadlocal var tt_generation: u32 = 0;

fn hashPiece(hasher: *std.hash.Wyhash, piece: *const QuantumPiece) void {
    hasher.update(std.mem.asBytes(&piece.state_a.shape_type));
    hasher.update(std.mem.asBytes(&piece.state_b.shape_type));
    hasher.update(std.mem.asBytes(&piece.prob_a));
    hasher.update(std.mem.asBytes(&piece.serial));
}

fn positionKey(state: *const GameState, plies_left: u32) u64 {
    var hasher = std.hash.Wyhash.init(plies_left);
    hasher.update(std.mem.asBytes(&state.board.grid));
    hashPiece(&hasher, &state.current_piece);
    hashPiece(&hasher, &state.next_piece);
    if (state.held_piece) |*held| hashPiece(&hasher, held);
    hasher.update(std.mem.asBytes(&state.hold_used));
    hasher.update(std.mem.asBytes(&state.rng.s));
    hasher.update(std.mem.asBytes(&state.bag.shapes));
    hasher.update(std.mem.asBytes(&state.bag.index));
    // Key 0 marks an empty slot.
    return hasher.final() | 1;
}

fn ttSlot(key: u64) usize {
    return @intCast(key & (TT_SIZE - 1));
}

fn ttLookup(ctx: *const Context, key: u64) ?f32 {
    const entry = &tt[ttSlot(key)];
    if (entry.generation == ctx.tt_generation and entry.key == key) return entry.value;
    return null;
}

fn ttStore(ctx: *const Context, key: u64, value: f32) void {
    tt[ttSlot(key)] = .{ .key = key, .value = value, .generation = ctx.tt_generation };
}

// ── Tree ──────────────────────────────────────────────────────────────────────

fn isKnown(ctx: *const Context, state: *const GameState) bool {
    return state.current_piece.serial <= ctx.horizon;
}

//lists every placement of the current piece and, if allowed, of the held piece
fn expand(ctx: *const Context, state: *const GameState, out: *Expansion) void {
    out.len = 0;
    out.any_known = false;

    if (isKnown(ctx, state)) {
        out.any_known = true;
        out.bases[0] = state.*;
        const moves = state.getMoves();
        for (moves.slice()) |move| {
            out.candidates[out.len] = .{ .move = move, .base = 0 };
            out.len += 1;
        }
    }

    if (ctx.use_hold and state.canHold()) {
        var held = state.clone();
        held.tryHold();
        if (!held.game_over and isKnown(ctx, &held)) {
            out.any_known = true;
            out.bases[1] = held;
            const moves = held.getMoves();
            for (moves.slice()) |move| {
                var with_hold = move;
                with_hold.use_hold = true;
                out.candidates[out.len] = .{ .move = with_hold, .base = 1 };
                out.len += 1;
            }
        }
    }
}

//we clone the state into the universe where the piece collapsed into 'state_a'
//and the one where it collapsed into 'state_b'
fn simulate(base: *const GameState, move: *const Move) Branches {
    var branches = Branches{
        .a = base.clone(),
        .b = base.clone(),
        .prob_a = base.current_piece.prob_a,
        .prev_lines = base.lines_cleared,
    };
    branches.a.applyMoveDeterministic(move, true, true);
    branches.b.applyMoveDeterministic(move, false, true);
    return branches;
}

//evaluator of the final score. calculates the penalty + reward
fn scoreLeaf(ctx: *const Context, state: *const GameState, prev_lines: u32) f32 {
    //we evaluate the state based on our weights model.
    const base = heuristics.score(state, ctx.weights);
    //lines cleared by the placement that produced this state
    const delta = state.lines_cleared - prev_lines;
    return base + LINE_CLEAR_REWARD * @as(f32, @floatFromInt(delta));
}

fn branchValue(ctx: *const Context, branch: *const GameState, prev_lines: u32, plies_left: u32) f32 {
    if (branch.game_over) return GAME_OVER_SCORE;
    if (plies_left == 0) return scoreLeaf(ctx, branch, prev_lines);
    return maxNode(ctx, branch, plies_left, prev_lines);
}

//we blend the EV of both realities into a unified EV.
//basically, if we have a prob_a = 0.1, score_a = 10, prob_b = 0.9, score_b = 2
//its EV is 2.8
fn chanceValue(ctx: *const Context, branches: *const Branches, plies_left: u32) f32 {
    node_count += 1;
    const score_a = branchValue(ctx, &branches.a, branches.prev_lines, plies_left);
    const score_b = branchValue(ctx, &branches.b, branches.prev_lines, plies_left);
    return (branches.prob_a * score_a) + ((1.0 - branches.prob_a) * score_b);
}

//beam tracker: keeps the beam_width highest estimates
fn pushBeam(beam: []BeamEntry, beam_len: *usize, beam_width: usize, entry: *const BeamEntry) void {
    //beam not full
    if (beam_len.* < beam_width) {
        beam[beam_len.*] = entry.*;
        beam_len.* += 1;
        return;
    }

    //beam is full: the candidate replaces the worst entry if it beats it
    var worst_idx: usize = 0;
    var worst_score = beam[0].score;
    var i: usize = 1;
    while (i < beam_len.*) : (i += 1) {
        if (beam[i].score < worst_score) {
            worst_score = beam[i].score;
            worst_idx = i;
        }
    }

    if (entry.score > worst_score) {
        beam[worst_idx] = entry.*;
    }
}

fn usesBeam(ctx: *const Context, expansion: *const Expansion) bool {
    return ctx.beam_width > 0 and expansion.len > ctx.beam_width;
}

//estimates every candidate one ply deep and keeps the best beam_width of them
fn fillBeam(ctx: *const Context, expansion: *const Expansion, beam: []BeamEntry) usize {
    var beam_len: usize = 0;
    for (expansion.candidates[0..expansion.len], 0..) |*candidate, i| {
        var entry = BeamEntry{
            .candidate = i,
            .score = 0,
            .branches = simulate(&expansion.bases[candidate.base], &candidate.move),
        };
        entry.score = chanceValue(ctx, &entry.branches, 0);
        pushBeam(beam, &beam_len, ctx.beam_width, &entry);
    }
    return beam_len;
}

//value of a beam entry searched to `plies_left` more placements
fn beamEntryValue(ctx: *const Context, entry: *const BeamEntry, plies_left: u32) f32 {
    //the 1-ply estimate already is the exact value at the last ply
    if (plies_left == 0) return entry.score;
    return chanceValue(ctx, &entry.branches, plies_left);
}

fn candidateValue(ctx: *const Context, expansion: *const Expansion, idx: usize, plies_left: u32) f32 {
    const candidate = &expansion.candidates[idx];
    const branches = simulate(&expansion.bases[candidate.base], &candidate.move);
    return chanceValue(ctx, &branches, plies_left);
}

//this is used to simulate the future timelines: the AI picks the best option
fn maxNode(ctx: *const Context, state: *const GameState, plies_left: u32, prev_lines: u32) f32 {
    std.debug.assert(!state.game_over and plies_left > 0);
    node_count += 1;

    const key = positionKey(state, plies_left);
    if (ttLookup(ctx, key)) |value| return value;

    const ply = &plies[MAX_DEPTH - plies_left];
    expand(ctx, state, &ply.expansion);
    const expansion = &ply.expansion;

    //nothing we are allowed to know about is left to place: score the board as is
    if (!expansion.any_known) return scoreLeaf(ctx, state, prev_lines);
    if (expansion.len == 0) return GAME_OVER_SCORE;

    var best_score: f32 = GAME_OVER_SCORE;
    if (usesBeam(ctx, expansion)) {
        //prune using beam width so we just calculate the top performing
        const beam_len = fillBeam(ctx, expansion, &ply.beam);
        for (ply.beam[0..beam_len]) |*entry| {
            best_score = @max(best_score, beamEntryValue(ctx, entry, plies_left - 1));
        }
    } else {
        for (0..expansion.len) |i| {
            best_score = @max(best_score, candidateValue(ctx, expansion, i, plies_left - 1));
        }
    }

    ttStore(ctx, key, best_score);
    return best_score;
}

// ── Root search ───────────────────────────────────────────────────────────────

/// A root search that can be run to completion at once (`run`) or a few root
/// candidates at a time (`step`), so a single-threaded frontend can spread one
/// search over several frames.
///
/// Large (tens of KB): keep it in static or heap memory on small-stack targets.
pub const Search = struct {
    ctx: Context,
    plies: u32,
    expansion: Expansion,
    beam: [MAX_BEAM]BeamEntry,
    beam_len: usize,
    use_beam: bool,
    /// Next candidate (or beam entry) to evaluate.
    cursor: usize,
    best_score: f32,
    best_candidate: ?usize,
    done: bool,

    pub fn init(self: *Search, state: *const GameState, weights: *const Weights, options: SearchOptions) void {
        tt_generation +%= 1;
        if (tt_generation == 0) tt_generation = 1;

        self.ctx = .{
            .weights = weights,
            .beam_width = @min(options.beam_width, MAX_BEAM),
            .use_hold = options.use_hold,
            //the player sees the current piece, the next piece and the hold slot
            .horizon = state.next_piece.serial,
            .tt_generation = tt_generation,
        };
        self.plies = @min(options.depth, MAX_DEPTH);
        self.cursor = 0;
        self.beam_len = 0;
        self.best_score = GAME_OVER_SCORE;
        self.best_candidate = null;
        self.done = state.game_over or self.plies == 0;
        if (self.done) {
            self.expansion.len = 0;
            return;
        }

        //get all possible moves
        expand(&self.ctx, state, &self.expansion);
        self.use_beam = usesBeam(&self.ctx, &self.expansion);
        //Pruning the results. if we only have beam width of 5
        //we get the top 5 highest ev of all the possible moves
        if (self.use_beam) self.beam_len = fillBeam(&self.ctx, &self.expansion, &self.beam);
        self.done = self.remaining() == 0;
    }

    fn remaining(self: *const Search) usize {
        const total = if (self.use_beam) self.beam_len else self.expansion.len;
        return total - self.cursor;
    }

    /// Evaluates up to `max_candidates` root options. Returns true when finished.
    pub fn step(self: *Search, max_candidates: usize) bool {
        var budget = max_candidates;
        while (!self.done and budget > 0) : (budget -= 1) {
            const idx, const value = if (self.use_beam) blk: {
                const entry = &self.beam[self.cursor];
                break :blk .{ entry.candidate, beamEntryValue(&self.ctx, entry, self.plies - 1) };
            } else .{ self.cursor, candidateValue(&self.ctx, &self.expansion, self.cursor, self.plies - 1) };

            //first best wins ties, so results do not depend on step sizes
            if (value > self.best_score or self.best_candidate == null) {
                self.best_score = value;
                self.best_candidate = idx;
            }
            self.cursor += 1;
            self.done = self.remaining() == 0;
        }
        return self.done;
    }

    pub fn run(self: *Search) void {
        while (!self.step(std.math.maxInt(usize))) {}
    }

    /// The best move found, or null if there is none (game over / no legal move).
    pub fn result(self: *const Search) ?Move {
        const idx = self.best_candidate orelse return null;
        return self.expansion.candidates[idx].move;
    }
};

//this will give the best move (the highest value move) according the weights
pub fn bestMoveWithOptions(state: *const GameState, weights: *const Weights, options: SearchOptions) ?Move {
    var search: Search = undefined;
    search.init(state, weights, options);
    search.run();
    return search.result();
}

test "search finds a move and respects the hold flag" {
    var state = GameState.init(42);
    const move = bestMoveWithOptions(&state, &heuristics.DEFAULT_WEIGHTS, .{ .depth = 2, .beam_width = 6, .use_hold = false }).?;
    try std.testing.expect(!move.use_hold);
    state.applyMove(&move);
    try std.testing.expect(!state.game_over);
}

test "stepping a search gives the same move as running it" {
    var state = GameState.init(7);
    for (0..10) |_| {
        const options = SearchOptions{ .depth = 2, .beam_width = 5 };
        const full = bestMoveWithOptions(&state, &heuristics.DEFAULT_WEIGHTS, options).?;

        var search: Search = undefined;
        search.init(&state, &heuristics.DEFAULT_WEIGHTS, options);
        while (!search.step(1)) {}
        const stepped = search.result().?;

        try std.testing.expectEqualDeep(full, stepped);
        state.applyMove(&full);
        if (state.game_over) break;
    }
}

test "search never places a piece beyond the preview" {
    // With hold disabled only current + next are visible, so depth 3 must equal depth 2.
    var state = GameState.init(1337);
    for (0..10) |_| {
        const d2 = bestMoveWithOptions(&state, &heuristics.DEFAULT_WEIGHTS, .{ .depth = 2, .beam_width = 4, .use_hold = false }).?;
        const d3 = bestMoveWithOptions(&state, &heuristics.DEFAULT_WEIGHTS, .{ .depth = 3, .beam_width = 4, .use_hold = false }).?;
        try std.testing.expectEqualDeep(d2, d3);
        state.applyMove(&d2);
        if (state.game_over) break;
    }
}

test "AI survives a short game with hold" {
    var state = GameState.init(2024);
    var moves: usize = 0;
    while (moves < 60 and !state.game_over) : (moves += 1) {
        const move = bestMoveWithOptions(&state, &heuristics.DEFAULT_WEIGHTS, .{ .depth = 2, .beam_width = 4 }) orelse break;
        state.applyMove(&move);
    }
    try std.testing.expect(moves == 60);
}
