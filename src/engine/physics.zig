const std = @import("std");
const Board = @import("board.zig").Board;
const piece_mod = @import("piece.zig");
const Piece = piece_mod.Piece;
const QuantumPiece = piece_mod.QuantumPiece;

/// One 4-bit row of a piece, projected into board column space.
/// Projection happens in a u32 so no block is ever silently shifted out of the word.
pub const ProjectedRow = struct {
    /// Bits that land on the 10 playable columns.
    on_board: u16,
    /// True if any block sits right of the last column.
    off_right: bool,
    /// True if any block sits left of column 0.
    off_left: bool,

    pub inline fn offBoard(self: ProjectedRow) bool {
        return self.off_left or self.off_right;
    }
};

/// Extracts row `row` (0 = top) of the piece's 4x4 matrix as a 4-bit value.
/// Row 0 is stored in the highest 4 bits (bits 12-15), row 3 in the lowest.
pub inline fn pieceRow(piece: *const Piece, row: usize) u16 {
    const shift_amount: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
    return (piece.matrix >> shift_amount) & 0x0F;
}

/// Shifts a 4-bit piece row to the piece's x offset.
pub inline fn projectRow(piece_row: u16, x: i8) ProjectedRow {
    std.debug.assert(x >= -@as(i8, Piece.BOUND_SIZE) and x <= @as(i8, Board.WIDTH + Piece.BOUND_SIZE));
    const wide_row: u32 = piece_row;
    if (x < 0) {
        const shift: u5 = @intCast(-@as(i16, x));
        const shifted = wide_row >> shift;
        return .{
            .on_board = @intCast(shifted & Board.ROW_MASK),
            .off_right = false,
            // Shifting back reveals whether a block fell off the left edge.
            .off_left = (shifted << shift) != wide_row,
        };
    }
    const shifted = wide_row << @as(u5, @intCast(x));
    return .{
        .on_board = @intCast(shifted & Board.ROW_MASK),
        .off_right = (shifted & ~@as(u32, Board.ROW_MASK)) != 0,
        .off_left = false,
    };
}

/// Checks if a standard piece collides with the floor, walls, or locked board cells.
/// Evaluates using bit-row projection to avoid expensive 2D array iterations.
pub fn checkCollision(board: *const Board, piece: *const Piece) bool {
    // Cache the board height as an i16 to allow safe comparisons with the
    // piece's Y coordinate, which can be negative during spawn.
    const board_height_i16: i16 = @intCast(Board.HEIGHT);

    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const piece_row = pieceRow(piece, row);
        // If this row of the 4x4 bounding box has no blocks, skip it.
        if (piece_row == 0) continue;

        const projected = projectRow(piece_row, piece.x);
        // Wall collision: a block left of column 0 or right of column 9.
        if (projected.offBoard()) return true;

        const board_y: i16 = @as(i16, piece.y) + @as(i16, @intCast(row));
        // Floor collision.
        if (board_y >= board_height_i16) return true;
        // Above the visible board (spawning): cannot hit locked blocks yet.
        if (board_y < 0) continue;

        // A single bitwise AND checks all 10 columns for overlap simultaneously.
        if ((board.grid[@intCast(board_y)] & projected.on_board) != 0) return true;
    }

    return false;
}

/// Checks only left/right wall overlap for a piece.
pub fn checkWallCollision(piece: *const Piece) bool {
    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const piece_row = pieceRow(piece, row);
        if (piece_row == 0) continue;
        if (projectRow(piece_row, piece.x).offBoard()) return true;
    }
    return false;
}

/// Checks collision against the floor and locked blocks, ignoring wall overlap.
/// Used for I pieces, which may hang over a wall (at the cost of a penalty line)
/// as long as at least one block stays on the board.
pub fn checkCollisionIgnoreWalls(board: *const Board, piece: *const Piece) bool {
    const board_height_i16: i16 = @intCast(Board.HEIGHT);
    var any_on_board = false;

    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const piece_row = pieceRow(piece, row);
        if (piece_row == 0) continue;

        const projected = projectRow(piece_row, piece.x);
        if (projected.on_board != 0) any_on_board = true;

        const board_y: i16 = @as(i16, piece.y) + @as(i16, @intCast(row));
        if (board_y >= board_height_i16) return true;
        if (board_y < 0) continue;

        if ((board.grid[@intCast(board_y)] & projected.on_board) != 0) return true;
    }

    // A piece pushed completely past a wall has left the playfield.
    return !any_on_board;
}

/// Checks collision for a Dual-State piece.
/// Returns true if either deterministic branch collides.
pub inline fn checkQuantumCollision(board: *const Board, q_piece: *const QuantumPiece) bool {
    // Fail-fast mathematical invariants
    std.debug.assert(std.math.isFinite(q_piece.prob_a));
    std.debug.assert(q_piece.prob_a >= 0.0 and q_piece.prob_a <= 1.0);

    return checkCollision(board, &q_piece.state_a) or
        checkCollision(board, &q_piece.state_b);
}

test "projectRow keeps every block inside the u32" {
    // A vertical I row (single block in column 2) pushed far right must be
    // reported as off-board instead of vanishing.
    const projected = projectRow(0b0100, 14);
    try std.testing.expectEqual(@as(u16, 0), projected.on_board);
    try std.testing.expect(projected.off_right);
}

test "projectRow detects left clipping" {
    const projected = projectRow(0b0011, -1);
    try std.testing.expectEqual(@as(u16, 0b0001), projected.on_board);
    try std.testing.expect(projected.off_left);
}

test "checkCollision walls, floor and blocks" {
    var board = Board.init();
    var piece = Piece.init(.O);

    piece.y = 0;
    try std.testing.expect(!checkCollision(&board, &piece));

    piece.x = -2;
    try std.testing.expect(checkCollision(&board, &piece));
    piece.x = 8;
    try std.testing.expect(checkCollision(&board, &piece));
    piece.x = 3;

    piece.y = 18;
    try std.testing.expect(checkCollision(&board, &piece));
    piece.y = 17;
    try std.testing.expect(!checkCollision(&board, &piece));

    board.grid[19] = @as(u16, 1) << 4;
    try std.testing.expect(checkCollision(&board, &piece));
}

test "checkCollisionIgnoreWalls rejects a piece fully past the wall" {
    const board = Board.init();
    var vertical_i = Piece.init(.I);
    vertical_i.rotateCW();
    vertical_i.y = 0;

    // Column 2 of the box is the block column; x = 7 puts it in column 9.
    vertical_i.x = 7;
    try std.testing.expect(!checkCollisionIgnoreWalls(&board, &vertical_i));
    vertical_i.x = 8;
    try std.testing.expect(checkCollisionIgnoreWalls(&board, &vertical_i));
    vertical_i.x = 14;
    try std.testing.expect(checkCollisionIgnoreWalls(&board, &vertical_i));

    // A horizontal I may hang over the right wall while part of it is on board.
    var horizontal_i = Piece.init(.I);
    horizontal_i.y = 0;
    horizontal_i.x = 8;
    try std.testing.expect(!checkCollisionIgnoreWalls(&board, &horizontal_i));
    try std.testing.expect(checkWallCollision(&horizontal_i));
}
