//SRS wall kick tables. y grows downwards (board row index), so the y values
//are the negation of the usual y-up SRS tables.
const std = @import("std");
const ShapeType = @import("piece.zig").ShapeType;

pub const Kick = struct { dx: i8, dy: i8 };

pub const Direction = enum { cw, ccw };

pub const MAX_KICKS: usize = 5;

/// A kick list for one rotation; `len` is 1 for the O piece and 5 otherwise.
pub const KickList = struct {
    items: [MAX_KICKS]Kick,
    len: usize,

    pub fn slice(self: *const KickList) []const Kick {
        return self.items[0..self.len];
    }

    pub fn contains(self: *const KickList, kick: Kick) bool {
        for (self.slice()) |entry| {
            if (entry.dx == kick.dx and entry.dy == kick.dy) return true;
        }
        return false;
    }
};

//indexed by the rotation index the piece rotates FROM (r -> r+1)
const JLSTZ_KICKS_CW: [4][MAX_KICKS]Kick = .{
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = -1, .dy = -1 }, .{ .dx = 0, .dy = 2 }, .{ .dx = -1, .dy = 2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = 1, .dy = -1 }, .{ .dx = 0, .dy = 2 }, .{ .dx = 1, .dy = 2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = 1, .dy = 1 }, .{ .dx = 0, .dy = -2 }, .{ .dx = 1, .dy = -2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = -1, .dy = 1 }, .{ .dx = 0, .dy = -2 }, .{ .dx = -1, .dy = -2 } },
};

const I_KICKS_CW: [4][MAX_KICKS]Kick = .{
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = -2, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = -2, .dy = 1 }, .{ .dx = 1, .dy = -2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = 2, .dy = 0 }, .{ .dx = -1, .dy = -2 }, .{ .dx = 2, .dy = 1 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = 2, .dy = 0 }, .{ .dx = -1, .dy = 0 }, .{ .dx = 2, .dy = -1 }, .{ .dx = -1, .dy = 2 } },
    .{ .{ .dx = 0, .dy = 0 }, .{ .dx = 1, .dy = 0 }, .{ .dx = -2, .dy = 0 }, .{ .dx = 1, .dy = 2 }, .{ .dx = -2, .dy = -1 } },
};

/// Kicks for rotating `shape` out of rotation `from` in direction `dir`.
/// In SRS the kicks for r -> r-1 are the negation of the kicks for (r-1) -> r.
pub fn forRotation(shape: ShapeType, from: u2, dir: Direction) KickList {
    if (shape == .O) {
        var single = KickList{ .items = undefined, .len = 1 };
        single.items[0] = .{ .dx = 0, .dy = 0 };
        return single;
    }

    const table = if (shape == .I) &I_KICKS_CW else &JLSTZ_KICKS_CW;
    var list = KickList{ .items = undefined, .len = MAX_KICKS };
    switch (dir) {
        .cw => list.items = table[from],
        .ccw => {
            const cw_from = from -% 1;
            for (table[cw_from], 0..) |kick, i| {
                list.items[i] = .{ .dx = -kick.dx, .dy = -kick.dy };
            }
        },
    }
    return list;
}

test "CCW kicks undo CW kicks" {
    const cw = forRotation(.T, 0, .cw);
    const ccw = forRotation(.T, 1, .ccw);
    for (cw.slice(), ccw.slice()) |a, b| {
        try std.testing.expectEqual(-a.dx, b.dx);
        try std.testing.expectEqual(-a.dy, b.dy);
    }
}

test "O piece never kicks" {
    try std.testing.expectEqual(@as(usize, 1), forRotation(.O, 2, .ccw).len);
}
