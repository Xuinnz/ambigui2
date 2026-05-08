const std = @import("std");
const Board = @import("board.zig").Board;
const physics = @import("physics.zig");
const zobrist = @import("../ai/zobrist.zig");
const piece_mod = @import("piece.zig");
const ShapeType = piece_mod.ShapeType;
const Piece = piece_mod.Piece;
const QuantumPiece = piece_mod.QuantumPiece;

const BAG_SIZE: usize = @typeInfo(ShapeType).@"enum".fields.len;
const ALL_SHAPES: [BAG_SIZE]ShapeType = .{ .I, .O, .T, .S, .Z, .J, .L };

const Kick = struct { dx: i8, dy: i8 };

const MAX_MOVES: usize = 128;

pub const Move = struct {
    state_a: Piece,
    state_b: Piece,
    wall_out_a: bool,
    wall_out_b: bool,
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
};

pub const EvalCache = struct {
    col_heights: [Board.WIDTH]u8,
    hole_count: u16,
    bumpiness: u16,
    aggregate_height: u16,

    pub fn init() EvalCache {
        return .{
            .col_heights = [_]u8{0} ** Board.WIDTH,
            .hole_count = 0,
            .bumpiness = 0,
            .aggregate_height = 0,
        };
    }

    pub fn recompute(self: *EvalCache, board: *const Board) void {
        self.hole_count = 0;
        self.bumpiness = 0;
        self.aggregate_height = 0;

        var col: usize = 0;
        while (col < Board.WIDTH) : (col += 1) {
            const col_mask: u16 = @as(u16, 1) << @as(u4, @intCast(col));
            var height: u8 = 0;
            var seen_block = false;

            var row: usize = 0;
            while (row < Board.HEIGHT) : (row += 1) {
                const row_masked = board.grid[row] & Board.ROW_MASK;
                const is_block = (row_masked & col_mask) != 0;
                if (is_block) {
                    if (!seen_block) {
                        seen_block = true;
                        height = @as(u8, @intCast(Board.HEIGHT - row));
                    }
                } else if (seen_block) {
                    self.hole_count += 1;
                }
            }

            self.col_heights[col] = height;
            self.aggregate_height += @as(u16, height);
        }

        col = 0;
        while (col + 1 < Board.WIDTH) : (col += 1) {
            const left = @as(i16, self.col_heights[col]);
            const right = @as(i16, self.col_heights[col + 1]);
            const diff = left - right;
            self.bumpiness += @as(u16, @intCast(@abs(diff)));
        }
    }
};

pub const Weights = struct {
    w_aggregate: f32,
    w_holes: f32,
    w_bumpiness: f32,
    w_lines: f32,
};

const JLSTZ_KICKS_CW: [4][5]Kick = .{
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = -1, .dy = -1 }, .{ .dx = 0, .dy = 2 }, .{ .dx = -1, .dy = 2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = 1, .dy = -1 }, .{ .dx = 0, .dy = 2 }, .{ .dx = 1, .dy = 2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = 1, .dy = 1 }, .{ .dx = 0, .dy = -2 }, .{ .dx = 1, .dy = -2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = -1, .dy = 1 }, .{ .dx = 0, .dy = -2 }, .{ .dx = -1, .dy = -2 } },
};

const I_KICKS_CW: [4][5]Kick = .{
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = -2, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = -2, .dy = 1 }, .{ .dx = 1, .dy = -2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = 2, .dy = 0 }, .{ .dx = -1, .dy = -2 }, .{ .dx = 2, .dy = 1 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = 2, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = 2, .dy = -1 }, .{ .dx = -1, .dy = 2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = -2, .dy = 0 }, .{ .dx = 1, .dy = 2 }, .{ .dx = -2, .dy = -1 } },
};

const ZERO_KICK: [1]Kick = .{.{ .dx = 0, .dy = 0 }};

fn kickTableForShape(shape: ShapeType, rot: u2) []const Kick {
    return switch (shape) {
        .O => ZERO_KICK[0..],
        .I => I_KICKS_CW[rot][0..],
        else => JLSTZ_KICKS_CW[rot][0..],
    };
}

fn kickInList(kick: Kick, list: []const Kick) bool {
    for (list) |entry| {
        if (entry.dx == kick.dx and entry.dy == kick.dy) return true;
    }
    return false;
}

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
    zobrist_hash: u64,
    current_piece: QuantumPiece,
    next_piece: QuantumPiece,
    held_piece: ?QuantumPiece,
    hold_used: bool,
    rng: std.Random.Xoshiro256,
    shape_bag: [BAG_SIZE]ShapeType,
    bag_index: usize,
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
            .zobrist_hash = 0,
            .current_piece = undefined,
            .next_piece = undefined,
            .held_piece = null,
            .hold_used = false,
            .rng = std.Random.Xoshiro256.init(seed),
            .shape_bag = undefined,
            .bag_index = BAG_SIZE,
            .score = 0,
            .lines_cleared = 0,
            .level = 0,
            .game_over = false,
            .top_out_reason = null,
        };

        state.refillBag();
        state.next_piece = state.generateQuantumPiece();
        state.spawnNextPiece();
        state.eval_cache.recompute(&state.board);
        state.zobrist_hash = zobrist.hashBoard(&state.board);
        return state;
    }

    /// Returns a cheap value copy for search tree branching.
    pub fn clone(self: *const GameState) GameState {
        return self.*;
    }

    pub fn evaluate(self: *const GameState, weights: *const Weights) f32 {
        const cache = &self.eval_cache;
        return weights.w_aggregate * @as(f32, @floatFromInt(cache.aggregate_height)) +
            weights.w_holes * @as(f32, @floatFromInt(cache.hole_count)) +
            weights.w_bumpiness * @as(f32, @floatFromInt(cache.bumpiness)) +
            weights.w_lines * @as(f32, @floatFromInt(self.lines_cleared));
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

                if (checkStateCollision(self, &probe_a) or
                    checkStateCollision(self, &probe_b))
                {
                    continue;
                }

                var drop_a = probe_a;
                while (!checkStateCollision(self, &drop_a)) {
                    drop_a.y += 1;
                }
                drop_a.y -= 1;

                var drop_b = probe_b;
                while (!checkStateCollision(self, &drop_b)) {
                    drop_b.y += 1;
                }
                drop_b.y -= 1;

                const wall_out_a = physics.checkWallCollision(&drop_a);
                const wall_out_b = physics.checkWallCollision(&drop_b);

                moves.append(.{
                    .state_a = drop_a,
                    .state_b = drop_b,
                    .wall_out_a = wall_out_a,
                    .wall_out_b = wall_out_b,
                });
            }
        }

        return moves;
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

        @panic("resolveSecondDuplicate: no valid non-duplicate found in bag — invariant broken");
    }

    fn generateQuantumPiece(self: *GameState) QuantumPiece {
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
        return QuantumPiece.init(shape_a, shape_b, prob);
    }

    fn canMovePieceBy(self: *const GameState, piece: *const Piece, dx: i8, dy: i8) bool {
        var probe = piece.*;
        probe.x += dx;
        probe.y += dy;
        return !checkStateCollision(self, &probe);
    }

    fn refreshImpactFlags(self: *GameState) void {
        self.current_piece.grounded_a = !self.canMovePieceBy(&self.current_piece.state_a, 0, 1);
        self.current_piece.grounded_b = !self.canMovePieceBy(&self.current_piece.state_b, 0, 1);
        self.current_piece.wall_out_a = physics.checkWallCollision(&self.current_piece.state_a);
        self.current_piece.wall_out_b = physics.checkWallCollision(&self.current_piece.state_b);
    }

    fn prepareCurrentPiece(self: *GameState) void {
        self.current_piece.grounded_a = false;
        self.current_piece.grounded_b = false;
        self.current_piece.wall_out_a = false;
        self.current_piece.wall_out_b = false;

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

    pub fn tryHold(self: *GameState) void {
        if (self.game_over or self.hold_used) return;

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

        self.current_piece.state_a.x += dx;
        self.current_piece.state_b.x += dx;

        if (checkStateCollision(self, &self.current_piece.state_a) or
            checkStateCollision(self, &self.current_piece.state_b))
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

        const old_a = self.current_piece.state_a;
        const old_b = self.current_piece.state_b;
        const old_rot = self.current_piece.state_a.rotation_idx;

        self.current_piece.state_a.rotateCW();
        self.current_piece.state_b.rotateCW();

        var applied = false;
        const kicks_a = kickTableForShape(old_a.shape_type, old_rot);
        const kicks_b = kickTableForShape(old_b.shape_type, old_rot);
        const primary = if (old_a.shape_type == .I or old_b.shape_type == .I)
            I_KICKS_CW[old_rot][0..]
        else
            kicks_a;
        const secondary = if (old_a.shape_type == .I)
            kicks_b
        else if (old_b.shape_type == .I)
            kicks_a
        else
            kicks_b;

        for (primary) |kick| {
            if (tryKick(self, old_a, old_b, kick)) {
                applied = true;
                break;
            }
        }

        if (!applied) {
            for (secondary) |kick| {
                if (kickInList(kick, primary)) continue;
                if (tryKick(self, old_a, old_b, kick)) {
                    applied = true;
                    break;
                }
            }
        }

        if (!applied) {
            self.current_piece.state_a = old_a;
            self.current_piece.state_b = old_b;
            return;
        }

        self.refreshImpactFlags();
    }

    /// Applies one gravity tick with independent fall states.
    /// Returns true if this tick caused a collapse/lock transition.
    pub fn tickGravity(self: *GameState) bool {
        if (self.game_over) return false;

        if (!self.current_piece.grounded_a) {
            self.current_piece.state_a.y += 1;
            if (checkStateCollision(self, &self.current_piece.state_a)) {
                self.current_piece.state_a.y -= 1;
                self.current_piece.grounded_a = true;
            }
        }

        if (!self.current_piece.grounded_b) {
            self.current_piece.state_b.y += 1;
            if (checkStateCollision(self, &self.current_piece.state_b)) {
                self.current_piece.state_b.y -= 1;
                self.current_piece.grounded_b = true;
            }
        }

        if (self.current_piece.grounded_a and self.current_piece.grounded_b) {
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
        std.debug.assert(self.current_piece.grounded_a and self.current_piece.grounded_b);

        const random = self.rng.random();
        const roll = random.float(f32);

        const collapse_is_a = roll < self.current_piece.prob_a;
        const final_piece = if (collapse_is_a)
            self.current_piece.state_a
        else
            self.current_piece.state_b;
        const final_wall_out = if (collapse_is_a)
            self.current_piece.wall_out_a
        else
            self.current_piece.wall_out_b;

        var lock_out = false;
        var hash_dirty = false;
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
            if (board_y >= @as(i16, @intCast(Board.HEIGHT))) continue;

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

            if (final_piece.shape_type == .I and final_wall_out) {
                projected_row &= Board.ROW_MASK;
            } else {
                // Invariant: The move generator must never feed coordinates out of bounds.
                std.debug.assert((projected_row & ~Board.ROW_MASK) == 0);
            }

            const b_y_usize: usize = @intCast(board_y);
            const old_row: u16 = self.board.grid[b_y_usize] & Board.ROW_MASK;
            const new_row: u16 = old_row | projected_row;
            if (new_row != old_row) {
                if (old_row != 0) {
                    self.zobrist_hash ^= zobrist.rowKey(b_y_usize, old_row);
                }
                self.board.grid[b_y_usize] = new_row;
                self.zobrist_hash ^= zobrist.rowKey(b_y_usize, new_row);
            }
        }

        // Trigger 2 (Lock Out): Evaluate skyline breach post-lock.
        if (lock_out) {
            self.game_over = true;
            self.top_out_reason = .lock_out;
            return;
        }

        // O(N) line clear evaluation and score mutation.
        const cleared = self.board.clearFullLines();
        std.debug.assert(cleared <= 4);
        self.lines_cleared += @as(u32, cleared);
        if (cleared > 0) {
            hash_dirty = true;
        }
        // Non-linear rewards (Tetris bonus) to avoid linear clear bias in evaluation.
        const line_scores = [_]u32{ 0, 100, 300, 500, 800 };
        self.score += line_scores[@intCast(cleared)] * (self.level + 1);
        // Standard progression: level increases every 10 cleared lines.
        self.level = self.lines_cleared / 10;

        if (final_piece.shape_type == .I and final_wall_out) {
            const hole_col: usize = Board.WIDTH / 2;
            if (self.board.addPenaltyLine(hole_col)) {
                self.game_over = true;
                self.top_out_reason = .lock_out;
                hash_dirty = true;
                self.eval_cache.recompute(&self.board);
                if (hash_dirty) {
                    self.zobrist_hash = zobrist.hashBoard(&self.board);
                }
                return;
            }
            hash_dirty = true;
        }

        self.eval_cache.recompute(&self.board);
        if (hash_dirty) {
            self.zobrist_hash = zobrist.hashBoard(&self.board);
        }
        self.hold_used = false;
        self.spawnNextPiece();
    }
};
