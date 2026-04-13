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

//represents one block
pub const Piece = struct {
    pub const BOUND_SIZE: usize = 4; //dimension of the block is only 4x4
    pub const DEFAULT_SPAWN_Y: i8 = -1; //spawn above ceiling

    shape_type: ShapeType,
    matrix: u16,
    x: i8,
    y: i8,

    //initializes a piece
    pub fn init(shape: ShapeType) Piece {
        //safety check
        std.debug.assert(Board.WIDTH >= BOUND_SIZE);

        //get center spawn
        const spawn_x: i8 = @intCast((Board.WIDTH - BOUND_SIZE) / 2);

        return .{
            .shape_type = shape,
            .matrix = maskForShape(shape),
            .x = spawn_x,
            .y = DEFAULT_SPAWN_Y,
        };
    }
};

//simulating a piece existing in two states
pub const QuantumPiece = struct {
    //two possible shapes
    state_a: Piece,
    state_b: Piece,

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
            .prob_a = probability_a,
        };
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
