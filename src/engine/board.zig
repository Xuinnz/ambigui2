const std = @import("std");

pub const Board = struct {
    //dimension of the board (10 x 20)
    pub const WIDTH: usize = 10;
    pub const HEIGHT: usize = 20;

    pub const ROW_MASK: u16 = (@as(u16, 1) << WIDTH) - 1; //ROW_MASK is 0x03FF (11 1111 1111)

    grid: [HEIGHT]u16, //initialize the grid

    //initialize empty board
    pub fn init() Board {
        return Board{
            .grid = [_]u16{0} ** HEIGHT,
        };
    }

    //reset board
    pub fn clear(self: *Board) void {
        self.grid = [_]u16{0} ** HEIGHT;
    }

    // check if specific row is complete
    // evaluates in O(1) time since you only compare it with the hex
    pub inline fn isLineFull(self: *const Board, row_idx: usize) bool {
        std.debug.assert(row_idx < HEIGHT);
        return (self.grid[row_idx] & ROW_MASK) == ROW_MASK;
    }

    //clears full line and drops all row above by 1
    pub fn clearAndDrop(self: *Board, full_row_idx: usize) void {
        std.debug.assert(full_row_idx < HEIGHT);

        //shift all rows above the cleared line down by one memory
        var i: usize = full_row_idx;
        while (i > 0) : (i -= 1) {
            self.grid[i] = self.grid[i - 1];
        }
        //the very top row becomes 0
        self.grid[0] = 0;
    }

    //for multiple lines clear
    pub fn clearFullLines(self: *Board) u8 {
        var write_row: isize = HEIGHT - 1; //where the blocks should fall to
        var read_row: isize = HEIGHT - 1; //which row we evaluating
        var cleared: u8 = 0;

        //scan starting from the ceiling and go down
        while (read_row >= 0) : (read_row -= 1) {
            const r: usize = @as(usize, @intCast(read_row));
            const row = self.grid[r] & ROW_MASK;

            // if
            if (row == ROW_MASK) {
                cleared += 1;
                continue;
            }

            const w: usize = @as(usize, @intCast(write_row));
            self.grid[w] = row;
            write_row -= 1;
        }

        while (write_row >= 0) : (write_row -= 1) {
            const w: usize = @as(usize, @intCast(write_row));
            self.grid[w] = 0;
        }
        return cleared;
    }

    //helper function to visualize
    pub fn debugPrint(self: *const Board) void {
        std.debug.print("\n=== BOARD STATE ===\n", .{});
        for (self.grid) |row| {
            std.debug.print("|", .{});

            // loop through the first 10 bits to render the board
            var col: u4 = 0;
            while (col < 10) : (col += 1) {
                // bitwise AND to check if the specific bit is 1
                const is_block = (row & (@as(u16, 1) << col)) != 0;
                if (is_block) {
                    std.debug.print("[]", .{}); // Locked block
                } else {
                    std.debug.print(" .", .{}); // Empty space
                }
            }
            std.debug.print("|\n", .{});
        }
        std.debug.print("===================\n", .{});
    }
};

test "Board.init creates an empty board" {
    const board = Board.init();

    for (board.grid) |row| {
        try std.testing.expectEqual(@as(u16, 0), row);
    }
}

test "Board.clear resets all rows" {
    var board = Board.init();
    board.grid[0] = 0x0001;
    board.grid[7] = 0x0010;
    board.grid[19] = Board.ROW_MASK;

    board.clear();

    for (board.grid) |row| {
        try std.testing.expectEqual(@as(u16, 0), row);
    }
}

test "Board.isLineFull checks only the lower 10 bits" {
    var board = Board.init();

    board.grid[5] = Board.ROW_MASK;
    try std.testing.expect(board.isLineFull(5));

    board.grid[5] = Board.ROW_MASK | @as(u16, 0xFC00);
    try std.testing.expect(board.isLineFull(5));

    board.grid[5] = Board.ROW_MASK - 1;
    try std.testing.expect(!board.isLineFull(5));
}

test "Board.clearAndDrop shifts rows above downward" {
    var board = Board.init();
    board.grid[0] = 0x0001;
    board.grid[1] = 0x0002;
    board.grid[2] = 0x0004;
    board.grid[3] = Board.ROW_MASK;
    board.grid[4] = 0x0008;

    board.clearAndDrop(3);

    try std.testing.expectEqual(@as(u16, 0), board.grid[0]);
    try std.testing.expectEqual(@as(u16, 0x0001), board.grid[1]);
    try std.testing.expectEqual(@as(u16, 0x0002), board.grid[2]);
    try std.testing.expectEqual(@as(u16, 0x0004), board.grid[3]);
    try std.testing.expectEqual(@as(u16, 0x0008), board.grid[4]);
}

test "Board.clearAndDrop on top row only clears row 0" {
    var board = Board.init();
    board.grid[0] = Board.ROW_MASK;
    board.grid[1] = 0x0001;

    board.clearAndDrop(0);

    try std.testing.expectEqual(@as(u16, 0), board.grid[0]);
    try std.testing.expectEqual(@as(u16, 0x0001), board.grid[1]);
}

test "Board.clearFullLines clears one full row" {
    var board = Board.init();
    board.grid[17] = 0x0001;
    board.grid[18] = 0x0002;
    board.grid[19] = Board.ROW_MASK;

    const cleared = board.clearFullLines();

    try std.testing.expectEqual(@as(u8, 1), cleared);
    try std.testing.expectEqual(@as(u16, 0x0002), board.grid[19]);
    try std.testing.expectEqual(@as(u16, 0x0001), board.grid[18]);
    try std.testing.expectEqual(@as(u16, 0), board.grid[17]);
}

test "Board.clearFullLines clears multiple rows and preserves order" {
    var board = Board.init();
    board.grid[16] = 0x0001;
    board.grid[17] = Board.ROW_MASK;
    board.grid[18] = 0x0002;
    board.grid[19] = Board.ROW_MASK;

    const cleared = board.clearFullLines();

    try std.testing.expectEqual(@as(u8, 2), cleared);
    try std.testing.expectEqual(@as(u16, 0x0002), board.grid[19]);
    try std.testing.expectEqual(@as(u16, 0x0001), board.grid[18]);
    try std.testing.expectEqual(@as(u16, 0), board.grid[17]);
    try std.testing.expectEqual(@as(u16, 0), board.grid[0]);
}

test "Board.clearFullLines handles consecutive full rows" {
    var board = Board.init();
    board.grid[15] = 0x0001;
    board.grid[16] = 0x0002;
    board.grid[17] = 0x0004;
    board.grid[18] = Board.ROW_MASK;
    board.grid[19] = Board.ROW_MASK;

    const cleared = board.clearFullLines();

    try std.testing.expectEqual(@as(u8, 2), cleared);
    try std.testing.expectEqual(@as(u16, 0x0004), board.grid[19]);
    try std.testing.expectEqual(@as(u16, 0x0002), board.grid[18]);
    try std.testing.expectEqual(@as(u16, 0x0001), board.grid[17]);
    try std.testing.expectEqual(@as(u16, 0), board.grid[16]);
}
