const std = @import("std");
const Board = @import("board.zig").Board;
const physics = @import("physics.zig");
const piece_mod = @import("piece.zig");
const kicks = @import("kicks.zig");
const bag_mod = @import("bag.zig");
const eval = @import("eval.zig");
const ShapeType = piece_mod.ShapeType;
const Piece = piece_mod.Piece;
const QuantumPiece = piece_mod.QuantumPiece;
const Kick = kicks.Kick;
const Bag = bag_mod.Bag;

pub const Weights = eval.Weights;
pub const EvalCache = eval.EvalCache;
pub const RotationDirection = kicks.Direction;

const LockBranch = enum { a, b };

const MAX_MOVES: usize = 128;
const LOCK_DELAY_TICKS: u8 = 2;
/// Rotations reset the lock delay at most this many times per piece, so a
/// player cannot stall forever by spinning a grounded piece.
pub const MAX_LOCK_RESETS: u8 = 15;

/// A placement for the current piece: where each state comes to rest.
pub const Move = struct {
    state_a: Piece,
    state_b: Piece,
    a_valid: bool,
    b_valid: bool,
    wall_out_a: bool,
    wall_out_b: bool,
    /// Swap with the hold slot before placing. The states above are then
    /// positions of the piece that comes out of hold (or the next piece).
    use_hold: bool = false,
};

pub const MoveList = struct {
    items: [MAX_MOVES]Move,
    len: usize,

    pub fn init() MoveList {
        return .{ .items = undefined, .len = 0 };
    }

    pub fn append(self: *MoveList, move: Move) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = move;
        self.len += 1;
    }

    pub fn slice(self: *const MoveList) []const Move {
        return self.items[0..self.len];
    }
};

fn checkStateCollision(self: *const GameState, piece: *const Piece) bool {
    return if (piece.shape_type == .I)
        physics.checkCollisionIgnoreWalls(&self.board, piece)
    else
        physics.checkCollision(&self.board, piece);
}

fn tryKick(self: *GameState, old_a: Piece, old_b: Piece, kick: Kick) bool {
    self.current_piece.state_a.x = old_a.x + kick.dx;
    self.current_piece.state_a.y = old_a.y + kick.dy;
    self.current_piece.state_b.x = old_b.x + kick.dx;
    self.current_piece.state_b.y = old_b.y + kick.dy;

    return !checkStateCollision(self, &self.current_piece.state_a) and
        !checkStateCollision(self, &self.current_piece.state_b);
}

fn rotatePiece(piece: *Piece, dir: RotationDirection) void {
    switch (dir) {
        .cw => piece.rotateCW(),
        .ccw => piece.rotateCCW(),
    }
}

fn rotateSingle(self: *GameState, piece: *Piece, dir: RotationDirection) bool {
    const old = piece.*;
    rotatePiece(piece, dir);

    const kick_list = kicks.forRotation(old.shape_type, old.rotation_idx, dir);
    for (kick_list.slice()) |kick| {
        piece.x = old.x + kick.dx;
        piece.y = old.y + kick.dy;
        if (!checkStateCollision(self, piece)) return true;
    }

    piece.* = old;
    return false;
}

/// Writes a piece's blocks into the board. Returns true if any block is above
/// the visible board (a lock out).
fn projectPiece(self: *GameState, piece: Piece, wall_out: bool) bool {
    var lock_out = false;

    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const piece_row = physics.pieceRow(&piece, row);
        if (piece_row == 0) continue;

        const board_y: i16 = @as(i16, piece.y) + @as(i16, @intCast(row));
        if (board_y < 0) {
            lock_out = true;
            continue;
        }
        if (board_y >= @as(i16, @intCast(Board.HEIGHT))) continue;

        const projected = physics.projectRow(piece_row, piece.x);
        // Only an I piece may hang over a wall; its overhanging blocks are dropped.
        std.debug.assert(!projected.offBoard() or (piece.shape_type == .I and wall_out));

        self.board.grid[@intCast(board_y)] |= projected.on_board;
    }

    return lock_out;
}

/// Defines the terminal conditions for a game session.
pub const TopOutReason = enum {
    /// A piece spawned overlapping an existing locked block.
    block_out,
    /// A piece locked successfully, but its structure breached the visible skyline (y < 0).
    lock_out,
};

/// Manages the deterministic game loop, state transitions, and PRNG.
pub const GameState = struct {
    board: Board,
    eval_cache: EvalCache,
    current_piece: QuantumPiece,
    next_piece: QuantumPiece,
    held_piece: ?QuantumPiece,
    hold_used: bool,
    lock_delay_counter: u8,
    lock_resets: u8,
    rng: std.Random.Xoshiro256,
    bag: Bag,
    pieces_generated: u32,
    score: u32,
    lines_cleared: u32,
    level: u32,
    game_over: bool,
    top_out_reason: ?TopOutReason,

    /// Initializes the engine. A fixed seed guarantees deterministic chance nodes
    /// for the Expectimax search tree and reproducible debugging.
    pub fn init(seed: u64) GameState {
        var state = GameState{
            .board = Board.init(),
            .eval_cache = EvalCache.init(),
            .current_piece = undefined,
            .next_piece = undefined,
            .held_piece = null,
            .hold_used = false,
            .lock_delay_counter = 0,
            .lock_resets = 0,
            .rng = std.Random.Xoshiro256.init(seed),
            .bag = Bag.init(),
            .pieces_generated = 0,
            .score = 0,
            .lines_cleared = 0,
            .level = 0,
            .game_over = false,
            .top_out_reason = null,
        };

        state.next_piece = state.generateQuantumPiece();
        state.spawnNextPiece();
        state.eval_cache.recompute(&state.board);
        return state;
    }

    /// Returns a cheap value copy for search tree branching.
    pub fn clone(self: *const GameState) GameState {
        return self.*;
    }

    pub fn evaluate(self: *const GameState, weights: *const Weights) f32 {
        return self.eval_cache.evaluate(weights);
    }

    /// Milliseconds between gravity ticks; speeds up 15% per level, floored at 100ms.
    pub fn gravityIntervalMs(self: *const GameState) i64 {
        const factor = std.math.pow(f32, 0.85, @floatFromInt(self.level));
        return @max(100, @as(i64, @intFromFloat(1000.0 * factor)));
    }

    /// Returns the projected landing position for a piece without mutating state.
    pub fn projectGhostPiece(self: *const GameState, piece: *const Piece) Piece {
        var ghost = piece.*;
        while (true) {
            var next = ghost;
            next.y += 1;
            if (checkStateCollision(self, &next)) break;
            ghost = next;
        }
        return ghost;
    }

    /// Enumerates legal placements for the current quantum piece.
    pub fn getMoves(self: *const GameState) MoveList {
        var moves = MoveList.init();

        const base_a = self.current_piece.state_a;
        const base_b = self.current_piece.state_b;
        const min_x: i8 = -@as(i8, @intCast(Piece.BOUND_SIZE));
        const max_x: i8 = @as(i8, @intCast(Board.WIDTH + Piece.BOUND_SIZE));

        const unique_rots_a: usize = switch (base_a.shape_type) {
            .O => 1,
            .S, .Z => 2,
            else => 4,
        };
        const unique_rots_b: usize = switch (base_b.shape_type) {
            .O => 1,
            .S, .Z => 2,
            else => 4,
        };
        const max_rots = @max(unique_rots_a, unique_rots_b);

        var rot_steps: usize = 0;
        while (rot_steps < max_rots) : (rot_steps += 1) {
            var rot_a = base_a;
            var rot_b = base_b;
            var r: usize = 0;
            while (r < rot_steps) : (r += 1) {
                rot_a.rotateCW();
                rot_b.rotateCW();
            }

            var x: i8 = min_x;
            while (x <= max_x) : (x += 1) {
                var probe_a = rot_a;
                var probe_b = rot_b;
                probe_a.x = x;
                probe_b.x = x;
                probe_a.y = Piece.DEFAULT_SPAWN_Y;
                probe_b.y = Piece.DEFAULT_SPAWN_Y;

                // Independent validity — skip only if BOTH states are blocked
                const a_valid = !checkStateCollision(self, &probe_a);
                const b_valid = !checkStateCollision(self, &probe_b);
                if (!a_valid and !b_valid) continue;

                // Drop each state independently to its own resting position
                const drop_a = if (a_valid) self.projectGhostPiece(&probe_a) else probe_a;
                const drop_b = if (b_valid) self.projectGhostPiece(&probe_b) else probe_b;

                const wall_out_a = if (a_valid) physics.checkWallCollision(&drop_a) else false;
                const wall_out_b = if (b_valid) physics.checkWallCollision(&drop_b) else false;

                moves.append(.{
                    .state_a = drop_a,
                    .state_b = drop_b,
                    .a_valid = a_valid,
                    .b_valid = b_valid,
                    .wall_out_a = wall_out_a,
                    .wall_out_b = wall_out_b,
                });
            }
        }

        return moves;
    }

    fn generateQuantumPiece(self: *GameState) QuantumPiece {
        const random = self.rng.random();
        const shape_a = self.bag.draw(random);
        var shape_b = self.bag.draw(random);

        // Invariant: A quantum piece must comprise two distinct deterministic states.
        // With a 7-bag, equality only occurs at bag boundaries, so we swap in
        // the next distinct candidate from the same shuffled bag segment.
        if (shape_a == shape_b) {
            shape_b = self.bag.redrawExcluding(shape_a);
        }

        const prob = 0.1 + (random.float(f32) * 0.8);
        const serial = self.pieces_generated;
        self.pieces_generated += 1;
        return QuantumPiece.init(shape_a, shape_b, prob, serial);
    }

    fn canMovePieceBy(self: *const GameState, piece: *const Piece, dx: i8, dy: i8) bool {
        var probe = piece.*;
        probe.x += dx;
        probe.y += dy;
        return !checkStateCollision(self, &probe);
    }

    fn refreshImpactFlags(self: *GameState) void {
        if (self.current_piece.locked_a) {
            self.current_piece.grounded_a = true;
        } else {
            self.current_piece.grounded_a = !self.canMovePieceBy(&self.current_piece.state_a, 0, 1);
            self.current_piece.wall_out_a = physics.checkWallCollision(&self.current_piece.state_a);
        }

        if (self.current_piece.locked_b) {
            self.current_piece.grounded_b = true;
        } else {
            self.current_piece.grounded_b = !self.canMovePieceBy(&self.current_piece.state_b, 0, 1);
            self.current_piece.wall_out_b = physics.checkWallCollision(&self.current_piece.state_b);
        }
    }

    fn prepareCurrentPiece(self: *GameState) void {
        self.current_piece.grounded_a = false;
        self.current_piece.grounded_b = false;
        self.current_piece.wall_out_a = false;
        self.current_piece.wall_out_b = false;
        self.current_piece.locked_a = false;
        self.current_piece.locked_b = false;
        self.lock_delay_counter = 0;
        self.lock_resets = 0;

        if (physics.checkQuantumCollision(&self.board, &self.current_piece)) {
            self.game_over = true;
            self.top_out_reason = .block_out;
            return;
        }

        self.refreshImpactFlags();
    }

    /// Generates the next quantum superposition and checks for spawn obstruction.
    pub fn spawnNextPiece(self: *GameState) void {
        if (self.game_over) return;

        self.current_piece = self.next_piece;
        self.next_piece = self.generateQuantumPiece();
        self.prepareCurrentPiece();
    }

    /// True if hold may be used right now (once per piece, before any state locks).
    pub fn canHold(self: *const GameState) bool {
        return !self.game_over and !self.hold_used and
            !self.current_piece.locked_a and !self.current_piece.locked_b;
    }

    pub fn tryHold(self: *GameState) void {
        if (!self.canHold()) return;

        var stored = self.current_piece;
        stored.resetToSpawn();

        if (self.held_piece) |held| {
            var swap_in = held;
            swap_in.resetToSpawn();
            self.held_piece = stored;
            self.hold_used = true;
            self.current_piece = swap_in;
            self.prepareCurrentPiece();
            return;
        }

        self.held_piece = stored;
        self.hold_used = true;
        self.spawnNextPiece();
    }

    /// Attempts a horizontal move for both states together.
    /// If either branch collides, the move is reverted.
    pub fn tryMoveHorizontal(self: *GameState, dx: i8) void {
        if (self.game_over) return;

        const move_a = !self.current_piece.locked_a;
        const move_b = !self.current_piece.locked_b;
        if (!move_a and !move_b) return;

        if (move_a) self.current_piece.state_a.x += dx;
        if (move_b) self.current_piece.state_b.x += dx;

        if ((move_a and checkStateCollision(self, &self.current_piece.state_a)) or
            (move_b and checkStateCollision(self, &self.current_piece.state_b)))
        {
            if (move_a) self.current_piece.state_a.x -= dx;
            if (move_b) self.current_piece.state_b.x -= dx;
            return;
        }

        self.refreshImpactFlags();
    }

    pub fn tryRotateCW(self: *GameState) void {
        self.tryRotate(.cw);
    }

    pub fn tryRotateCCW(self: *GameState) void {
        self.tryRotate(.ccw);
    }

    /// Rotates both deterministic states in-place.
    /// If either branch collides after every kick, both are reverted.
    pub fn tryRotate(self: *GameState, dir: RotationDirection) void {
        if (self.game_over) return;
        const active_a = !self.current_piece.locked_a;
        const active_b = !self.current_piece.locked_b;
        if (!active_a and !active_b) return;

        if (active_a and active_b) {
            const old_a = self.current_piece.state_a;
            const old_b = self.current_piece.state_b;

            rotatePiece(&self.current_piece.state_a, dir);
            rotatePiece(&self.current_piece.state_b, dir);

            // When one state is an I piece its kick table is tried first,
            // then any kicks unique to the other state's table.
            const kicks_a = kicks.forRotation(old_a.shape_type, old_a.rotation_idx, dir);
            const kicks_b = kicks.forRotation(old_b.shape_type, old_b.rotation_idx, dir);
            const b_first = old_b.shape_type == .I;
            const primary = if (b_first) &kicks_b else &kicks_a;
            const secondary = if (b_first) &kicks_a else &kicks_b;

            const applied = for (primary.slice()) |kick| {
                if (tryKick(self, old_a, old_b, kick)) break true;
            } else for (secondary.slice()) |kick| {
                if (primary.contains(kick)) continue;
                if (tryKick(self, old_a, old_b, kick)) break true;
            } else false;

            if (!applied) {
                self.current_piece.state_a = old_a;
                self.current_piece.state_b = old_b;
                return;
            }
        } else if (active_a) {
            if (!rotateSingle(self, &self.current_piece.state_a, dir)) return;
        } else {
            if (!rotateSingle(self, &self.current_piece.state_b, dir)) return;
        }

        self.refreshImpactFlags();
        if (self.lock_resets < MAX_LOCK_RESETS) {
            self.lock_delay_counter = 0;
            self.lock_resets += 1;
        }
    }

    /// Advances the lock delay of a fully grounded piece.
    /// Returns true once the delay expires and the piece collapses.
    fn stepLockDelay(self: *GameState) bool {
        if (self.lock_delay_counter >= LOCK_DELAY_TICKS) {
            self.lock_delay_counter = 0;
            self.finalizeCollapse();
            return true;
        }
        self.lock_delay_counter += 1;
        return false;
    }

    /// Applies one gravity tick with independent fall states.
    /// Returns true if this tick caused a collapse/lock transition.
    pub fn tickGravity(self: *GameState) bool {
        if (self.game_over) return false;

        const active_a = !self.current_piece.locked_a;
        const active_b = !self.current_piece.locked_b;

        if (active_a and !self.current_piece.grounded_a) {
            self.current_piece.state_a.y += 1;
            if (checkStateCollision(self, &self.current_piece.state_a)) {
                self.current_piece.state_a.y -= 1;
                self.current_piece.grounded_a = true;
            }
        }

        if (active_b and !self.current_piece.grounded_b) {
            self.current_piece.state_b.y += 1;
            if (checkStateCollision(self, &self.current_piece.state_b)) {
                self.current_piece.state_b.y -= 1;
                self.current_piece.grounded_b = true;
            }
        }

        if (active_a and active_b) {
            const grounded_a = self.current_piece.grounded_a;
            const grounded_b = self.current_piece.grounded_b;
            if (grounded_a and grounded_b) return self.stepLockDelay();

            // One state landed: lock it in place and let the other keep falling.
            if (grounded_a) self.partialLock(.a);
            if (grounded_b) self.partialLock(.b);
            if (!grounded_a and !grounded_b) self.lock_delay_counter = 0;
            return false;
        }

        const grounded = if (active_a) self.current_piece.grounded_a else self.current_piece.grounded_b;
        if (active_a or active_b) {
            if (grounded) return self.stepLockDelay();
            self.lock_delay_counter = 0;
        }
        return false;
    }

    /// Drops the current quantum piece until collapse triggers.
    pub fn hardDrop(self: *GameState) void {
        while (!self.game_over) {
            if (self.tickGravity()) break;
        }
    }

    fn partialLock(self: *GameState, which: LockBranch) void {
        if (self.game_over) return;

        // Do NOT write to the board yet — the other state is still active
        // and may need to pass through this space. finalizeCollapse writes the winner.
        switch (which) {
            .a => {
                self.current_piece.wall_out_a = physics.checkWallCollision(&self.current_piece.state_a);
                self.current_piece.locked_a = true;
                self.current_piece.grounded_a = true;
            },
            .b => {
                self.current_piece.wall_out_b = physics.checkWallCollision(&self.current_piece.state_b);
                self.current_piece.locked_b = true;
                self.current_piece.grounded_b = true;
            },
        }

        self.lock_delay_counter = 0;
        self.refreshImpactFlags();
    }

    pub fn rollCollapsePick(self: *GameState) bool {
        const random = self.rng.random();
        const roll = random.float(f32);
        return roll < self.current_piece.prob_a;
    }

    /// Places the CURRENT piece as described by `move`, collapsing into state A
    /// if `pick_a`. Does not perform the move's hold; callers that search over
    /// hold apply it to the state first (see `applyMove`).
    pub fn applyMoveDeterministic(self: *GameState, move: *const Move, pick_a: bool, advance_rng: bool) void {
        if (self.game_over) return;

        self.current_piece.state_a = move.state_a;
        self.current_piece.state_b = move.state_b;
        self.current_piece.wall_out_a = move.wall_out_a;
        self.current_piece.wall_out_b = move.wall_out_b;
        self.current_piece.grounded_a = true;
        self.current_piece.grounded_b = true;
        self.current_piece.locked_a = false;
        self.current_piece.locked_b = false;
        self.lock_delay_counter = 0;

        if (advance_rng) {
            _ = self.rollCollapsePick();
        }

        const picked_valid = if (pick_a) move.a_valid else move.b_valid;
        if (!picked_valid) {
            self.game_over = true;
            self.top_out_reason = .lock_out;
            return;
        }

        self.finalizeCollapseWithPick(pick_a);
    }

    /// Plays a move chosen by the AI: holds if requested, then places and collapses.
    pub fn applyMove(self: *GameState, move: *const Move) void {
        if (move.use_hold) {
            std.debug.assert(self.canHold());
            self.tryHold();
        }
        const pick_a = self.rollCollapsePick();
        self.applyMoveDeterministic(move, pick_a, false);
    }

    fn finalizeCollapseWithPick(self: *GameState, pick_a: bool) void {
        if (self.game_over) return;
        std.debug.assert(self.current_piece.grounded_a and self.current_piece.grounded_b);

        const final_piece = if (pick_a) self.current_piece.state_a else self.current_piece.state_b;
        const final_wall_out = if (pick_a) self.current_piece.wall_out_a else self.current_piece.wall_out_b;

        // ALWAYS project the winner to the board, ignoring legacy locked flags.
        if (projectPiece(self, final_piece, final_wall_out)) {
            self.game_over = true;
            self.top_out_reason = .lock_out;
            return;
        }

        const cleared = self.board.clearFullLines();
        std.debug.assert(cleared <= 4);
        self.lines_cleared += @as(u32, cleared);

        const line_scores = [_]u32{ 0, 100, 300, 500, 800 };
        self.score += line_scores[@intCast(cleared)] * (self.level + 1);
        self.level = self.lines_cleared / 10;

        // An I piece that locked hanging over a wall costs a garbage line.
        if (final_piece.shape_type == .I and final_wall_out) {
            const hole_col: usize = Board.WIDTH / 2;
            if (self.board.addPenaltyLine(hole_col)) {
                self.game_over = true;
                self.top_out_reason = .lock_out;
                self.eval_cache.recompute(&self.board);
                return;
            }
        }

        self.eval_cache.recompute(&self.board);
        self.hold_used = false;
        self.spawnNextPiece();
    }

    fn finalizeCollapse(self: *GameState) void {
        if (self.game_over) return;
        const pick_a = self.rollCollapsePick();
        self.finalizeCollapseWithPick(pick_a);
    }
};

test "same seed produces the same game" {
    var a = GameState.init(1234);
    var b = GameState.init(1234);
    for (0..40) |_| {
        try std.testing.expectEqual(a.current_piece.state_a.shape_type, b.current_piece.state_a.shape_type);
        try std.testing.expectEqual(a.current_piece.prob_a, b.current_piece.prob_a);
        a.hardDrop();
        b.hardDrop();
        try std.testing.expectEqualDeep(a.board, b.board);
    }
}

test "quantum pieces always have two distinct shapes and increasing serials" {
    var state = GameState.init(5);
    var last_serial = state.current_piece.serial;
    for (0..500) |_| {
        if (state.game_over) {
            state = GameState.init(state.pieces_generated);
            last_serial = state.current_piece.serial;
        }
        try std.testing.expect(state.current_piece.state_a.shape_type != state.current_piece.state_b.shape_type);
        try std.testing.expect(state.next_piece.serial == state.current_piece.serial + 1);
        state.hardDrop();
        if (!state.game_over) {
            try std.testing.expect(state.current_piece.serial > last_serial);
            last_serial = state.current_piece.serial;
        }
    }
}

test "hold swaps once per piece" {
    var state = GameState.init(9);
    const first = state.current_piece.serial;
    try std.testing.expect(state.canHold());
    state.tryHold();
    try std.testing.expect(!state.canHold());
    try std.testing.expectEqual(first, state.held_piece.?.serial);
    try std.testing.expectEqual(first + 1, state.current_piece.serial);

    state.hardDrop();
    try std.testing.expect(state.canHold());
    state.tryHold();
    try std.testing.expectEqual(first, state.current_piece.serial);
}

test "rotation lock-delay resets are capped" {
    var state = GameState.init(3);
    // Land the piece without locking it.
    while (!(state.current_piece.grounded_a and state.current_piece.grounded_b) and !state.current_piece.locked_a and !state.current_piece.locked_b) {
        _ = state.tickGravity();
    }
    for (0..MAX_LOCK_RESETS + 5) |_| {
        state.tryRotateCW();
        state.tryRotateCCW();
    }
    try std.testing.expect(state.lock_resets <= MAX_LOCK_RESETS);
}

test "gravity speeds up with level" {
    var state = GameState.init(1);
    try std.testing.expectEqual(@as(i64, 1000), state.gravityIntervalMs());
    state.level = 5;
    try std.testing.expect(state.gravityIntervalMs() < 1000);
    state.level = 100;
    try std.testing.expectEqual(@as(i64, 100), state.gravityIntervalMs());
}

test "an I piece cannot be pushed off the board" {
    var state = GameState.init(11);
    // Force an I piece as state A and lock B so only A moves.
    state.current_piece = QuantumPiece.init(.I, .O, 0.5, 0);
    state.current_piece.locked_b = true;
    state.current_piece.state_a.rotateCW();
    for (0..40) |_| state.tryMoveHorizontal(1);
    try std.testing.expect(!physics.checkCollisionIgnoreWalls(&state.board, &state.current_piece.state_a));
    try std.testing.expect(state.current_piece.state_a.x <= 7);
}
