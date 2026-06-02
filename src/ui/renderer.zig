const std = @import("std");
const rl = @import("raylib");
const game_mod = @import("../engine/game.zig");
const piece_mod = @import("../engine/piece.zig");
const board_mod = @import("../engine/board.zig");

const GameState = game_mod.GameState;
const Weights = game_mod.Weights;
const Board = board_mod.Board;
const Piece = piece_mod.Piece;
const ShapeType = piece_mod.ShapeType;

// ── Layout constants ───────────────────────────────────────────────────────────
pub const CELL: i32 = 28;
const BOARD_W: i32 = @as(i32, Board.WIDTH) * CELL;
const BOARD_H: i32 = @as(i32, Board.HEIGHT) * CELL;
const BOX: i32 = @as(i32, Piece.BOUND_SIZE) * CELL;
const GAP: i32 = 8;
const MARGIN: i32 = 14;
pub const BOARD_Y: i32 = 44;
const STATS_W: i32 = 130;

// Left side (Player)
const L_LEFT_X: i32 = MARGIN;
const L_BOARD_X: i32 = L_LEFT_X + BOX + GAP;
const L_RIGHT_X: i32 = L_BOARD_X + BOARD_W + GAP;

// Divider
const DIVIDER_X: i32 = L_RIGHT_X + STATS_W + MARGIN;

// Right side (AI)
const R_LEFT_X: i32 = DIVIDER_X + MARGIN;
const R_BOARD_X: i32 = R_LEFT_X + BOX + GAP;
const R_RIGHT_X: i32 = R_BOARD_X + BOARD_W + GAP;

pub const WIN_W: i32 = R_RIGHT_X + STATS_W + MARGIN;
pub const WIN_H: i32 = BOARD_Y + BOARD_H + 36;

// Y positions for left-side panel items (same for both sides)
const HOLD_Y: i32 = BOARD_Y;
const PROB_A_Y: i32 = HOLD_Y + BOX + GAP;
const PROB_B_Y: i32 = PROB_A_Y + BOX + GAP;

// Y positions for right-side panel items
const NEXT_Y: i32 = BOARD_Y;
const STATS_Y: i32 = NEXT_Y + BOX + GAP;

// ── Colours ────────────────────────────────────────────────────────────────────
const COL_BG = rl.Color{ .r = 18, .g = 18, .b = 18, .a = 255 };
const COL_EMPTY = rl.Color{ .r = 30, .g = 30, .b = 30, .a = 255 };
const COL_LOCKED = rl.Color{ .r = 160, .g = 160, .b = 160, .a = 255 };
const COL_BORDER = rl.Color{ .r = 60, .g = 60, .b = 60, .a = 255 };
const COL_LABEL = rl.Color{ .r = 110, .g = 110, .b = 110, .a = 255 };
const COL_WHITE = rl.Color{ .r = 240, .g = 240, .b = 240, .a = 255 };
const COL_RED = rl.Color{ .r = 220, .g = 50, .b = 50, .a = 255 };
const COL_GREEN = rl.Color{ .r = 60, .g = 220, .b = 80, .a = 255 };
const COL_GOLD = rl.Color{ .r = 255, .g = 210, .b = 0, .a = 255 };
const COL_DIVIDER = rl.Color{ .r = 45, .g = 45, .b = 45, .a = 255 };
const COL_BLACK = rl.Color.black;

// ── Public types ───────────────────────────────────────────────────────────────
pub const GameMode = enum { Solo, VsAI };
pub const Difficulty = enum { Easy, Medium, Hard };

pub const AiGameConfig = struct {
    weights: Weights,
    depth: u32,
    beam_width: usize,
    step_ms: i64,
};

// ── Asset paths ────────────────────────────────────────────────────────────────
// FIX: game_board.png removed — board is drawn programmatically (no more misalignment)
const LANDING_ASSET: [:0]const u8 = "assets/landing_page/resized_main_page.png";
const DIFFICULTY_ASSET: [:0]const u8 = "assets/landing_page/difficulty_page.png";
const BLOCK_BOX_ASSET: [:0]const u8 = "assets/vs_ai/block.png";
const VS_AI_FRAMES_DIR: []const u8 = "assets/vs_ai/frames";
const BG_FRAME_DURATION: f32 = 1.0 / 24.0;

// ── Asset globals ──────────────────────────────────────────────────────────────
var landing_tex: ?rl.Texture2D = null;
var difficulty_tex: ?rl.Texture2D = null;
// FIX: game_board_tex removed
var block_box_tex: ?rl.Texture2D = null;

var bg_textures: []rl.Texture2D = &.{};
var bg_current_frame: u32 = 0;
var bg_frame_timer: f32 = 0.0;

const bg_gpa = std.heap.page_allocator;

// Landing page hit zones (normalized 0..1)
const VSAI_HIT = [4]f32{ 0.40, 0.685, 0.20, 0.08 };
const SOLO_HIT = [4]f32{ 0.40, 0.575, 0.20, 0.08 };

// Difficulty hit zones
const EASY_HIT = [4]f32{ 0.40, 0.54, 0.20, 0.08 };
const MED_HIT = [4]f32{ 0.40, 0.64, 0.20, 0.08 };
const HARD_HIT = [4]f32{ 0.40, 0.74, 0.20, 0.08 };

// ── Frame file helper ──────────────────────────────────────────────────────────
const FrameFile = struct { num: u32, name: []const u8 };

fn isFrameAsset(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "frame_")) return false;
    if (std.mem.indexOf(u8, name, ":Zone.Identifier") != null) return false;
    return std.mem.endsWith(u8, name, ".png") or std.mem.endsWith(u8, name, ".gif");
}

fn parseFrameNumber(name: []const u8) ?u32 {
    const prefix = "frame_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    var i: usize = prefix.len;
    if (i >= name.len or name[i] < '0' or name[i] > '9') return null;
    var num: u32 = 0;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        if (c < '0' or c > '9') break;
        num = num * 10 + @as(u32, c - '0');
    }
    return if (i > prefix.len) num else null;
}

fn loadBgFrames() void {
    var dir = std.fs.cwd().openDir(VS_AI_FRAMES_DIR, .{ .iterate = true }) catch return;
    defer dir.close();

    var frame_files: std.ArrayList(FrameFile) = .empty;
    defer {
        for (frame_files.items) |e| bg_gpa.free(e.name);
        frame_files.deinit(bg_gpa);
    }

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!isFrameAsset(entry.name)) continue;
        const num = parseFrameNumber(entry.name) orelse continue;
        const owned = bg_gpa.dupe(u8, entry.name) catch continue;
        frame_files.append(bg_gpa, .{ .num = num, .name = owned }) catch {
            bg_gpa.free(owned);
            continue;
        };
    }

    if (frame_files.items.len == 0) return;

    std.mem.sort(FrameFile, frame_files.items, {}, struct {
        fn less(_: void, a: FrameFile, b: FrameFile) bool {
            return a.num < b.num;
        }
    }.less);

    var tex_list: std.ArrayList(rl.Texture2D) = .empty;
    for (frame_files.items) |entry| {
        const path = std.fmt.allocPrint(bg_gpa, "{s}/{s}", .{ VS_AI_FRAMES_DIR, entry.name }) catch break;
        defer bg_gpa.free(path);
        const path_z = bg_gpa.allocSentinel(u8, path.len, 0) catch break;
        defer bg_gpa.free(path_z);
        @memcpy(path_z, path);
        const tex = rl.loadTexture(path_z) catch break;
        rl.setTextureFilter(tex, .bilinear);
        tex_list.append(bg_gpa, tex) catch {
            rl.unloadTexture(tex);
            break;
        };
    }

    bg_textures = tex_list.toOwnedSlice(bg_gpa) catch return;
}

fn loadTex(path: [:0]const u8) ?rl.Texture2D {
    const t = rl.loadTexture(path) catch return null;
    rl.setTextureFilter(t, .bilinear);
    return t;
}

// ── Public: eager asset loading ────────────────────────────────────────────────
/// Call once after initWindow(), before the game loop.
pub fn preloadAssets() void {
    rl.beginDrawing();
    rl.clearBackground(COL_BG);
    const msg = "Loading...";
    const sz: i32 = 24;
    const mw = rl.measureText(msg, sz);
    rl.drawText(msg, @divTrunc(WIN_W - mw, 2), @divTrunc(WIN_H - sz, 2), sz, COL_LABEL);
    rl.endDrawing();

    landing_tex = loadTex(LANDING_ASSET);
    difficulty_tex = loadTex(DIFFICULTY_ASSET);
    // FIX: game_board_tex no longer loaded — board drawn programmatically
    block_box_tex = loadTex(BLOCK_BOX_ASSET);
    loadBgFrames();
}

// ── Helpers ────────────────────────────────────────────────────────────────────
fn scaledRect(norm: [4]f32) rl.Rectangle {
    return .{
        .x = @as(f32, @floatFromInt(WIN_W)) * norm[0],
        .y = @as(f32, @floatFromInt(WIN_H)) * norm[1],
        .width = @as(f32, @floatFromInt(WIN_W)) * norm[2],
        .height = @as(f32, @floatFromInt(WIN_H)) * norm[3],
    };
}

fn drawFullscreenTex(tex: rl.Texture2D) void {
    const src = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(tex.height) };
    const dest = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(WIN_W), .height = @floatFromInt(WIN_H) };
    rl.drawTexturePro(tex, src, dest, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
}

fn shapeColor(shape: ShapeType) rl.Color {
    return switch (shape) {
        .I => .{ .r = 0, .g = 220, .b = 220, .a = 255 },
        .O => .{ .r = 220, .g = 220, .b = 0, .a = 255 },
        .T => .{ .r = 160, .g = 0, .b = 220, .a = 255 },
        .S => .{ .r = 0, .g = 200, .b = 0, .a = 255 },
        .Z => .{ .r = 220, .g = 0, .b = 0, .a = 255 },
        .J => .{ .r = 0, .g = 80, .b = 220, .a = 255 },
        .L => .{ .r = 220, .g = 140, .b = 0, .a = 255 },
    };
}

fn withAlpha(c: rl.Color, a: u8) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

fn drawShadowText(text: [:0]const u8, x: i32, y: i32, sz: i32, col: rl.Color) void {
    rl.drawText(text, x + 1, y + 1, sz, COL_BLACK);
    rl.drawText(text, x, y, sz, col);
}

// ── Cell primitives ────────────────────────────────────────────────────────────
fn cellAt(board_x: i32, bx: i32, by: i32, color: rl.Color) void {
    const px = board_x + bx * CELL;
    const py = BOARD_Y + by * CELL;
    rl.drawRectangle(px + 1, py + 1, CELL - 2, CELL - 2, color);
}

fn cellOutlineAt(board_x: i32, bx: i32, by: i32, color: rl.Color) void {
    const px = board_x + bx * CELL;
    const py = BOARD_Y + by * CELL;
    rl.drawRectangleLines(px + 1, py + 1, CELL - 2, CELL - 2, color);
}

fn miniCellAt(ox: i32, oy: i32, col: usize, row: usize, color: rl.Color) void {
    const px = ox + @as(i32, @intCast(col)) * CELL;
    const py = oy + @as(i32, @intCast(row)) * CELL;
    rl.drawRectangle(px + 1, py + 1, CELL - 2, CELL - 2, color);
}

// ── Piece drawing ──────────────────────────────────────────────────────────────
fn drawPieceOnBoard(board_x: i32, piece: *const Piece, color: rl.Color) void {
    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const shift: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
        const piece_row: u16 = (piece.matrix >> shift) & 0x0F;
        if (piece_row == 0) continue;
        const by: i32 = piece.y + @as(i32, @intCast(row));
        if (by < 0 or by >= @as(i32, Board.HEIGHT)) continue;
        var col: usize = 0;
        while (col < Piece.BOUND_SIZE) : (col += 1) {
            const is_block = (piece_row & (@as(u16, 1) << @as(u4, @intCast(col)))) != 0;
            if (!is_block) continue;
            const bx: i32 = piece.x + @as(i32, @intCast(col));
            if (bx < 0 or bx >= @as(i32, Board.WIDTH)) continue;
            cellAt(board_x, bx, by, color);
        }
    }
}

fn drawPieceOutlineOnBoard(board_x: i32, piece: *const Piece, color: rl.Color) void {
    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const shift: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
        const piece_row: u16 = (piece.matrix >> shift) & 0x0F;
        if (piece_row == 0) continue;
        const by: i32 = piece.y + @as(i32, @intCast(row));
        if (by < 0 or by >= @as(i32, Board.HEIGHT)) continue;
        var col: usize = 0;
        while (col < Piece.BOUND_SIZE) : (col += 1) {
            const is_block = (piece_row & (@as(u16, 1) << @as(u4, @intCast(col)))) != 0;
            if (!is_block) continue;
            const bx: i32 = piece.x + @as(i32, @intCast(col));
            if (bx < 0 or bx >= @as(i32, Board.WIDTH)) continue;
            cellOutlineAt(board_x, bx, by, color);
        }
    }
}

fn drawPieceMini(piece: *const Piece, ox: i32, oy: i32, color: rl.Color) void {
    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const shift: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
        const piece_row: u16 = (piece.matrix >> shift) & 0x0F;
        if (piece_row == 0) continue;
        var col: usize = 0;
        while (col < Piece.BOUND_SIZE) : (col += 1) {
            const is_block = (piece_row & (@as(u16, 1) << @as(u4, @intCast(col)))) != 0;
            if (is_block) miniCellAt(ox, oy, col, row, color);
        }
    }
}

// ── Board drawing ──────────────────────────────────────────────────────────────
// FIX: drawBoardBg now only draws the border outline.
// The texture was removed because stretching game_board.png to BOARD_W×BOARD_H
// caused a size mismatch with the actual cell grid drawn on top of it.
fn drawBoardBg(board_x: i32) void {
    rl.drawRectangle(board_x, BOARD_Y, BOARD_W, BOARD_H, COL_BLACK);
    rl.drawRectangleLines(board_x - 1, BOARD_Y - 1, BOARD_W + 2, BOARD_H + 2, COL_BORDER);
}

// FIX: renamed from drawLockedCells and now draws ALL cells — both empty and
// locked — so the board grid is always visible without any texture background.
fn drawBoardCells(layout: BoardLayout, state: *const GameState) void {
    var row: usize = 0;
    while (row < Board.HEIGHT) : (row += 1) {
        var col: usize = 0;
        while (col < Board.WIDTH) : (col += 1) {
            const bit: u16 = @as(u16, 1) << @as(u4, @intCast(col));
            const locked = (state.board.grid[row] & bit) != 0;
            cellAt(layout.board_x, @intCast(col), @intCast(row), if (locked) COL_LOCKED else COL_EMPTY);
        }
    }
}

fn drawBoxBg(x: i32, y: i32, w: i32, h: i32) void {
    if (block_box_tex) |tex| {
        const src = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(tex.height) };
        const dest = rl.Rectangle{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) };
        rl.drawTexturePro(tex, src, dest, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
    } else {
        rl.drawRectangle(x, y, w, h, COL_EMPTY);
        rl.drawRectangleLines(x - 1, y - 1, w + 2, h + 2, COL_BORDER);
    }
}

// ── Background animation ───────────────────────────────────────────────────────
fn updateBgFrame() void {
    if (bg_textures.len == 0) return;
    bg_frame_timer += rl.getFrameTime();
    const count: u32 = @intCast(bg_textures.len);
    while (bg_frame_timer >= BG_FRAME_DURATION) {
        bg_frame_timer -= BG_FRAME_DURATION;
        bg_current_frame = (bg_current_frame + 1) % count;
    }
}

fn drawBgFrame() void {
    rl.clearBackground(COL_BLACK);
    if (bg_textures.len == 0) return;
    const idx = @as(usize, @intCast(bg_current_frame));
    drawFullscreenTex(bg_textures[idx]);
}

// ── Board layout descriptor ────────────────────────────────────────────────────
const BoardLayout = struct {
    left_x: i32,
    board_x: i32,
    right_x: i32,
    label: [:0]const u8,
};

const PLAYER_LAYOUT = BoardLayout{
    .left_x = L_LEFT_X,
    .board_x = L_BOARD_X,
    .right_x = L_RIGHT_X,
    .label = "PLAYER",
};

const AI_LAYOUT = BoardLayout{
    .left_x = R_LEFT_X,
    .board_x = R_BOARD_X,
    .right_x = R_RIGHT_X,
    .label = "AI",
};

// ── Per-board drawing ──────────────────────────────────────────────────────────
fn drawGhostPieces(layout: BoardLayout, state: *const GameState) void {
    const ghost_a = state.projectGhostPiece(&state.current_piece.state_a);
    const ghost_b = state.projectGhostPiece(&state.current_piece.state_b);
    // A ghost: crisp outline, matches the solid A piece above it
    drawPieceOnBoardOutline(layout.board_x, &ghost_a, withAlpha(shapeColor(ghost_a.shape_type), 180));
    // B ghost: barely-there fill, matches the faint B piece above it
    drawPieceOnBoard(layout.board_x, &ghost_b, withAlpha(shapeColor(ghost_b.shape_type), 25));
}

fn cellAtOutline(board_x: i32, bx: i32, by: i32, color: rl.Color) void {
    const px = board_x + bx * CELL;
    const py = BOARD_Y + by * CELL;
    rl.drawRectangleLines(px + 1, py + 1, CELL - 2, CELL - 2, color);
}

// Add this alongside drawPieceOnBoard
fn drawPieceOnBoardOutline(board_x: i32, piece: *const Piece, color: rl.Color) void {
    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const shift: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
        const piece_row: u16 = (piece.matrix >> shift) & 0x0F;
        if (piece_row == 0) continue;
        const by: i32 = piece.y + @as(i32, @intCast(row));
        if (by < 0 or by >= @as(i32, Board.HEIGHT)) continue;
        var col: usize = 0;
        while (col < Piece.BOUND_SIZE) : (col += 1) {
            const is_block = (piece_row & (@as(u16, 1) << @as(u4, @intCast(col)))) != 0;
            if (!is_block) continue;
            const bx: i32 = piece.x + @as(i32, @intCast(col));
            if (bx < 0 or bx >= @as(i32, Board.WIDTH)) continue;
            cellAtOutline(board_x, bx, by, color);
        }
    }
}

fn drawActivePieces(layout: BoardLayout, state: *const GameState) void {
    const qp = &state.current_piece;
    if (!qp.locked_a)
        drawPieceOnBoard(layout.board_x, &qp.state_a, shapeColor(qp.state_a.shape_type));
    if (!qp.locked_b)
        drawPieceOnBoard(layout.board_x, &qp.state_b, withAlpha(shapeColor(qp.state_b.shape_type), 130));
}

fn drawHold(layout: BoardLayout, state: *const GameState) void {
    drawBoxBg(layout.left_x, HOLD_Y, BOX, BOX);
    if (state.held_piece) |held| {
        drawPieceMini(&held.state_a, layout.left_x, HOLD_Y, shapeColor(held.state_a.shape_type));
        drawPieceMini(&held.state_b, layout.left_x, HOLD_Y, withAlpha(shapeColor(held.state_b.shape_type), 130));
    }
}

// FIX: prob boxes now show the piece shape inside block.png, with the
// probability label ("A 70%") in a small dark strip at the top of the box.
// Previously the box showed only the text label and the piece was never drawn.
fn drawProbBoxes(layout: BoardLayout, state: *const GameState) void {
    var buf: [16]u8 = undefined;
    const pct: u32 = @intFromFloat(state.current_piece.prob_a * 100.0);
    const label_h: i32 = 16; // height of the dark strip that holds the text

    // ── State A box ──────────────────────────────────────────────────────────
    drawBoxBg(layout.left_x, PROB_A_Y, BOX, BOX);
    // Draw the piece filling the whole box
    drawPieceMini(
        &state.current_piece.state_a,
        layout.left_x,
        PROB_A_Y,
        shapeColor(state.current_piece.state_a.shape_type),
    );
    // Dark strip at the top so the label stays readable over the piece
    rl.drawRectangle(layout.left_x, PROB_A_Y, BOX, label_h, withAlpha(COL_BLACK, 170));
    const ta = std.fmt.bufPrintZ(&buf, "A {d}%", .{pct}) catch return;
    const wa = rl.measureText(ta, 12);
    rl.drawText(
        ta,
        layout.left_x + @divTrunc(BOX - wa, 2),
        PROB_A_Y + 2,
        12,
        shapeColor(state.current_piece.state_a.shape_type),
    );

    // ── State B box ──────────────────────────────────────────────────────────
    drawBoxBg(layout.left_x, PROB_B_Y, BOX, BOX);
    // B is drawn at reduced alpha to match its role as the secondary state
    drawPieceMini(
        &state.current_piece.state_b,
        layout.left_x,
        PROB_B_Y,
        withAlpha(shapeColor(state.current_piece.state_b.shape_type), 160),
    );
    rl.drawRectangle(layout.left_x, PROB_B_Y, BOX, label_h, withAlpha(COL_BLACK, 170));
    const tb = std.fmt.bufPrintZ(&buf, "B {d}%", .{100 - pct}) catch return;
    const wb = rl.measureText(tb, 12);
    rl.drawText(
        tb,
        layout.left_x + @divTrunc(BOX - wb, 2),
        PROB_B_Y + 2,
        12,
        shapeColor(state.current_piece.state_b.shape_type),
    );
}

fn drawNext(layout: BoardLayout, state: *const GameState) void {
    drawBoxBg(layout.right_x, NEXT_Y, BOX, BOX);
    drawPieceMini(&state.next_piece.state_a, layout.right_x, NEXT_Y, shapeColor(state.next_piece.state_a.shape_type));
    drawPieceMini(&state.next_piece.state_b, layout.right_x, NEXT_Y, withAlpha(shapeColor(state.next_piece.state_b.shape_type), 130));
}

fn drawStats(layout: BoardLayout, state: *const GameState) void {
    var buf: [48]u8 = undefined;
    const x = layout.right_x;
    const lh: i32 = 20;
    var y: i32 = STATS_Y;

    const header = std.fmt.bufPrintZ(&buf, "{s}", .{layout.label}) catch return;
    drawShadowText(header, x, y, 15, COL_WHITE);
    y += lh + 4;

    const score = std.fmt.bufPrintZ(&buf, "SCORE: {d}", .{state.score}) catch return;
    drawShadowText(score, x, y, 12, COL_WHITE);
    y += lh;

    const lines = std.fmt.bufPrintZ(&buf, "LINES: {d}", .{state.lines_cleared}) catch return;
    drawShadowText(lines, x, y, 12, COL_WHITE);
    y += lh;

    const level = std.fmt.bufPrintZ(&buf, "LEVEL: {d}", .{state.level}) catch return;
    drawShadowText(level, x, y, 12, COL_WHITE);
}

fn drawGameOverOverlay(layout: BoardLayout, subtitle: [:0]const u8) void {
    rl.drawRectangle(layout.board_x, BOARD_Y, BOARD_W, BOARD_H, withAlpha(COL_BLACK, 180));
    const msg = "GAME OVER";
    const sz: i32 = 26;
    const mid_y = BOARD_Y + @divTrunc(BOARD_H, 2);
    const mw = rl.measureText(msg, sz);
    rl.drawText(msg, layout.board_x + @divTrunc(BOARD_W - mw, 2), mid_y - sz, sz, COL_RED);
    const sw = rl.measureText(subtitle, 13);
    rl.drawText(subtitle, layout.board_x + @divTrunc(BOARD_W - sw, 2), mid_y + 8, 13, COL_LABEL);
}

fn drawOneSide(layout: BoardLayout, state: *const GameState, game_over_msg: [:0]const u8) void {
    // FIX: was drawLockedCells — now draws ALL cells so the grid is always visible
    drawBoardCells(layout, state);
    if (!state.game_over) {
        drawGhostPieces(layout, state);
        drawActivePieces(layout, state);
    }
    drawHold(layout, state);
    drawProbBoxes(layout, state);
    drawNext(layout, state);
    drawStats(layout, state);
    if (state.game_over) drawGameOverOverlay(layout, game_over_msg);
}

// ── Winner screen overlay ──────────────────────────────────────────────────────
fn drawWinnerScreen(player: *const GameState, ai: *const GameState) void {
    rl.drawRectangle(0, 0, WIN_W, WIN_H, withAlpha(COL_BLACK, 160));

    const mid_x = @divTrunc(WIN_W, 2);
    const mid_y = @divTrunc(WIN_H, 2);

    const winner_msg: [:0]const u8 = if (player.score > ai.score)
        "PLAYER WINS!"
    else if (ai.score > player.score)
        "AI WINS!"
    else
        "IT'S A TIE!";

    const winner_col: rl.Color = if (player.score > ai.score)
        COL_GREEN
    else if (ai.score > player.score)
        COL_RED
    else
        COL_GOLD;

    const wm_sz: i32 = 42;
    const wm_w = rl.measureText(winner_msg, wm_sz);
    rl.drawText(winner_msg, mid_x - @divTrunc(wm_w, 2), mid_y - 80, wm_sz, winner_col);

    var buf: [64]u8 = undefined;

    const ps = std.fmt.bufPrintZ(&buf, "Player: {d}", .{player.score}) catch return;
    const pw = rl.measureText(ps, 22);
    rl.drawText(ps, mid_x - @divTrunc(pw, 2), mid_y - 20, 22, COL_WHITE);

    const as_ = std.fmt.bufPrintZ(&buf, "AI:     {d}", .{ai.score}) catch return;
    const aw = rl.measureText(as_, 22);
    rl.drawText(as_, mid_x - @divTrunc(aw, 2), mid_y + 10, 22, COL_WHITE);

    // R now returns to the main menu
    const hint = "Press R for main menu";
    const hw = rl.measureText(hint, 14);
    rl.drawText(hint, mid_x - @divTrunc(hw, 2), mid_y + 56, 14, COL_LABEL);
}

// ── Public screen drawing functions ───────────────────────────────────────────

/// Returns the selected GameMode when player clicks, null otherwise.
pub fn drawLandingFrame() ?GameMode {
    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(COL_BG);

    if (landing_tex) |tex| drawFullscreenTex(tex);

    const mouse = rl.getMousePosition();
    const clicked = rl.isMouseButtonPressed(.left);

    if (clicked and rl.checkCollisionPointRec(mouse, scaledRect(VSAI_HIT))) return .VsAI;
    if (clicked and rl.checkCollisionPointRec(mouse, scaledRect(SOLO_HIT))) return .Solo;
    return null;
}

/// Returns the selected Difficulty when player clicks, null otherwise.
pub fn drawDifficultyFrame() ?Difficulty {
    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(COL_BG);

    if (difficulty_tex) |tex| drawFullscreenTex(tex);

    const mouse = rl.getMousePosition();
    const clicked = rl.isMouseButtonPressed(.left);

    if (clicked and rl.checkCollisionPointRec(mouse, scaledRect(EASY_HIT))) return .Easy;
    if (clicked and rl.checkCollisionPointRec(mouse, scaledRect(MED_HIT))) return .Medium;
    if (clicked and rl.checkCollisionPointRec(mouse, scaledRect(HARD_HIT))) return .Hard;
    return null;
}

/// Draw VsAI game frame. Pass show_winner=true once both are game_over.
pub fn drawVsAiFrame(
    player: *const GameState,
    ai: *const GameState,
    show_winner: bool,
) void {
    rl.beginDrawing();
    defer rl.endDrawing();

    updateBgFrame();
    drawBgFrame();

    // drawBoardBg now only draws the border — cells are drawn inside drawOneSide
    drawBoardBg(L_BOARD_X);
    drawBoardBg(R_BOARD_X);

    rl.drawRectangle(DIVIDER_X, 0, 1, WIN_H, COL_DIVIDER);

    // FIX: subtitle changed — R now returns to main menu, not restart
    drawOneSide(PLAYER_LAYOUT, player, "Press R for menu");
    drawOneSide(AI_LAYOUT, ai, "Waiting...");

    if (show_winner) drawWinnerScreen(player, ai);
}

/// Draw Solo game frame (player board centered).
pub fn drawSoloFrame(player: *const GameState) void {
    const cx = @divTrunc(WIN_W - BOARD_W, 2);
    const lx = cx - BOX - GAP;
    const rx = cx + BOARD_W + GAP;
    const solo = BoardLayout{
        .left_x = lx,
        .board_x = cx,
        .right_x = rx,
        .label = "PLAYER",
    };

    rl.beginDrawing();
    defer rl.endDrawing();

    updateBgFrame();
    drawBgFrame();
    drawBoardBg(cx);
    // FIX: subtitle changed — R now returns to main menu
    drawOneSide(solo, player, "Press R for menu");
}
