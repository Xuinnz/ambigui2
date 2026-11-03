//7-bag randomizer. Every shape appears exactly once per shuffled bag.
const std = @import("std");
const ShapeType = @import("piece.zig").ShapeType;

pub const BAG_SIZE: usize = @typeInfo(ShapeType).@"enum".fields.len;
const ALL_SHAPES: [BAG_SIZE]ShapeType = .{ .I, .O, .T, .S, .Z, .J, .L };

pub const Bag = struct {
    shapes: [BAG_SIZE]ShapeType,
    index: usize,

    /// An exhausted bag; the first draw shuffles it.
    pub fn init() Bag {
        return .{ .shapes = ALL_SHAPES, .index = BAG_SIZE };
    }

    pub fn refill(self: *Bag, random: std.Random) void {
        self.shapes = ALL_SHAPES;

        //Fisher-Yates shuffle
        var i: usize = BAG_SIZE - 1;
        while (i > 0) : (i -= 1) {
            const j = random.intRangeLessThan(usize, 0, i + 1);
            std.mem.swap(ShapeType, &self.shapes[i], &self.shapes[j]);
        }

        self.index = 0;
    }

    pub fn draw(self: *Bag, random: std.Random) ShapeType {
        if (self.index >= BAG_SIZE) self.refill(random);

        const shape = self.shapes[self.index];
        self.index += 1;
        return shape;
    }

    /// Replaces the shape just drawn with the next shape in this bag that is not
    /// `exclude`, keeping the bag a permutation.
    pub fn redrawExcluding(self: *Bag, exclude: ShapeType) ShapeType {
        std.debug.assert(self.index > 0);
        const consumed_idx = self.index - 1;

        var i: usize = self.index;
        while (i < BAG_SIZE) : (i += 1) {
            if (self.shapes[i] == exclude) continue;

            const chosen = self.shapes[i];
            self.shapes[i] = self.shapes[consumed_idx];
            self.shapes[consumed_idx] = chosen;
            return chosen;
        }

        @panic("Bag.redrawExcluding: no valid non-duplicate found in bag — invariant broken");
    }
};

test "a bag yields each shape exactly once" {
    var rng = std.Random.Xoshiro256.init(7);
    var bag = Bag.init();
    var seen = [_]bool{false} ** BAG_SIZE;
    for (0..BAG_SIZE) |_| {
        const shape = bag.draw(rng.random());
        try std.testing.expect(!seen[@intFromEnum(shape)]);
        seen[@intFromEnum(shape)] = true;
    }
}

test "same seed gives the same sequence" {
    var rng_a = std.Random.Xoshiro256.init(99);
    var rng_b = std.Random.Xoshiro256.init(99);
    var bag_a = Bag.init();
    var bag_b = Bag.init();
    for (0..50) |_| {
        try std.testing.expectEqual(bag_a.draw(rng_a.random()), bag_b.draw(rng_b.random()));
    }
}
