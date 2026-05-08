const std = @import("std");
const Board = @import("../engine/board.zig").Board;
const piece_mod = @import("../engine/piece.zig");
const QuantumPiece = piece_mod.QuantumPiece;

pub const wall_out_a_key: u64 = 0x9E3779B97F4A7C15;
pub const wall_out_b_key: u64 = 0xBF58476D1CE4E5B9;
pub const penalty_pending_key: u64 = 0x94D049BB133111EB;

pub inline fn penaltyPending(piece: *const QuantumPiece) bool {
    return (piece.state_a.shape_type == .I and piece.wall_out_a) or
        (piece.state_b.shape_type == .I and piece.wall_out_b);
}

/// XOR this into the main Zobrist key to capture penalty-relevant state.
pub inline fn penaltyHash(piece: *const QuantumPiece) u64 {
    var key: u64 = 0;
    if (piece.wall_out_a) key ^= wall_out_a_key;
    if (piece.wall_out_b) key ^= wall_out_b_key;
    if (penaltyPending(piece)) key ^= penalty_pending_key;
    return key;
}

const ROW_KEYS = buildRowKeys();

fn splitmix64(seed: u64) u64 {
    var z = seed +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn buildRowKeys() [Board.HEIGHT][1 << Board.WIDTH]u64 {
    var table: [Board.HEIGHT][1 << Board.WIDTH]u64 = undefined;
    var row: usize = 0;
    while (row < Board.HEIGHT) : (row += 1) {
        var mask: usize = 0;
        while (mask < (1 << Board.WIDTH)) : (mask += 1) {
            if (mask == 0) {
                table[row][mask] = 0;
            } else {
                const seed = (@as(u64, row) << 32) ^ @as(u64, mask);
                table[row][mask] = splitmix64(seed);
            }
        }
    }
    return table;
}

pub inline fn rowKey(row: usize, mask: u16) u64 {
    std.debug.assert(row < Board.HEIGHT);
    const idx: usize = @intCast(mask & Board.ROW_MASK);
    return ROW_KEYS[row][idx];
}

pub fn hashBoard(board: *const Board) u64 {
    var key: u64 = 0;
    var row: usize = 0;
    while (row < Board.HEIGHT) : (row += 1) {
        const mask = board.grid[row] & Board.ROW_MASK;
        if (mask != 0) {
            key ^= rowKey(row, mask);
        }
    }
    return key;
}
