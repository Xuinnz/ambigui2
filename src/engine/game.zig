const std = @import("std");
const Board = @import("board.zig").Board;
const physics = @import("physics.zig");
const piece_mod = @import("piece.zig");
const ShapeType = piece_mod.ShapeType;
const Piece = piece_mod.Piece;
const QuantumPiece = piece_mod.QuantumPiece;

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
    score: u32,
    lines_cleared: u32,
    game_over: bool,
    top_out_reason: ?TopOutReason,

    /// Initializes the engine. A fixed seed guarantees deterministic chance nodes
    /// for the Expectimax search tree and reproducible debugging.
    pub fn init(seed: u64) GameState {
        var state = GameState{
            .board = Board.init(),
            .current_piece = undefined,
            .rng = std.Random.Xoshiro256.init(seed),
            .score = 0,
            .lines_cleared = 0,
            .game_over = false,
            .top_out_reason = null,
        };
        state.spawnNextPiece();
        return state;
    }

    /// Generates the next quantum superposition and checks for spawn obstruction.
    pub fn spawnNextPiece(self: *GameState) void {
        if (self.game_over) return;

        const random = self.rng.random();
        const shape_count: u8 = @intCast(@typeInfo(ShapeType).@"enum".fields.len);

        const shape_a = @as(ShapeType, @enumFromInt(random.intRangeLessThan(u8, 0, shape_count)));
        var shape_b = @as(ShapeType, @enumFromInt(random.intRangeLessThan(u8, 0, shape_count)));

        // Invariant: A quantum piece must comprise two distinct deterministic states.
        while (shape_a == shape_b) {
            shape_b = @as(ShapeType, @enumFromInt(random.intRangeLessThan(u8, 0, shape_count)));
        }

        const prob = 0.1 + (random.float(f32) * 0.8);
        self.current_piece = QuantumPiece.init(shape_a, shape_b, prob);

        // Trigger 1 (Block Out): Ensure the spawn zone is mathematically clear.
        if (physics.checkQuantumCollision(&self.board, &self.current_piece)) {
            self.game_over = true;
            self.top_out_reason = .block_out;
        }
    }

    /// Resolves the quantum superposition into a deterministic state via PRNG,
    /// projects the result into the bitboard, and evaluates board clears.
    pub fn collapseAndLock(self: *GameState) void {
        if (self.game_over) return;

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
