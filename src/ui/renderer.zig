//Drawing for both the desktop and the browser build.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("rl.zig").c;
const game_mod = @import("../engine/game.zig");
const piece_mod = @import("../engine/piece.zig");
const board_mod = @import("../engine/board.zig");
const agent = @import("../ai/agent.zig");

const GameState = game_mod.GameState;
const Board = board_mod.Board;
const Piece = piece_mod.Piece;
const ShapeType = piece_mod.ShapeType;

pub const is_web = builtin.cpu.arch == .wasm32;

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
const COL_BLACK = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
const COL_TINT = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

// ── Public types ───────────────────────────────────────────────────────────────
pub const GameMode = enum { Solo, VsAI };
pub const Difficulty = agent.Difficulty;

// ── Asset paths ────────────────────────────────────────────────────────────────
// The web build bundles a smaller copy of the assets (see build.zig, `web` step).
const LANDING_ASSET: [:0]const u8 = if (is_web) "web-assets/resized_main_page.png" else "assets/landing_page/resized_main_page.png";
const DIFFICULTY_ASSET: [:0]const u8 = if (is_web) "web-assets/difficulty_page.png" else "assets/landing_page/difficulty_page.png";
const BLOCK_BOX_ASSET: [:0]const u8 = if (is_web) "web-assets/block.png" else "assets/vs_ai/block.png";
const VS_AI_FRAMES_DIR: []const u8 = "assets/vs_ai/frames";
const BG_FRAME_DURATION: f32 = 1.0 / 24.0;

const CONTROLS_HINT: [:0]const u8 = "<- -> move   v soft drop   SPACE hard drop   UP/X rotate   Z rotate back   C hold";

// ── Asset globals ──────────────────────────────────────────────────────────────
var landing_tex: ?rl.Texture2D = null;
var difficulty_tex: ?rl.Texture2D = null;
var block_box_tex: ?rl.Texture2D = null;

// Animated background (desktop only: the frames are too large to ship to the browser)
var bg_textures: []rl.Texture2D = &.{};
var bg_current_frame: u32 = 0;
var bg_frame_timer: f32 = 0.0;

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
    return std.mem.endsWith(u8, name, ".png") or std.mem.endsWith(u8, name, ".gif");
}

fn parseFrameNumber(name: []const u8) ?u32 {
    const prefix = "frame_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    var i: usize = prefix.len;
    if (i >= name.len or name[i] < '0' or name[i] > '9') return null;
    var num: u32 = 0;
    while (i < name.len) : (i += 1) {
        const ch = name[i];
        if (ch < '0' or ch > '9') break;
        num = num * 10 + @as(u32, ch - '0');
    }
    return if (i > prefix.len) num else null;
}

fn loadBgFrames() void {
    if (is_web) return;
    const gpa = std.heap.page_allocator;

    var dir = std.fs.cwd().openDir(VS_AI_FRAMES_DIR, .{ .iterate = true }) catch return;
    defer dir.close();

    var frame_files: std.ArrayList(FrameFile) = .empty;
    defer {
        for (frame_files.items) |e| gpa.free(e.name);
        frame_files.deinit(gpa);
    }

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!isFrameAsset(entry.name)) continue;
        const num = parseFrameNumber(entry.name) orelse continue;
        const owned = gpa.dupe(u8, entry.name) catch continue;
        frame_files.append(gpa, .{ .num = num, .name = owned }) catch {
            gpa.free(owned);
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
        const path = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ VS_AI_FRAMES_DIR, entry.name }, 0) catch break;
        defer gpa.free(path);
        const tex = loadTex(path) orelse break;
        tex_list.append(gpa, tex) catch {
            rl.UnloadTexture(tex);
            break;
        };
    }

    bg_textures = tex_list.toOwnedSlice(gpa) catch return;
}

fn loadTex(path: [:0]const u8) ?rl.Texture2D {
    const t = rl.LoadTexture(path.ptr);
    if (t.id == 0) return null;
    rl.SetTextureFilter(t, rl.TEXTURE_FILTER_BILINEAR);
    return t;
}

// ── Public: eager asset loading ────────────────────────────────────────────────
/// Call once after InitWindow(), before the game loop.
pub fn preloadAssets() void {
    rl.BeginDrawing();
    rl.ClearBackground(COL_BG);
    const msg = "Loading...";
    const sz: i32 = 24;
    const mw = rl.MeasureText(msg, sz);
    rl.DrawText(msg, @divTrunc(WIN_W - mw, 2), @divTrunc(WIN_H - sz, 2), sz, COL_LABEL);
    rl.EndDrawing();

    landing_tex = loadTex(LANDING_ASSET);
    difficulty_tex = loadTex(DIFFICULTY_ASSET);
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

fn drawTexIn(tex: rl.Texture2D, x: i32, y: i32, w: i32, h: i32) void {
    const src = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(tex.height) };
    const dest = rl.Rectangle{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) };
    rl.DrawTexturePro(tex, src, dest, rl.Vector2{ .x = 0, .y = 0 }, 0, COL_TINT);
}

fn drawFullscreenTex(tex: rl.Texture2D) void {
    drawTexIn(tex, 0, 0, WIN_W, WIN_H);
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

fn withAlpha(col: rl.Color, a: u8) rl.Color {
    return .{ .r = col.r, .g = col.g, .b = col.b, .a = a };
}

/// Opacity for a superposition state: the likelier state is drawn more solid,
/// but even a 10% state stays clearly visible.
fn probabilityAlpha(prob: f32, min: f32, max: f32) u8 {
    return @intFromFloat(min + (max - min) * std.math.clamp(prob, 0.0, 1.0));
}

fn drawShadowText(text: [:0]const u8, x: i32, y: i32, sz: i32, col: rl.Color) void {
    rl.DrawText(text.ptr, x + 1, y + 1, sz, COL_BLACK);
    rl.DrawText(text.ptr, x, y, sz, col);
}

fn drawCenteredText(text: [:0]const u8, center_x: i32, y: i32, sz: i32, col: rl.Color) void {
    const w = rl.MeasureText(text.ptr, sz);
    rl.DrawText(text.ptr, center_x - @divTrunc(w, 2), y, sz, col);
}

// ── Piece drawing ──────────────────────────────────────────────────────────────
const CellStyle = enum { fill, outline };

fn cellAt(board_x: i32, bx: i32, by: i32, color: rl.Color, style: CellStyle) void {
    const px = board_x + bx * CELL;
    const py = BOARD_Y + by * CELL;
    switch (style) {
        .fill => rl.DrawRectangle(px + 1, py + 1, CELL - 2, CELL - 2, color),
        .outline => {
            rl.DrawRectangleLines(px + 1, py + 1, CELL - 2, CELL - 2, color);
            rl.DrawRectangleLines(px + 2, py + 2, CELL - 4, CELL - 4, color);
        },
    }
}

/// Calls `visit(bx, by)` for every block of the piece that is on the board.
fn forEachBoardCell(piece: *const Piece, ctx: anytype, comptime visit: fn (@TypeOf(ctx), i32, i32) void) void {
    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const shift: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
        const piece_row: u16 = (piece.matrix >> shift) & 0x0F;
        if (piece_row == 0) continue;
        const by: i32 = piece.y + @as(i32, @intCast(row));
        if (by < 0 or by >= @as(i32, Board.HEIGHT)) continue;
        var col: usize = 0;
        while (col < Piece.BOUND_SIZE) : (col += 1) {
            if ((piece_row & (@as(u16, 1) << @as(u4, @intCast(col)))) == 0) continue;
            const bx: i32 = piece.x + @as(i32, @intCast(col));
            if (bx < 0 or bx >= @as(i32, Board.WIDTH)) continue;
            visit(ctx, bx, by);
        }
    }
}

const PieceDraw = struct { board_x: i32, color: rl.Color, style: CellStyle };

fn drawPieceOnBoard(board_x: i32, piece: *const Piece, color: rl.Color, style: CellStyle) void {
    forEachBoardCell(piece, PieceDraw{ .board_x = board_x, .color = color, .style = style }, struct {
        fn visit(d: PieceDraw, bx: i32, by: i32) void {
            cellAt(d.board_x, bx, by, d.color, d.style);
        }
    }.visit);
}

/// Top-left on-board cell of a piece, used to anchor its probability label.
fn labelAnchor(piece: *const Piece) ?[2]i32 {
    const Anchor = struct { best: ?[2]i32 = null };
    var anchor = Anchor{};
    forEachBoardCell(piece, &anchor, struct {
        fn visit(a: *Anchor, bx: i32, by: i32) void {
            if (a.best) |b| {
                if (by > b[1] or (by == b[1] and bx >= b[0])) return;
            }
            a.best = .{ bx, by };
        }
    }.visit);
    return anchor.best;
}

/// Draws a piece centered in the w x h area at (box_x, box_y) using square cells of `cell` pixels.
fn drawPieceIn(piece: *const Piece, box_x: i32, box_y: i32, w: i32, h: i32, cell: i32, color: rl.Color) void {
    // Bounding box of the piece's blocks inside its 4x4 matrix.
    var min_col: i32 = Piece.BOUND_SIZE;
    var max_col: i32 = -1;
    var min_row: i32 = Piece.BOUND_SIZE;
    var max_row: i32 = -1;
    for (0..Piece.BOUND_SIZE) |r| {
        const shift: u4 = @intCast((Piece.BOUND_SIZE - 1 - r) * 4);
        const bits: u16 = (piece.matrix >> shift) & 0x0F;
        if (bits == 0) continue;
        min_row = @min(min_row, @as(i32, @intCast(r)));
        max_row = @max(max_row, @as(i32, @intCast(r)));
        min_col = @min(min_col, @as(i32, @ctz(bits)));
        max_col = @max(max_col, @as(i32, 15 - @clz(bits)));
    }
    if (max_row < 0) return;

    const ox = box_x + @divTrunc(w - (max_col - min_col + 1) * cell, 2) - min_col * cell;
    const oy = box_y + @divTrunc(h - (max_row - min_row + 1) * cell, 2) - min_row * cell;

    var row: usize = 0;
    while (row < Piece.BOUND_SIZE) : (row += 1) {
        const shift: u4 = @intCast((Piece.BOUND_SIZE - 1 - row) * 4);
        const piece_row: u16 = (piece.matrix >> shift) & 0x0F;
        if (piece_row == 0) continue;
        var col: usize = 0;
        while (col < Piece.BOUND_SIZE) : (col += 1) {
            if ((piece_row & (@as(u16, 1) << @as(u4, @intCast(col)))) == 0) continue;
            const px = ox + @as(i32, @intCast(col)) * cell;
            const py = oy + @as(i32, @intCast(row)) * cell;
            rl.DrawRectangle(px + 1, py + 1, cell - 2, cell - 2, color);
        }
    }
}

/// One piece filling a preview box. Cells are a bit smaller than board cells
/// so every piece fits with a margin.
fn drawPieceMini(piece: *const Piece, box_x: i32, box_y: i32, color: rl.Color) void {
    drawPieceIn(piece, box_x, box_y, BOX, BOX, @divTrunc(CELL * 3, 4), color);
}

/// Both states of a quantum piece in one preview box: A on top, B below.
fn drawQuantumMini(qp: *const piece_mod.QuantumPiece, box_x: i32, box_y: i32) void {
    const half = @divTrunc(BOX, 2);
    const cell = @divTrunc(CELL, 2);
    drawPieceIn(&qp.state_a, box_x, box_y + 4, BOX, half - 4, cell, shapeColor(qp.state_a.shape_type));
    drawPieceIn(&qp.state_b, box_x, box_y + half, BOX, half - 4, cell, shapeColor(qp.state_b.shape_type));
}

// ── Board drawing ──────────────────────────────────────────────────────────────
fn drawBoardBg(board_x: i32) void {
    rl.DrawRectangle(board_x, BOARD_Y, BOARD_W, BOARD_H, COL_BLACK);
    rl.DrawRectangleLines(board_x - 1, BOARD_Y - 1, BOARD_W + 2, BOARD_H + 2, COL_BORDER);
}

fn drawBoardCells(layout: BoardLayout, state: *const GameState) void {
    var row: usize = 0;
    while (row < Board.HEIGHT) : (row += 1) {
        var col: usize = 0;
        while (col < Board.WIDTH) : (col += 1) {
            const bit: u16 = @as(u16, 1) << @as(u4, @intCast(col));
            const locked = (state.board.grid[row] & bit) != 0;
            cellAt(layout.board_x, @intCast(col), @intCast(row), if (locked) COL_LOCKED else COL_EMPTY, .fill);
        }
    }
}

fn drawBoxBg(x: i32, y: i32, w: i32, h: i32) void {
    if (block_box_tex) |tex| {
        drawTexIn(tex, x, y, w, h);
    } else {
        rl.DrawRectangle(x, y, w, h, COL_EMPTY);
        rl.DrawRectangleLines(x - 1, y - 1, w + 2, h + 2, COL_BORDER);
    }
}

// ── Background animation ───────────────────────────────────────────────────────
fn updateBgFrame() void {
    if (bg_textures.len == 0) return;
    bg_frame_timer += rl.GetFrameTime();
    const count: u32 = @intCast(bg_textures.len);
    while (bg_frame_timer >= BG_FRAME_DURATION) {
        bg_frame_timer -= BG_FRAME_DURATION;
        bg_current_frame = (bg_current_frame + 1) % count;
    }
}

fn drawBgFrame() void {
    rl.ClearBackground(COL_BLACK);
    if (bg_textures.len == 0) return;
    drawFullscreenTex(bg_textures[bg_current_frame]);
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

/// Both possible landing spots, outlined with their collapse probability, so
/// the player can see where the piece ends up in either reality.
fn drawGhostPieces(layout: BoardLayout, state: *const GameState) void {
    const qp = &state.current_piece;
    const prob_a = qp.prob_a;
    const ghosts = [2]struct { piece: Piece, prob: f32 }{
        .{ .piece = state.projectGhostPiece(&qp.state_a), .prob = prob_a },
        .{ .piece = state.projectGhostPiece(&qp.state_b), .prob = 1.0 - prob_a },
    };

    for (ghosts) |ghost| {
        const color = withAlpha(shapeColor(ghost.piece.shape_type), probabilityAlpha(ghost.prob, 90, 230));
        drawPieceOnBoard(layout.board_x, &ghost.piece, color, .outline);
    }
    for (ghosts) |ghost| {
        const anchor = labelAnchor(&ghost.piece) orelse continue;
        var buf: [8]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d}%", .{@as(u32, @intFromFloat(@round(ghost.prob * 100.0)))}) catch continue;
        const px = layout.board_x + anchor[0] * CELL + 3;
        const py = BOARD_Y + anchor[1] * CELL + 3;
        drawShadowText(text, px, py, 10, COL_WHITE);
    }
}

fn drawActivePieces(layout: BoardLayout, state: *const GameState) void {
    const qp = &state.current_piece;
    if (!qp.locked_a)
        drawPieceOnBoard(layout.board_x, &qp.state_a, withAlpha(shapeColor(qp.state_a.shape_type), probabilityAlpha(qp.prob_a, 110, 255)), .fill);
    if (!qp.locked_b)
        drawPieceOnBoard(layout.board_x, &qp.state_b, withAlpha(shapeColor(qp.state_b.shape_type), probabilityAlpha(1.0 - qp.prob_a, 110, 255)), .fill);
}

fn drawHold(layout: BoardLayout, state: *const GameState) void {
    drawBoxBg(layout.left_x, HOLD_Y, BOX, BOX);
    if (state.held_piece) |*held| drawQuantumMini(held, layout.left_x, HOLD_Y);
    if (state.hold_used) rl.DrawRectangle(layout.left_x, HOLD_Y, BOX, BOX, withAlpha(COL_BLACK, 120));
}

/// Shows each state of the current piece in its own box with its probability.
fn drawProbBox(x: i32, y: i32, piece: *const Piece, label: []const u8, prob: f32) void {
    const label_h: i32 = 16; // height of the dark strip that holds the text
    drawBoxBg(x, y, BOX, BOX);
    drawPieceMini(piece, x, y, withAlpha(shapeColor(piece.shape_type), probabilityAlpha(prob, 110, 255)));
    // Dark strip at the top so the label stays readable over the piece
    rl.DrawRectangle(x, y, BOX, label_h, withAlpha(COL_BLACK, 170));
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "{s} {d}%", .{ label, @as(u32, @intFromFloat(@round(prob * 100.0))) }) catch return;
    drawCenteredText(text, x + @divTrunc(BOX, 2), y + 2, 12, COL_WHITE);
}

fn drawProbBoxes(layout: BoardLayout, state: *const GameState) void {
    const qp = &state.current_piece;
    drawProbBox(layout.left_x, PROB_A_Y, &qp.state_a, "A", qp.prob_a);
    drawProbBox(layout.left_x, PROB_B_Y, &qp.state_b, "B", 1.0 - qp.prob_a);
}

fn drawNext(layout: BoardLayout, state: *const GameState) void {
    drawBoxBg(layout.right_x, NEXT_Y, BOX, BOX);
    drawQuantumMini(&state.next_piece, layout.right_x, NEXT_Y);
}

fn drawStats(layout: BoardLayout, state: *const GameState) void {
    var buf: [48]u8 = undefined;
    const x = layout.right_x;
    const lh: i32 = 50;
    var y: i32 = STATS_Y;

    drawShadowText(layout.label, x, y, 30, COL_WHITE);
    y += lh + 4;

    const score = std.fmt.bufPrintZ(&buf, "SCORE: {d}", .{state.score}) catch return;
    drawShadowText(score, x, y, 20, COL_WHITE);
    y += lh;

    const lines = std.fmt.bufPrintZ(&buf, "LINES: {d}", .{state.lines_cleared}) catch return;
    drawShadowText(lines, x, y, 20, COL_WHITE);
    y += lh;

    const level = std.fmt.bufPrintZ(&buf, "LEVEL: {d}", .{state.level}) catch return;
    drawShadowText(level, x, y, 20, COL_WHITE);
}

fn drawGameOverOverlay(layout: BoardLayout, subtitle: [:0]const u8) void {
    rl.DrawRectangle(layout.board_x, BOARD_Y, BOARD_W, BOARD_H, withAlpha(COL_BLACK, 180));
    const sz: i32 = 26;
    const mid_y = BOARD_Y + @divTrunc(BOARD_H, 2);
    const center_x = layout.board_x + @divTrunc(BOARD_W, 2);
    drawCenteredText("GAME OVER", center_x, mid_y - sz, sz, COL_RED);
    drawCenteredText(subtitle, center_x, mid_y + 8, 13, COL_LABEL);
}

fn drawOneSide(layout: BoardLayout, state: *const GameState, game_over_msg: [:0]const u8) void {
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

fn drawControlsHint() void {
    drawCenteredText(CONTROLS_HINT, @divTrunc(WIN_W, 2), BOARD_Y + BOARD_H + 12, 14, COL_LABEL);
}

// ── Winner screen overlay ──────────────────────────────────────────────────────
fn drawWinnerScreen(player: *const GameState, ai: *const GameState) void {
    rl.DrawRectangle(0, 0, WIN_W, WIN_H, withAlpha(COL_BLACK, 160));

    const mid_x = @divTrunc(WIN_W, 2);
    const mid_y = @divTrunc(WIN_H, 2);

    const winner_msg: [:0]const u8, const winner_col: rl.Color = if (player.score > ai.score)
        .{ "PLAYER WINS!", COL_GREEN }
    else if (ai.score > player.score)
        .{ "AI WINS!", COL_RED }
    else
        .{ "IT'S A TIE!", COL_GOLD };
    drawCenteredText(winner_msg, mid_x, mid_y - 80, 42, winner_col);

    var buf: [64]u8 = undefined;
    const ps = std.fmt.bufPrintZ(&buf, "Player: {d}", .{player.score}) catch return;
    drawCenteredText(ps, mid_x, mid_y - 20, 22, COL_WHITE);
    const as_ = std.fmt.bufPrintZ(&buf, "AI:     {d}", .{ai.score}) catch return;
    drawCenteredText(as_, mid_x, mid_y + 10, 22, COL_WHITE);

    drawCenteredText("Press R for main menu", mid_x, mid_y + 56, 14, COL_LABEL);
}

// ── Public screen drawing functions ───────────────────────────────────────────

/// Returns the selected GameMode when player clicks, null otherwise.
pub fn drawLandingFrame() ?GameMode {
    rl.BeginDrawing();
    defer rl.EndDrawing();
    rl.ClearBackground(COL_BG);

    if (landing_tex) |tex| drawFullscreenTex(tex);

    const mouse = rl.GetMousePosition();
    const clicked = rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);

    if (clicked and rl.CheckCollisionPointRec(mouse, scaledRect(VSAI_HIT))) return .VsAI;
    if (clicked and rl.CheckCollisionPointRec(mouse, scaledRect(SOLO_HIT))) return .Solo;
    return null;
}

/// Returns the selected Difficulty when player clicks, null otherwise.
pub fn drawDifficultyFrame() ?Difficulty {
    rl.BeginDrawing();
    defer rl.EndDrawing();
    rl.ClearBackground(COL_BG);

    if (difficulty_tex) |tex| drawFullscreenTex(tex);

    const mouse = rl.GetMousePosition();
    const clicked = rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);

    if (clicked and rl.CheckCollisionPointRec(mouse, scaledRect(EASY_HIT))) return .Easy;
    if (clicked and rl.CheckCollisionPointRec(mouse, scaledRect(MED_HIT))) return .Medium;
    if (clicked and rl.CheckCollisionPointRec(mouse, scaledRect(HARD_HIT))) return .Hard;
    return null;
}

/// Draw VsAI game frame. Pass show_winner=true once both are game_over.
pub fn drawVsAiFrame(player: *const GameState, ai: *const GameState, show_winner: bool) void {
    rl.BeginDrawing();
    defer rl.EndDrawing();

    updateBgFrame();
    drawBgFrame();

    drawBoardBg(L_BOARD_X);
    drawBoardBg(R_BOARD_X);

    rl.DrawRectangle(DIVIDER_X, 0, 1, WIN_H, COL_DIVIDER);

    drawOneSide(PLAYER_LAYOUT, player, "Press R for menu");
    drawOneSide(AI_LAYOUT, ai, "Waiting...");
    drawControlsHint();

    if (show_winner) drawWinnerScreen(player, ai);
}

/// Draw Solo game frame (player board centered).
pub fn drawSoloFrame(player: *const GameState) void {
    const cx = @divTrunc(WIN_W - BOARD_W, 2);
    const solo = BoardLayout{
        .left_x = cx - BOX - GAP,
        .board_x = cx,
        .right_x = cx + BOARD_W + GAP,
        .label = "PLAYER",
    };

    rl.BeginDrawing();
    defer rl.EndDrawing();

    updateBgFrame();
    drawBgFrame();
    drawBoardBg(cx);
    drawOneSide(solo, player, "Press R for menu");
    drawControlsHint();
}
