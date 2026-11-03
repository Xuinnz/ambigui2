//Keyboard handling with guideline-style auto-repeat, independent of raylib so
//it can be unit tested. Frontends report which keys are held each frame and
//get back the game actions to apply.
const std = @import("std");

pub const Action = enum { left, right, rotate_cw, rotate_ccw, hold, hard_drop, soft_drop };

/// Which keys are held down this frame.
pub const Keys = struct {
    left: bool = false,
    right: bool = false,
    soft_drop: bool = false,
    rotate_cw: bool = false,
    rotate_ccw: bool = false,
    hold: bool = false,
    hard_drop: bool = false,
};

pub const Actions = struct {
    items: [16]Action = undefined,
    len: usize = 0,

    fn push(self: *Actions, action: Action) void {
        if (self.len < self.items.len) {
            self.items[self.len] = action;
            self.len += 1;
        }
    }

    pub fn slice(self: *const Actions) []const Action {
        return self.items[0..self.len];
    }
};

pub const Controller = struct {
    /// Delayed auto shift: how long a direction is held before it repeats.
    das_ms: i64 = 167,
    /// Auto repeat rate: time between repeated shifts once DAS has charged.
    arr_ms: i64 = 33,
    /// Time between gravity ticks while soft drop is held.
    soft_drop_ms: i64 = 50,

    prev: Keys = .{},
    /// Direction currently auto-shifting: -1 left, 1 right, 0 none.
    shift_dir: i8 = 0,
    next_shift_ms: i64 = 0,
    next_soft_drop_ms: i64 = 0,

    pub fn update(self: *Controller, keys: Keys, now_ms: i64) Actions {
        var out = Actions{};

        // One-shot actions fire on the frame the key goes down.
        if (keys.rotate_cw and !self.prev.rotate_cw) out.push(.rotate_cw);
        if (keys.rotate_ccw and !self.prev.rotate_ccw) out.push(.rotate_ccw);
        if (keys.hold and !self.prev.hold) out.push(.hold);

        // Horizontal movement: the most recently pressed direction wins.
        const left_pressed = keys.left and !self.prev.left;
        const right_pressed = keys.right and !self.prev.right;
        if (left_pressed or right_pressed) {
            self.shift_dir = if (right_pressed) 1 else -1;
            out.push(if (self.shift_dir > 0) .right else .left);
            self.next_shift_ms = now_ms + self.das_ms;
        } else if ((self.shift_dir < 0 and !keys.left) or (self.shift_dir > 0 and !keys.right)) {
            // Released the active direction; fall back to the other if still held.
            self.shift_dir = if (keys.left) -1 else if (keys.right) 1 else 0;
            self.next_shift_ms = now_ms + self.das_ms;
        } else if (self.shift_dir != 0) {
            var repeats: usize = 0;
            while (now_ms >= self.next_shift_ms and repeats < 10) : (repeats += 1) {
                out.push(if (self.shift_dir > 0) .right else .left);
                self.next_shift_ms += self.arr_ms;
            }
            // After a long frame, do not try to catch up on missed repeats.
            if (now_ms >= self.next_shift_ms) self.next_shift_ms = now_ms + self.arr_ms;
        }

        if (keys.soft_drop) {
            if (!self.prev.soft_drop or now_ms >= self.next_soft_drop_ms) {
                out.push(.soft_drop);
                self.next_soft_drop_ms = now_ms + self.soft_drop_ms;
            }
        }

        // Hard drop last, so a shift or rotation pressed on the same frame applies first.
        if (keys.hard_drop and !self.prev.hard_drop) out.push(.hard_drop);

        self.prev = keys;
        return out;
    }
};

fn count(actions: Actions, action: Action) usize {
    var n: usize = 0;
    for (actions.slice()) |a| {
        if (a == action) n += 1;
    }
    return n;
}

test "tap moves once" {
    var c = Controller{};
    try std.testing.expectEqual(@as(usize, 1), count(c.update(.{ .left = true }, 0), .left));
    try std.testing.expectEqual(@as(usize, 0), count(c.update(.{ .left = true }, 16), .left));
    try std.testing.expectEqual(@as(usize, 0), count(c.update(.{}, 32), .left));
}

test "holding repeats after DAS at ARR" {
    var c = Controller{};
    _ = c.update(.{ .right = true }, 0);
    try std.testing.expectEqual(@as(usize, 0), count(c.update(.{ .right = true }, 100), .right));
    try std.testing.expectEqual(@as(usize, 1), count(c.update(.{ .right = true }, 167), .right));
    try std.testing.expectEqual(@as(usize, 0), count(c.update(.{ .right = true }, 180), .right));
    try std.testing.expectEqual(@as(usize, 1), count(c.update(.{ .right = true }, 200), .right));
}

test "latest direction wins and release falls back" {
    var c = Controller{};
    _ = c.update(.{ .left = true }, 0);
    const both = c.update(.{ .left = true, .right = true }, 50);
    try std.testing.expectEqual(@as(usize, 1), count(both, .right));
    try std.testing.expectEqual(@as(i8, 1), c.shift_dir);
    _ = c.update(.{ .left = true }, 60);
    try std.testing.expectEqual(@as(i8, -1), c.shift_dir);
}

test "rotation, hold and hard drop fire once per press" {
    var c = Controller{};
    const first = c.update(.{ .rotate_cw = true, .rotate_ccw = true, .hold = true, .hard_drop = true }, 0);
    try std.testing.expectEqual(@as(usize, 4), first.len);
    try std.testing.expectEqual(Action.hard_drop, first.items[3]);
    const held = c.update(.{ .rotate_cw = true, .rotate_ccw = true, .hold = true, .hard_drop = true }, 500);
    try std.testing.expectEqual(@as(usize, 0), held.len);
}

test "soft drop repeats while held" {
    var c = Controller{};
    try std.testing.expectEqual(@as(usize, 1), count(c.update(.{ .soft_drop = true }, 0), .soft_drop));
    try std.testing.expectEqual(@as(usize, 0), count(c.update(.{ .soft_drop = true }, 20), .soft_drop));
    try std.testing.expectEqual(@as(usize, 1), count(c.update(.{ .soft_drop = true }, 50), .soft_drop));
}
