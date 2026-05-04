const piece_mod = @import("engine/piece.zig");
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
