const std = @import("std");
const Board = @import("board.zig").Board;

//the 7 shapes
pub const ShapeType = enum { I, O, T, S, Z, J, L };

//since all shapes can fit in a 4x4, we can use 16 bits.
//this is the spawn orientation of the shapes represented by hex from bits
pub const ShapeMasks = struct {
    pub const I: u16 = 0x0F00; //0000 1111 0000 0000
    pub const O: u16 = 0x0660; //0000 0110 0110 0000
    pub const T: u16 = 0x04E0; //0000 0100 1110 0000
    pub const S: u16 = 0x06C0; //0000 0110 1100 0000
    pub const Z: u16 = 0x0C60; //0000 1100 0110 0000
    pub const J: u16 = 0x08E0; //0000 1000 1110 0000
    pub const L: u16 = 0x02E0; //0000 0010 1110 0000
};

//retrieve the bitmask (ShapeMask) using the ShapeType
pub inline fn maskForShape(shape: ShapeType) u16 {
    return switch (shape) {
        .I => ShapeMasks.I,
        .O => ShapeMasks.O,
        .T => ShapeMasks.T,
        .S => ShapeMasks.S,
        .Z => ShapeMasks.Z,
        .J => ShapeMasks.J,
        .L => ShapeMasks.L,
    };
}

pub inline fn shapeIndex(shape: ShapeType) usize {
    return @intFromEnum(shape);
}

// Precomputed shape rotations (spawn, CW1, CW2, CW3).
pub const ROTATION_MASKS: [7][4]u16 = .{
    .{ 0x0F00, 0x4444, 0x00F0, 0x2222 }, // I
    .{ 0x0660, 0x0660, 0x0660, 0x0660 }, // O
    .{ 0x04E0, 0x0262, 0x0720, 0x4640 }, // T
    .{ 0x06C0, 0x0462, 0x0360, 0x4620 }, // S
    .{ 0x0C60, 0x0264, 0x0630, 0x2640 }, // Z
    .{ 0x08E0, 0x0226, 0x0710, 0x6440 }, // J
    .{ 0x02E0, 0x0622, 0x0740, 0x4460 }, // L
};

//represents one block
pub const Piece = struct {
    pub const BOUND_SIZE: usize = 4; //dimension of the block is only 4x4
    pub const DEFAULT_SPAWN_Y: i8 = -1; //spawn above ceiling

    shape_type: ShapeType,
    matrix: u16,
    rotation_idx: u2,
    x: i8,
    y: i8,

    //initializes a piece
    pub fn init(shape: ShapeType) Piece {
        //safety check
        std.debug.assert(Board.WIDTH >= BOUND_SIZE);

        //get center spawn
        const spawn_x: i8 = @intCast((Board.WIDTH - BOUND_SIZE) / 2);
        const idx = shapeIndex(shape);

        return .{
            .shape_type = shape,
            .matrix = ROTATION_MASKS[idx][0],
            .rotation_idx = 0,
            .x = spawn_x,
            .y = DEFAULT_SPAWN_Y,
        };
    }

    pub fn rotateCW(self: *Piece) void {
        const idx = shapeIndex(self.shape_type);
        const next_idx: u2 = @intCast((@as(u3, self.rotation_idx) + 1) & 0b11);
        self.rotation_idx = next_idx;
        self.matrix = ROTATION_MASKS[idx][next_idx];
    }
};

//simulating a piece existing in two states
pub const QuantumPiece = struct {
    //two possible shapes
    state_a: Piece,
    state_b: Piece,

    // Stored with the piece so hashing/serialization includes grounded and wall-out state.
    grounded_a: bool,
    grounded_b: bool,
    wall_out_a: bool,
    wall_out_b: bool,

    //probability of piece collapsing into shape_a upong landing
    prob_a: f32,

    //initialize
    pub fn init(shape_a: ShapeType, shape_b: ShapeType, probability_a: f32) QuantumPiece {
        std.debug.assert(shape_a != shape_b); //2 shapes must not be the same
        std.debug.assert(std.math.isFinite(probability_a)); //must be a valid float
        std.debug.assert(probability_a >= 0.0 and probability_a <= 1.0);

        return .{
            .state_a = Piece.init(shape_a),
            .state_b = Piece.init(shape_b),
            .grounded_a = false,
            .grounded_b = false,
            .wall_out_a = false,
            .wall_out_b = false,
            .prob_a = probability_a,
        };
    }

    pub fn resetToSpawn(self: *QuantumPiece) void {
        self.state_a = Piece.init(self.state_a.shape_type);
        self.state_b = Piece.init(self.state_b.shape_type);
        self.grounded_a = false;
        self.grounded_b = false;
        self.wall_out_a = false;
        self.wall_out_b = false;
    }

    // combines the bitmask of both states into a single shadow
    pub inline fn getSuperpositionMask(self: *const QuantumPiece) u16 {
        return self.state_a.matrix | self.state_b.matrix;
    }

    // self explanatory
    pub inline fn probabilityB(self: *const QuantumPiece) f32 {
        return 1.0 - self.prob_a;
    }

    //move the 2 states simultaneously
    pub fn moveBy(self: *QuantumPiece, dx: i8, dy: i8) void {
        self.state_a.x += dx;
        self.state_a.y += dy;
        self.state_b.x += dx;
        self.state_b.y += dy;
    }
};
