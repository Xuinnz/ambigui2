//Board features used by the AI's heuristic, and the weights that combine them.
const std = @import("std");
const Board = @import("board.zig").Board;

pub const Weights = struct {
    w_aggregate: f32,
    w_holes: f32,
    w_bumpiness: f32,
    w_wells: f32,
    w_row_transitions: f32,
    w_col_transitions: f32,

    pub const COUNT: usize = @typeInfo(Weights).@"struct".fields.len;

    pub fn toArray(self: Weights) [COUNT]f32 {
        var out: [COUNT]f32 = undefined;
        inline for (@typeInfo(Weights).@"struct".fields, 0..) |field, i| {
            out[i] = @field(self, field.name);
        }
        return out;
    }

    pub fn fromArray(values: [COUNT]f32) Weights {
        var out: Weights = undefined;
        inline for (@typeInfo(Weights).@"struct".fields, 0..) |field, i| {
            @field(out, field.name) = values[i];
        }
        return out;
    }
};

pub const EvalCache = struct {
    col_heights: [Board.WIDTH]u8,
    hole_count: u16,
    bumpiness: u16,
    aggregate_height: u16,
    wells: u16,
    row_transitions: u16,
    col_transitions: u16,

    pub fn init() EvalCache {
        return .{
            .col_heights = [_]u8{0} ** Board.WIDTH,
            .hole_count = 0,
            .bumpiness = 0,
            .aggregate_height = 0,
            .wells = 0,
            .row_transitions = 0,
            .col_transitions = 0,
        };
    }

    /// Recomputes every feature from the board. Works a whole row at a time:
    /// each feature is a popcount over masked row words instead of a per-cell loop.
    pub fn recompute(self: *EvalCache, board: *const Board) void {
        const M = Board.ROW_MASK;

        self.hole_count = 0;
        self.row_transitions = 0;
        self.col_transitions = 0;
        self.col_heights = [_]u8{0} ** Board.WIDTH;

        // `covered` accumulates every column that has a block at or above the
        // current row. An empty cell in a covered column is a hole, and a column
        // that becomes covered at this row gets its height from this row.
        var covered: u16 = 0;
        var row: usize = 0;
        while (row < Board.HEIGHT) : (row += 1) {
            const r = board.grid[row] & M;

            var newly_covered = r & ~covered;
            while (newly_covered != 0) {
                const col = @ctz(newly_covered);
                self.col_heights[col] = @intCast(Board.HEIGHT - row);
                newly_covered &= newly_covered - 1;
            }
            covered |= r;
            self.hole_count += @popCount(covered & ~r);

            // Row transitions, with both walls treated as filled:
            // [wall][c0 .. c9][wall] has 11 adjacent pairs.
            const framed: u16 = 1 | (r << 1) | (@as(u16, 1) << (Board.WIDTH + 1));
            self.row_transitions += @popCount((framed ^ (framed >> 1)) & ((@as(u16, 1) << (Board.WIDTH + 1)) - 1));

            // Column transitions between this row and the one below it;
            // the floor below the last row counts as filled.
            const below: u16 = if (row + 1 < Board.HEIGHT) board.grid[row + 1] & M else M;
            self.col_transitions += @popCount(r ^ below);
        }

        self.aggregate_height = 0;
        self.bumpiness = 0;
        self.wells = 0;
        for (self.col_heights, 0..) |height, col| {
            self.aggregate_height += height;

            const h: i16 = height;
            if (col + 1 < Board.WIDTH) {
                self.bumpiness += @intCast(@abs(h - @as(i16, self.col_heights[col + 1])));
            }

            // Walls count as full-height neighbours.
            const left_h: i16 = if (col == 0) Board.HEIGHT else self.col_heights[col - 1];
            const right_h: i16 = if (col == Board.WIDTH - 1) Board.HEIGHT else self.col_heights[col + 1];
            const well_depth = @min(left_h, right_h) - h;
            if (well_depth > 0) self.wells += @intCast(well_depth);
        }
    }

    pub fn evaluate(self: *const EvalCache, weights: *const Weights) f32 {
        return weights.w_aggregate * @as(f32, @floatFromInt(self.aggregate_height)) +
            weights.w_holes * @as(f32, @floatFromInt(self.hole_count)) +
            weights.w_bumpiness * @as(f32, @floatFromInt(self.bumpiness)) +
            weights.w_wells * @as(f32, @floatFromInt(self.wells)) +
            weights.w_row_transitions * @as(f32, @floatFromInt(self.row_transitions)) +
            weights.w_col_transitions * @as(f32, @floatFromInt(self.col_transitions));
    }
};

// Cell-by-cell reference implementation; the bitwise version must match it exactly
// so weights trained against the original features stay valid.
fn referenceRecompute(board: *const Board) EvalCache {
    var c = EvalCache.init();

    for (0..Board.WIDTH) |col| {
        const col_mask: u16 = @as(u16, 1) << @as(u4, @intCast(col));
        var height: u8 = 0;
        var seen_block = false;
        for (0..Board.HEIGHT) |row| {
            if ((board.grid[row] & col_mask) != 0) {
                if (!seen_block) {
                    seen_block = true;
                    height = @intCast(Board.HEIGHT - row);
                }
            } else if (seen_block) {
                c.hole_count += 1;
            }
        }
        c.col_heights[col] = height;
        c.aggregate_height += height;
    }

    for (0..Board.WIDTH - 1) |col| {
        c.bumpiness += @intCast(@abs(@as(i16, c.col_heights[col]) - @as(i16, c.col_heights[col + 1])));
    }

    for (0..Board.WIDTH) |col| {
        const left_h: i16 = if (col == 0) Board.HEIGHT else c.col_heights[col - 1];
        const right_h: i16 = if (col == Board.WIDTH - 1) Board.HEIGHT else c.col_heights[col + 1];
        const well_depth = @min(left_h, right_h) - @as(i16, c.col_heights[col]);
        if (well_depth > 0) c.wells += @intCast(well_depth);
    }

    for (0..Board.HEIGHT) |row| {
        var prev_filled = true;
        for (0..Board.WIDTH) |col| {
            const filled = (board.grid[row] & (@as(u16, 1) << @as(u4, @intCast(col)))) != 0;
            if (filled != prev_filled) c.row_transitions += 1;
            prev_filled = filled;
        }
        if (!prev_filled) c.row_transitions += 1;
    }

    for (0..Board.WIDTH) |col| {
        const col_mask: u16 = @as(u16, 1) << @as(u4, @intCast(col));
        var prev_filled = true;
        var r: usize = Board.HEIGHT;
        while (r > 0) {
            r -= 1;
            const filled = (board.grid[r] & col_mask) != 0;
            if (filled != prev_filled) c.col_transitions += 1;
            prev_filled = filled;
        }
    }

    return c;
}

test "EvalCache recompute empty board" {
    const board = Board.init();
    var cache = EvalCache.init();
    cache.recompute(&board);

    try std.testing.expectEqual(@as(u16, 0), cache.hole_count);
    try std.testing.expectEqual(@as(u16, 0), cache.bumpiness);
    try std.testing.expectEqual(@as(u16, 0), cache.aggregate_height);
    for (cache.col_heights) |height| {
        try std.testing.expectEqual(@as(u8, 0), height);
    }
}

test "EvalCache recompute metrics" {
    var board = Board.init();
    board.grid[15] = (@as(u16, 1) << 3);
    board.grid[17] = (@as(u16, 1) << 1);
    board.grid[18] = (@as(u16, 1) << 0);
    board.grid[19] = (@as(u16, 1) << 0) | (@as(u16, 1) << 3);

    var cache = EvalCache.init();
    cache.recompute(&board);

    try std.testing.expectEqual(@as(u8, 2), cache.col_heights[0]);
    try std.testing.expectEqual(@as(u8, 3), cache.col_heights[1]);
    try std.testing.expectEqual(@as(u8, 0), cache.col_heights[2]);
    try std.testing.expectEqual(@as(u8, 5), cache.col_heights[3]);
    try std.testing.expectEqual(@as(u8, 0), cache.col_heights[4]);

    try std.testing.expectEqual(@as(u16, 5), cache.hole_count);
    try std.testing.expectEqual(@as(u16, 14), cache.bumpiness);
    try std.testing.expectEqual(@as(u16, 10), cache.aggregate_height);
}

test "bitwise EvalCache matches the cell-by-cell reference on random boards" {
    var rng = std.Random.Xoshiro256.init(0xB0A2D);
    const random = rng.random();

    for (0..2000) |_| {
        var board = Board.init();
        // Random skyline with random holes, like a real mid-game board.
        const fill_from = random.intRangeLessThan(usize, 0, Board.HEIGHT);
        for (fill_from..Board.HEIGHT) |row| {
            board.grid[row] = random.int(u16) & Board.ROW_MASK;
        }

        var fast = EvalCache.init();
        fast.recompute(&board);
        const slow = referenceRecompute(&board);
        try std.testing.expectEqualDeep(slow, fast);
    }
}

test "Weights array round trip" {
    const w = Weights{
        .w_aggregate = 1,
        .w_holes = 2,
        .w_bumpiness = 3,
        .w_wells = 4,
        .w_row_transitions = 5,
        .w_col_transitions = 6,
    };
    try std.testing.expectEqualDeep(w, Weights.fromArray(w.toArray()));
}
