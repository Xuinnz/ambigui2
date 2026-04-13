const std = @import("std");
const Board = @import("engine/board.zig").Board;
const piece_mod = @import("engine/piece.zig");
const ShapeType = piece_mod.ShapeType;
const QuantumPiece = piece_mod.QuantumPiece;

fn setOccupied(board: *Board, row_idx: usize, col_idx: usize, value: bool) void {
    std.debug.assert(row_idx < Board.HEIGHT);
    std.debug.assert(col_idx < Board.WIDTH);

    const shift: u4 = @intCast(col_idx);
    const bit: u16 = @as(u16, 1) << shift;

    if (value) {
        board.grid[row_idx] |= bit;
    } else {
        board.grid[row_idx] &= ~bit;
    }
}

pub fn main() !void {
    std.debug.print("=== AMBIGUI2 ENGINE TEST BENCH ===\n\n", .{});

    // ---------------------------------------------------------
    // TEST 1: Board Memory and Bitwise Line Clearing
    // ---------------------------------------------------------
    std.debug.print("[1] Testing Board Memory and Line Clearing...\n", .{});
    var board = Board.init();

    // Inject a full bottom line.
    board.grid[Board.HEIGHT - 1] = Board.ROW_MASK;

    // Inject a few blocks one row above.
    setOccupied(&board, Board.HEIGHT - 2, 0, true);
    setOccupied(&board, Board.HEIGHT - 2, 4, true);
    setOccupied(&board, Board.HEIGHT - 2, 9, true);

    std.debug.print("Initial State (solid bottom line):\n", .{});
    board.debugPrint();

    const cleared = board.clearFullLines();
    std.debug.print("Lines cleared: {d}\n", .{cleared});

    std.debug.print("State After Line Clear (former row 18 should now be row 19):\n", .{});
    board.debugPrint();

    // ---------------------------------------------------------
    // TEST 2: Quantum Superposition Sync
    // ---------------------------------------------------------
    std.debug.print("\n[2] Testing Quantum Superposition...\n", .{});

    var q_piece = QuantumPiece.init(ShapeType.T, ShapeType.Z, 0.70);

    std.debug.print(
        "Spawned T/Z Superposition at (X: {d}, Y: {d})\n",
        .{ q_piece.state_a.x, q_piece.state_a.y },
    );

    std.debug.print(
        "Combined Superposition Mask (Binary): {b:0>16}\n",
        .{q_piece.getSuperpositionMask()},
    );

    std.debug.print("\nSimulating Vector Movement: moveBy(-1, 2)...\n", .{});
    q_piece.moveBy(-1, 2);

    std.debug.print("New Position Sync Check:\n", .{});
    std.debug.print(
        "  -> State A (T): X: {d}, Y: {d}\n",
        .{ q_piece.state_a.x, q_piece.state_a.y },
    );
    std.debug.print(
        "  -> State B (Z): X: {d}, Y: {d}\n",
        .{ q_piece.state_b.x, q_piece.state_b.y },
    );

    std.debug.assert(q_piece.state_a.x == q_piece.state_b.x);
    std.debug.assert(q_piece.state_a.y == q_piece.state_b.y);
    std.debug.print("  -> Vector Sync: SUCCESS\n", .{});

    std.debug.print("\n=== ALL SYSTEMS NOMINAL ===\n", .{});
}
