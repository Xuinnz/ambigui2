const std = @import("std");
const posix = std.posix; // Handles raw terminal interaction in WSL/Linux
const game_mod = @import("engine/game.zig");
const GameState = game_mod.GameState;
const expectimax = @import("ai/expectimax.zig");
const heuristics = @import("ai/heuristics.zig");
const Board = @import("engine/board.zig").Board;
const physics = @import("engine/physics.zig");
const piece_mod = @import("engine/piece.zig");
const Piece = piece_mod.Piece;
const config = @import("config");

//depth = pieces placed per line of play (max 3)
const SEED: u64 = config.seed;
const AI_DEPTH: u32 = config.ai_depth;
const AI_BEAM_WIDTH: usize = config.ai_beam_width;
const AI_STEP_INTERVAL_MS: i64 = 0;

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
fn overlayPiece(render_grid: *[Board.HEIGHT]u16, piece: *const Piece) void {
    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const piece_row = physics.pieceRow(piece, row);
        if (piece_row == 0) continue;

        const board_y: i16 = @as(i16, piece.y) + @as(i16, @intCast(row));
        if (board_y < 0 or board_y >= @as(i16, @intCast(Board.HEIGHT))) continue;

        render_grid[@as(usize, @intCast(board_y))] |= physics.projectRow(piece_row, piece.x).on_board;
    }
}

fn printMiniRow(writer: *std.Io.Writer, piece: *const Piece, row: usize) !void {
    const shift_amount: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
    const piece_row: u16 = (piece.matrix >> shift_amount) & 0x0F;

    var col: usize = 0;
    while (col < Piece.BOUND_SIZE) : (col += 1) {
        const is_block = (piece_row & (@as(u16, 1) << @as(u4, @intCast(col)))) != 0;
        if (is_block) {
            try writer.print("[]", .{});
        } else {
            try writer.print(" .", .{});
        }
    }
}

fn printEmptyMiniRow(writer: *std.Io.Writer) !void {
    var col: usize = 0;
    while (col < Piece.BOUND_SIZE) : (col += 1) {
        try writer.print(" .", .{});
    }
}

fn render(state: *const GameState) !void {
    var out_buffer: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(out_buffer[0..]);
    var writer = &out.interface;
    // 1. Clear the terminal and move cursor to top-left using ANSI escape codes
    try writer.print("\x1b[2J\x1b[H", .{});

    try writer.print("=== AMBIGUI2 ENGINE ===\n", .{});
    try writer.print("Score: {d} | Lines: {d}\n", .{ state.score, state.lines_cleared });
    try writer.print("Quantum Prob: {d}%\n\n", .{@as(u32, @intFromFloat(state.current_piece.prob_a * 100))});
    // try writer.print("State A Grounded: {s} | State B Grounded: {s}\n\n", .{
    //     if (state.current_piece.grounded_a) "yes" else "no",
    //     if (state.current_piece.grounded_b) "yes" else "no",
    // });
    // const penalty_pending = (state.current_piece.state_a.shape_type == .I and state.current_piece.wall_out_a) or
    //     (state.current_piece.state_b.shape_type == .I and state.current_piece.wall_out_b);
    // try writer.print("State A Wall Out: {s} | State B Wall Out: {s}\n", .{
    //     if (state.current_piece.wall_out_a) "yes" else "no",
    //     if (state.current_piece.wall_out_b) "yes" else "no",
    // });
    // try writer.print("Penalty Pending: {s}\n\n", .{if (penalty_pending) "yes" else "no"});

    try writer.print("Possible states:\n", .{});

    var preview_row: usize = 0;
    while (preview_row < Piece.BOUND_SIZE) : (preview_row += 1) {
        if (preview_row == 0) {
            try writer.print("A ", .{});
        } else {
            try writer.print("  ", .{});
        }
        try printMiniRow(writer, &state.current_piece.state_a, preview_row);

        try writer.print("   ", .{});

        if (preview_row == 0) {
            try writer.print("B ", .{});
        } else {
            try writer.print("  ", .{});
        }
        try printMiniRow(writer, &state.current_piece.state_b, preview_row);
        try writer.print("\n", .{});
    }

    try writer.print("\nHold:\n", .{});

    var hold_row: usize = 0;
    while (hold_row < Piece.BOUND_SIZE) : (hold_row += 1) {
        if (hold_row == 0) {
            try writer.print("A ", .{});
        } else {
            try writer.print("  ", .{});
        }

        if (state.held_piece) |held| {
            try printMiniRow(writer, &held.state_a, hold_row);
        } else {
            try printEmptyMiniRow(writer);
        }

        try writer.print("   ", .{});

        if (hold_row == 0) {
            try writer.print("B ", .{});
        } else {
            try writer.print("  ", .{});
        }

        if (state.held_piece) |held| {
            try printMiniRow(writer, &held.state_b, hold_row);
        } else {
            try printEmptyMiniRow(writer);
        }
        try writer.print("\n", .{});
    }

    try writer.print("\n", .{});

    // 2. Clone the static board memory so we can draw the falling piece onto it temporarily
    var render_grid = state.board.grid;
    var ghost_grid: [Board.HEIGHT]u16 = [_]u16{0} ** Board.HEIGHT;

    const ghost_a = state.projectGhostPiece(&state.current_piece.state_a);
    const ghost_b = state.projectGhostPiece(&state.current_piece.state_b);
    overlayPiece(&ghost_grid, &ghost_a);
    overlayPiece(&ghost_grid, &ghost_b);

    // 3. Overlay both deterministic states at their independent positions.
    overlayPiece(&render_grid, &state.current_piece.state_a);
    overlayPiece(&render_grid, &state.current_piece.state_b);

    // 4. Print the final composited grid
    var row: usize = 0;
    while (row < Board.HEIGHT) : (row += 1) {
        const live_row = render_grid[row] & Board.ROW_MASK;
        const ghost_row = ghost_grid[row] & Board.ROW_MASK;
        try writer.print("|", .{});
        var col: usize = 0;
        while (col < Board.WIDTH) : (col += 1) {
            const bit: u16 = @as(u16, 1) << @as(u4, @intCast(col));
            if ((live_row & bit) != 0) {
                try writer.print("[]", .{});
            } else if ((ghost_row & bit) != 0) {
                try writer.print("::", .{});
            } else {
                try writer.print(" .", .{});
            }
        }
        try writer.print("|\n", .{});
    }
    try writer.print("=======================\n", .{});
    try writer.print("Controls: [<-] Left | [->] Right | [^] Rotate | [z] Rotate Back | [v] Faster Drop | [Space] Hard Drop | [C] Hold | [P] Toggle AI | [N] AI Step | [q/Q] Quit\n", .{});
    try writer.flush();
}

fn runAiMove(state: *GameState, weights: *const game_mod.Weights) void {
    const move = expectimax.bestMoveWithOptions(state, weights, .{
        .depth = AI_DEPTH,
        .beam_width = AI_BEAM_WIDTH,
    });
    if (move) |chosen| {
        state.applyMove(&chosen);
    } else {
        state.game_over = true;
        state.top_out_reason = .block_out;
    }
}

fn handleGameplayKey(state: *GameState, key: u8) bool {
    if (key == 'q' or key == 'Q') return true;
    if (key == 'c' or key == 'C') {
        state.tryHold();
        return false;
    }
    if (key == 'z' or key == 'Z') {
        state.tryRotateCCW();
        return false;
    }
    if (key == 's' or key == 'S') {
        _ = state.tickGravity();
        return false;
    }
    if (key == ' ') {
        state.hardDrop();
        return false;
    }
    return false;
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

    // Initialize game state; -Dseed=0 (the default) picks a new seed each run
    var state = GameState.init(if (SEED != 0) SEED else std.crypto.random.int(u64));

    // Trained weights from data/weights.json, embedded at build time
    const weights = heuristics.trainedWeights();

    var last_gravity_tick = std.time.milliTimestamp();

    var ai_autopilot_active = false;
    var ai_step_requested = false;
    var last_ai_tick = std.time.milliTimestamp();

    // Standard non-blocking buffer
    var buffer: [1]u8 = undefined;
    var esc_state: u2 = 0;

    while (!state.game_over) {
        // 1. INPUT PROCESSING
        // Try to read a keystroke. If no key is pressed, it skips instantly.
        const bytes_read = try readInputByte(&buffer);
        if (bytes_read > 0) {
            const key = buffer[0];

            if (esc_state == 0) {
                if (key == 0x1b) {
                    esc_state = 1;
                } else {
                    if (key == 'p' or key == 'P') {
                        ai_autopilot_active = !ai_autopilot_active;
                        ai_step_requested = false;
                        last_ai_tick = std.time.milliTimestamp();
                    } else if (key == 'n' or key == 'N') {
                        ai_step_requested = true;
                    } else if (!ai_autopilot_active) {
                        if (handleGameplayKey(&state, key)) break;
                    }
                }
            } else if (esc_state == 1) {
                esc_state = if (key == '[') 2 else 0;
            } else {
                esc_state = 0;
                if (!ai_autopilot_active) {
                    if (key == 'D') {
                        state.tryMoveHorizontal(-1);
                    } else if (key == 'C') {
                        state.tryMoveHorizontal(1);
                    } else if (key == 'A') {
                        state.tryRotateCW();
                    } else if (key == 'B') {
                        // Arrow-down accelerates descent via immediate gravity tick.
                        _ = state.tickGravity();
                    }
                }
            }
        }

        // 2. AI STEP
        const current_time = std.time.milliTimestamp();
        var ai_moved = false;
        if (ai_autopilot_active or ai_step_requested) {
            const ai_ready = ai_step_requested or (current_time - last_ai_tick >= AI_STEP_INTERVAL_MS);
            if (ai_ready) {
                if (ai_autopilot_active) {
                    last_ai_tick = current_time;
                }
                ai_step_requested = false;
                runAiMove(&state, &weights);
                ai_moved = true;
            }
        }

        // 3. GRAVITY TICKS
        if (!ai_autopilot_active and !ai_moved) {
            if (current_time - last_gravity_tick > state.gravityIntervalMs()) {
                last_gravity_tick = current_time;
                _ = state.tickGravity();
            }
        }

        // 4. RENDER FRAME
        try render(&state);

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
