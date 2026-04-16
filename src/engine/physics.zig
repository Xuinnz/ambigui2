const std = @import("std");
const Board = @import("board.zig").Board;
const piece_mod = @import("piece.zig");
const Piece = piece_mod.Piece;
const QuantumPiece = piece_mod.QuantumPiece;

/// Checks if a standard piece collides with the floor, walls, or locked board cells.
/// Evaluates using 16-bit projection math to avoid expensive 2D array iterations.
pub fn checkCollision(board: *const Board, piece: *const Piece) bool {
    var row: usize = 0;
    // Cache the board height as an i16 to allow safe mathematical comparisons
    // with the piece's Y coordinate, which can be negative during spawn.
    const board_height_i16: i16 = @intCast(Board.HEIGHT);

    while (row < Piece.BOUND_SIZE) : (row += 1) {
        // --- EXTRACTION ---
        // The piece matrix is a single u16 representing a 4x4 grid.
        // Row 0 is stored in the highest 4 bits (bits 12-15).
        // Row 3 is stored in the lowest 4 bits (bits 0-3).
        // We calculate the shift to push the target row down to the lowest 4 bits.
        const shift_amount: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);

        // Bitwise AND with 0x0F (binary 0000 1111) isolates just that 4-bit row.
        const piece_row: u16 = (piece.matrix >> shift_amount) & 0x0F;

        // Optimization: If this specific row of the 4x4 bounding box has no blocks, skip it.
        if (piece_row == 0) continue;

        // Calculate the absolute vertical position of this 4-bit slice on the game board.
        const board_y: i16 = @as(i16, piece.y) + @as(i16, @intCast(row));

        // --- VERTICAL COLLISIONS ---
        // 1. Floor collision: If this slice of the piece hits the floor, stop.
        if (board_y >= board_height_i16) return true;
        // 2. Ceiling bypass: If this slice is still above the visible board (spawning),
        // it cannot possibly collide with locked blocks or the floor yet.
        if (board_y < 0) continue;

        var projected_piece_row: u16 = 0;
        const x_i16: i16 = @as(i16, piece.x);

        // --- HORIZONTAL PROJECTION & WALL COLLISIONS ---
        if (x_i16 < 0) {
            // Negative X means the piece is partially off the LEFT side of the screen.
            // We shift it RIGHT in bit-space to align it with the board's 0-index.
            const shift_right_i16: i16 = -x_i16;
            std.debug.assert(shift_right_i16 <= 15); // Fail-fast memory protection
            const shift_right: u4 = @intCast(shift_right_i16);

            // Shift the shadow right. If a block was pushed off the edge of the u16, it is permanently lost.
            projected_piece_row = piece_row >> shift_right;

            // Left Wall Collision Logic:
            // We try to shift the shadow back to the left. If it does not perfectly match
            // the original piece_row, it means a physical block was chopped off during the right shift.
            // This proves the physical block tried to pass through the left wall.
            if ((projected_piece_row << shift_right) != piece_row) return true;
        } else {
            // Positive X means the piece is safely within or passing the right wall.
            // We shift it LEFT in bit-space to align it with its physical column on the board.
            std.debug.assert(x_i16 <= 15);
            const shift_left: u4 = @intCast(x_i16);
            projected_piece_row = piece_row << shift_left;
        }

        // Right Wall Collision Logic:
        // The playable board is 10 bits wide. ~Board.ROW_MASK isolates the 6 padding bits.
        // If our projected shadow overlaps with any padding bits, it has breached the right wall.
        if ((projected_piece_row & ~Board.ROW_MASK) != 0) return true;

        // --- LOCKED BLOCK COLLISION ---
        // Both the board row and the projected piece row are now perfectly aligned in memory.
        // A single bitwise AND checks all 10 columns for overlapping 1s simultaneously.
        const board_row_idx: usize = @intCast(board_y);
        if ((board.grid[board_row_idx] & projected_piece_row) != 0) return true;
    }

    // If all 4 rows of the piece clear the checks, the space is empty.
    return false;
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
