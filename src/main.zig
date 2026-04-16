const std = @import("std");
const posix = std.posix; // Handles raw terminal interaction in WSL/Linux
const game_mod = @import("engine/game.zig");
const GameState = game_mod.GameState;
const Board = @import("engine/board.zig").Board;
const physics = @import("engine/physics.zig");
const piece_mod = @import("engine/piece.zig");
const Piece = piece_mod.Piece;

// --- TERMINAL MAGIC ---
// This switches the Linux/WSL terminal out of "line mode" and into "raw mode"
// so we can read keyboard inputs instantly without waiting for the Enter key.
fn enableRawMode(orig_termios: *posix.termios) !void {
    const stdin_fd = posix.STDIN_FILENO;
    orig_termios.* = try posix.tcgetattr(stdin_fd);

    var raw = orig_termios.*;
    // Disable echo (don't print keys to screen) and canonical mode (read instantly)
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;

    // Set non-blocking read: VMIN = 0 bytes required, VTIME = 0 timeout
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(stdin_fd, .FLUSH, raw);
}

fn disableRawMode(orig_termios: posix.termios) void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig_termios) catch {};
}

// --- RENDERING ---
/// Combines the static locked board with the dynamic falling piece to render a single frame.
fn render(state: *const GameState) void {
    // 1. Clear the terminal and move cursor to top-left using ANSI escape codes
    std.debug.print("\x1b[2J\x1b[H", .{});

    std.debug.print("=== AMBIGUI2 ENGINE ===\n", .{});
    std.debug.print("Score: {d} | Lines: {d}\n", .{ state.score, state.lines_cleared });
    std.debug.print("Quantum Prob: {d}%\n\n", .{@as(u32, @intFromFloat(state.current_piece.prob_a * 100))});

    // 2. Clone the static board memory so we can draw the falling piece onto it temporarily
    var render_grid = state.board.grid;

    // 3. Project the combined superposition shadow onto our temporary render grid
    const shadow_mask = state.current_piece.getSuperpositionMask();
    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const shift_amount: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
        const piece_row: u16 = (shadow_mask >> shift_amount) & 0x0F;
        if (piece_row == 0) continue;

        const board_y: i16 = @as(i16, state.current_piece.state_a.y) + @as(i16, @intCast(row));
        if (board_y < 0 or board_y >= @as(i16, @intCast(Board.HEIGHT))) continue;

        var projected_row: u16 = 0;
        const x_i16: i16 = @as(i16, state.current_piece.state_a.x);
        if (x_i16 < 0) {
            const shift_right_i16: i16 = -x_i16;
            std.debug.assert(shift_right_i16 <= 15);
            projected_row = piece_row >> @as(u4, @intCast(shift_right_i16));
        } else {
            std.debug.assert(x_i16 <= 15);
            projected_row = piece_row << @as(u4, @intCast(x_i16));
        }

        // Bitwise OR drops the falling piece onto the render grid for this frame only
        render_grid[@as(usize, @intCast(board_y))] |= projected_row;
    }

    // 4. Print the final composited grid
    for (render_grid) |raw_row| {
        const clean_row = raw_row & Board.ROW_MASK;
        std.debug.print("|", .{});
        var col: usize = 0;
        while (col < Board.WIDTH) : (col += 1) {
            const is_block = (clean_row & (@as(u16, 1) << @as(u4, @intCast(col)))) != 0;
            if (is_block) {
                std.debug.print("[]", .{});
            } else {
                std.debug.print(" .", .{});
            }
        }
        std.debug.print("|\n", .{});
    }
    std.debug.print("=======================\n", .{});
    std.debug.print("Controls: [a/A] Left | [d/D] Right | [s/S] Soft Drop | [q/Q] Quit\n", .{});
}

fn readInputByte(buf: *[1]u8) !usize {
    const result = posix.read(posix.STDIN_FILENO, buf) catch |err| switch (err) {
        error.WouldBlock => return 0,
        else => return err,
    };
    return result;
}

// --- MAIN LOOP ---
pub fn main() !void {
    // Terminal setup
    var orig_termios: posix.termios = undefined;
    try enableRawMode(&orig_termios);
    defer disableRawMode(orig_termios); // Ensure terminal resets even if game crashes

    // Initialize deterministic game state
    var state = GameState.init(42);

    var last_gravity_tick = std.time.milliTimestamp();
    const gravity_interval_ms: i64 = 500; // Piece falls every half second

    // Standard non-blocking buffer
    var buffer: [1]u8 = undefined;

    while (!state.game_over) {
        // 1. INPUT PROCESSING
        // Try to read a keystroke. If no key is pressed, it skips instantly.
        const bytes_read = try readInputByte(&buffer);
        if (bytes_read > 0) {
            const key = buffer[0];
            var dx: i8 = 0;
            var dy: i8 = 0;

            if (key == 'q' or key == 'Q') break; // Emergency exit
            if (key == 'a' or key == 'A') dx = -1;
            if (key == 'd' or key == 'D') dx = 1;
            if (key == 's' or key == 'S') dy = 1;

            if (dx != 0 or dy != 0) {
                // Apply movement vector
                state.current_piece.moveBy(dx, dy);

                // If the player's move caused a collision, undo it immediately
                if (physics.checkQuantumCollision(&state.board, &state.current_piece)) {
                    state.current_piece.moveBy(-dx, -dy);
                }
            }
        }

        // 2. GRAVITY TICKS
        const current_time = std.time.milliTimestamp();
        if (current_time - last_gravity_tick > gravity_interval_ms) {
            last_gravity_tick = current_time;

            // Apply downward vector
            state.current_piece.moveBy(0, 1);

            // If gravity pushed us into the floor/blocks, trigger the collapse
            if (physics.checkQuantumCollision(&state.board, &state.current_piece)) {
                // Undo the gravity tick to stay above the floor
                state.current_piece.moveBy(0, -1);
                state.collapseAndLock();
            }
        }

        // 3. RENDER FRAME
        render(&state);

        // Sleep for 16ms (~60 FPS) to prevent the CPU loop from maxing out at 100%
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }

    // GAME OVER SEQUENCE
    std.debug.print("\n=== GAME OVER ===\n", .{});
    if (state.top_out_reason) |reason| {
        std.debug.print("Reason: {s}\n", .{@tagName(reason)});
    }
    std.debug.print("Final Score: {d}\n", .{state.score});
}
