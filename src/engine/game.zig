const std = @import("std");
const Board = @import("board.zig").Board;
const physics = @import("physics.zig");
const piece_mod = @import("piece.zig");
const ShapeType = piece_mod.ShapeType;
const Piece = piece_mod.Piece;
const QuantumPiece = piece_mod.QuantumPiece;

const BAG_SIZE: usize = @typeInfo(ShapeType).@"enum".fields.len;
const ALL_SHAPES: [BAG_SIZE]ShapeType = .{ .I, .O, .T, .S, .Z, .J, .L };

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
    current_piece: QuantumPiece,
    rng: std.Random.Xoshiro256,
    shape_bag: [BAG_SIZE]ShapeType,
    bag_index: usize,
    score: u32,
    lines_cleared: u32,
    game_over: bool,
    top_out_reason: ?TopOutReason,
    state_a_impacted: bool,
    state_b_impacted: bool,

    /// Initializes the engine. A fixed seed guarantees deterministic chance nodes
    /// for the Expectimax search tree and reproducible debugging.
    pub fn init(seed: u64) GameState {
        var state = GameState{
            .board = Board.init(),
            .current_piece = undefined,
            .rng = std.Random.Xoshiro256.init(seed),
            .shape_bag = undefined,
            .bag_index = BAG_SIZE,
            .score = 0,
            .lines_cleared = 0,
            .game_over = false,
            .top_out_reason = null,
            .state_a_impacted = false,
            .state_b_impacted = false,
        };

        state.refillBag();
        state.spawnNextPiece();
        return state;
    }

    fn refillBag(self: *GameState) void {
        self.shape_bag = ALL_SHAPES;

        const random = self.rng.random();
        var i: usize = BAG_SIZE - 1;
        while (i > 0) : (i -= 1) {
            const j = random.intRangeLessThan(usize, 0, i + 1);
            std.mem.swap(ShapeType, &self.shape_bag[i], &self.shape_bag[j]);
        }

        self.bag_index = 0;
    }

    fn drawFromBag(self: *GameState) ShapeType {
        if (self.bag_index >= BAG_SIZE) {
            self.refillBag();
        }

        const shape = self.shape_bag[self.bag_index];
        self.bag_index += 1;
        return shape;
    }

    fn resolveSecondDuplicate(self: *GameState, exclude: ShapeType) ShapeType {
        std.debug.assert(self.bag_index > 0);
        const consumed_idx = self.bag_index - 1;

        var i: usize = self.bag_index;
        while (i < BAG_SIZE) : (i += 1) {
            if (self.shape_bag[i] == exclude) continue;

            const chosen = self.shape_bag[i];
            self.shape_bag[i] = self.shape_bag[consumed_idx];
            self.shape_bag[consumed_idx] = chosen;
            return chosen;
        }

        unreachable;
    }

    fn canMovePieceBy(self: *const GameState, piece: *const Piece, dx: i8, dy: i8) bool {
        var probe = piece.*;
        probe.x += dx;
        probe.y += dy;
        return !physics.checkCollision(&self.board, &probe);
    }

    fn refreshImpactFlags(self: *GameState) void {
        self.state_a_impacted = !self.canMovePieceBy(&self.current_piece.state_a, 0, 1);
        self.state_b_impacted = !self.canMovePieceBy(&self.current_piece.state_b, 0, 1);
    }

    /// Generates the next quantum superposition and checks for spawn obstruction.
    pub fn spawnNextPiece(self: *GameState) void {
        if (self.game_over) return;

        const shape_a = self.drawFromBag();
        var shape_b = self.drawFromBag();

        // Invariant: A quantum piece must comprise two distinct deterministic states.
        // With a 7-bag, equality only occurs at bag boundaries, so we swap in
        // the next distinct candidate from the same shuffled bag segment.
        if (shape_a == shape_b) {
            shape_b = self.resolveSecondDuplicate(shape_a);
        }

        const random = self.rng.random();
        const prob = 0.1 + (random.float(f32) * 0.8);
        self.current_piece = QuantumPiece.init(shape_a, shape_b, prob);
        self.state_a_impacted = false;
        self.state_b_impacted = false;

        // Trigger 1 (Block Out): Ensure the spawn zone is mathematically clear.
        if (physics.checkQuantumCollision(&self.board, &self.current_piece)) {
            self.game_over = true;
            self.top_out_reason = .block_out;
            return;
        }

        self.refreshImpactFlags();
    }

    /// Attempts a horizontal move for both states together.
    /// If either branch collides, the move is reverted.
    pub fn tryMoveHorizontal(self: *GameState, dx: i8) void {
        if (self.game_over) return;

        self.current_piece.state_a.x += dx;
        self.current_piece.state_b.x += dx;

        if (physics.checkCollision(&self.board, &self.current_piece.state_a) or
            physics.checkCollision(&self.board, &self.current_piece.state_b))
        {
            self.current_piece.state_a.x -= dx;
            self.current_piece.state_b.x -= dx;
            return;
        }

        self.refreshImpactFlags();
    }

    /// Rotates both deterministic states clockwise in-place.
    /// If either branch collides after rotation, both are reverted.
    pub fn tryRotateCW(self: *GameState) void {
        if (self.game_over) return;

        const old_a = self.current_piece.state_a.matrix;
        const old_b = self.current_piece.state_b.matrix;
        const old_rot_a = self.current_piece.state_a.rotation_idx;
        const old_rot_b = self.current_piece.state_b.rotation_idx;

        self.current_piece.state_a.rotateCW();
        self.current_piece.state_b.rotateCW();

        if (physics.checkCollision(&self.board, &self.current_piece.state_a) or
            physics.checkCollision(&self.board, &self.current_piece.state_b))
        {
            self.current_piece.state_a.matrix = old_a;
            self.current_piece.state_b.matrix = old_b;
            self.current_piece.state_a.rotation_idx = old_rot_a;
            self.current_piece.state_b.rotation_idx = old_rot_b;
            return;
        }

        self.refreshImpactFlags();
    }

    /// Applies one gravity tick with independent fall states.
    /// Returns true if this tick caused a collapse/lock transition.
    pub fn tickGravity(self: *GameState) bool {
        if (self.game_over) return false;

        if (!self.state_a_impacted) {
            self.current_piece.state_a.y += 1;
            if (physics.checkCollision(&self.board, &self.current_piece.state_a)) {
                self.current_piece.state_a.y -= 1;
                self.state_a_impacted = true;
            }
        }

        if (!self.state_b_impacted) {
            self.current_piece.state_b.y += 1;
            if (physics.checkCollision(&self.board, &self.current_piece.state_b)) {
                self.current_piece.state_b.y -= 1;
                self.state_b_impacted = true;
            }
        }

        if (self.state_a_impacted and self.state_b_impacted) {
            self.collapseAndLock();
            return true;
        }

        return false;
    }

    /// Drops the current quantum piece until collapse triggers.
    pub fn hardDrop(self: *GameState) void {
        while (!self.game_over) {
            if (self.tickGravity()) break;
        }
    }

    /// Resolves the quantum superposition into a deterministic state via PRNG,
    /// projects the result into the bitboard, and evaluates board clears.
    pub fn collapseAndLock(self: *GameState) void {
        if (self.game_over) return;
        std.debug.assert(self.state_a_impacted and self.state_b_impacted);

        const random = self.rng.random();
        const roll = random.float(f32);

        const final_piece = if (roll < self.current_piece.prob_a)
            self.current_piece.state_a
        else
            self.current_piece.state_b;

        var lock_out = false;
        var row: usize = 0;

        // Project the 4x4 matrix into the 128-bit board architecture.
        while (row < Piece.BOUND_SIZE) : (row += 1) {
            const shift_amount: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
            const piece_row: u16 = (final_piece.matrix >> shift_amount) & 0x0F;

            if (piece_row == 0) continue;

            const board_y: i16 = @as(i16, final_piece.y) + @as(i16, @intCast(row));

            // If bits lock above the playable arena, flag for Trigger 2 (Lock Out).
            // Do not write negative indices to the board array memory.
            if (board_y < 0) {
                lock_out = true;
                continue;
            }

            std.debug.assert(board_y < @as(i16, @intCast(Board.HEIGHT)));

            var projected_row: u16 = 0;
            const x_i16: i16 = @as(i16, final_piece.x);

            // Align the 4-bit shape mask with its physical column on the board.
            if (x_i16 < 0) {
                const shift_right_i16: i16 = -x_i16;
                std.debug.assert(shift_right_i16 <= 15);
                const shift_right: u4 = @intCast(shift_right_i16);
                projected_row = piece_row >> shift_right;
            } else {
                std.debug.assert(x_i16 <= 15);
                const shift_left: u4 = @intCast(x_i16);
                projected_row = piece_row << shift_left;
            }

            // Invariant: The move generator must never feed coordinates out of bounds.
            std.debug.assert((projected_row & ~Board.ROW_MASK) == 0);

            const b_y_usize: usize = @intCast(board_y);
            self.board.grid[b_y_usize] |= projected_row;
        }

        // Trigger 2 (Lock Out): Evaluate skyline breach post-lock.
        if (lock_out) {
            self.game_over = true;
            self.top_out_reason = .lock_out;
            return;
        }

        // O(N) line clear evaluation and score mutation.
        const cleared = self.board.clearFullLines();
        self.lines_cleared += @as(u32, cleared);
        self.score += @as(u32, cleared) * 100;

        self.spawnNextPiece();
    }
};
