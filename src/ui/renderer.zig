const std = @import("std");
const rl = @import("raylib");
const game_mod = @import("../engine/game.zig");
const piece_mod = @import("../engine/piece.zig");
const board_mod = @import("../engine/board.zig");

const GameState = game_mod.GameState;
const Board = board_mod.Board;
const Piece = piece_mod.Piece;
const ShapeType = piece_mod.ShapeType;

// ── Layout ────────────────────────────────────────────────────────────────────
pub const CELL: i32 = 28;

const BOARD_W: i32 = @as(i32, Board.WIDTH) * CELL;
const BOARD_H: i32 = @as(i32, Board.HEIGHT) * CELL;
const BOX_SIZE: i32 = @as(i32, Piece.BOUND_SIZE) * CELL; // 112 pixels (4x28)
const BOX_GAP: i32 = 8;
const GAP: i32 = 8;
const MARGIN: i32 = 10;
const BOARD_Y: i32 = 60;

// Stats box dimensions
const STATS_W: i32 = 180;
const STATS_H: i32 = BOX_SIZE * 2 + BOX_GAP; // Same height as Hold + Prob + gap
const STATS_PADDING: i32 = 15;

// Left (player) - left-side stack
const L_BOX_X: i32 = MARGIN;
const L_HOLD_Y: i32 = BOARD_Y;
const L_PROB_A_Y: i32 = L_HOLD_Y + BOX_SIZE + BOX_GAP;
const L_PROB_B_Y: i32 = L_PROB_A_Y + BOX_SIZE + BOX_GAP;

// Left (player) - board
const L_BOARD_X: i32 = L_BOX_X + BOX_SIZE + GAP;

// Left (player) - right-side stack
const L_NEXT_Y: i32 = BOARD_Y;
const L_STATS_Y: i32 = BOARD_Y + @divTrunc(BOARD_H - STATS_H, 2); // Vertically centered
const L_STATS_X: i32 = L_BOARD_X + BOARD_W + GAP;

// Right (AI) - divider
const DIVIDER_X: i32 = L_STATS_X + STATS_W + MARGIN;

// Right (AI) - left-side stack
const R_BOX_X: i32 = DIVIDER_X + MARGIN;
const R_HOLD_Y: i32 = BOARD_Y;
const R_PROB_A_Y: i32 = R_HOLD_Y + BOX_SIZE + BOX_GAP;
const R_PROB_B_Y: i32 = R_PROB_A_Y + BOX_SIZE + BOX_GAP;

// Right (AI) - board
const R_BOARD_X: i32 = R_BOX_X + BOX_SIZE + GAP;

// Right (AI) - right-side stack
const R_NEXT_Y: i32 = BOARD_Y;
const R_STATS_Y: i32 = BOARD_Y + @divTrunc(BOARD_H - STATS_H, 2); // Vertically centered
const R_STATS_X: i32 = R_BOARD_X + BOARD_W + GAP;

pub const WIN_W: i32 = R_STATS_X + STATS_W + MARGIN;
pub const WIN_H: i32 = BOARD_Y + BOARD_H + 30;

// ── Colours ───────────────────────────────────────────────────────────────────
const COL_BG = rl.Color{ .r = 18, .g = 18, .b = 18, .a = 255 };
const COL_EMPTY = rl.Color{ .r = 28, .g = 28, .b = 28, .a = 255 };
const COL_LOCKED = rl.Color{ .r = 160, .g = 160, .b = 160, .a = 255 };
const COL_BORDER = rl.Color{ .r = 70, .g = 70, .b = 70, .a = 255 };
const COL_LABEL = rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 };
const COL_WHITE = rl.Color{ .r = 240, .g = 240, .b = 240, .a = 255 };
const COL_RED = rl.Color{ .r = 220, .g = 50, .b = 50, .a = 255 };
const COL_DIVIDER = rl.Color{ .r = 45, .g = 45, .b = 45, .a = 255 };
const COL_BLACK = rl.Color.black;
const COL_BTN = rl.Color{ .r = 55, .g = 55, .b = 55, .a = 255 };
const COL_BTN_HOVER = rl.Color{ .r = 75, .g = 75, .b = 75, .a = 255 };

const AiConfig = struct {
    weights: []const u8,
    ai_depth: u32,
    ai_beam_width: u32,
};

var current_ai_config: AiConfig = .{
    .weights = "default.bin",
    .ai_depth = 0,
    .ai_beam_width = 0,
};

const UiScreen = enum {
    DifficultySelect,
    InGame,
};

var ui_screen: UiScreen = .DifficultySelect;

const DIFFICULTY_ASSET: [:0]const u8 = "assets/landing_page/difficulty_page.png";
const VS_AI_FRAMES_DIR: []const u8 = "assets/vs_ai/frames";
const GAME_BOARD_ASSET: [:0]const u8 = "assets/vs_ai/game_board.png";
const BLOCK_BOX_ASSET: [:0]const u8 = "assets/vs_ai/block.png";
const BG_FRAME_DURATION: f32 = 1.0 / 24.0;

var difficulty_texture: ?rl.Texture2D = null;
var difficulty_assets_inited: bool = false;

var game_board_texture: ?rl.Texture2D = null;
var game_board_inited: bool = false;

var block_box_texture: ?rl.Texture2D = null;
var block_box_inited: bool = false;

var bg_current_frame: u32 = 0;
var bg_frame_timer: f32 = 0.0;
var bg_textures: []rl.Texture2D = &.{};
var bg_anim_inited: bool = false;
const bg_gpa = std.heap.page_allocator;

const FrameFile = struct {
    num: u32,
    name: []const u8,
};

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

fn initDifficultyAssets() void {
    if (difficulty_assets_inited) return;
    difficulty_assets_inited = true;
    difficulty_texture = rl.loadTexture(DIFFICULTY_ASSET) catch null;
    if (difficulty_texture) |tex| {
        rl.setTextureFilter(tex, .bilinear);
    }
}

fn initGameBoardAsset() void {
    if (game_board_inited) return;
    game_board_inited = true;
    game_board_texture = rl.loadTexture(GAME_BOARD_ASSET) catch null;
    if (game_board_texture) |tex| {
        rl.setTextureFilter(tex, .bilinear);
    }
}

fn initBlockBoxAsset() void {
    if (block_box_inited) return;
    block_box_inited = true;
    block_box_texture = rl.loadTexture(BLOCK_BOX_ASSET) catch null;
    if (block_box_texture) |tex| {
        rl.setTextureFilter(tex, .bilinear);
    }
}

fn drawBoardBackgroundAt(board_x: i32) void {
    const tex = game_board_texture orelse return;
    const src = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(tex.width),
        .height = @floatFromInt(tex.height),
    };
    const dest = rl.Rectangle{
        .x = @floatFromInt(board_x),
        .y = @floatFromInt(BOARD_Y),
        .width = @floatFromInt(BOARD_W),
        .height = @floatFromInt(BOARD_H),
    };
    rl.drawTexturePro(tex, src, dest, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
}

fn drawTexturedBox(x: i32, y: i32, w: i32, h: i32) void {
    const tex = block_box_texture orelse return;
    const src = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(tex.width),
        .height = @floatFromInt(tex.height),
    };
    const dest = rl.Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };
    rl.drawTexturePro(tex, src, dest, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
}

fn drawInGameBoardOverlay() void {
    drawBoardBackgroundAt(L_BOARD_X);
    drawBoardBackgroundAt(R_BOARD_X);
}

fn scaledHitRect(x_n: f32, y_n: f32, w_n: f32, h_n: f32) rl.Rectangle {
    const w = @as(f32, @floatFromInt(WIN_W));
    const h = @as(f32, @floatFromInt(WIN_H));
    return .{
        .x = w * x_n,
        .y = h * y_n,
        .width = w * w_n,
        .height = h * h_n,
    };
}

// Normalized hit boxes on difficulty_page.png (1280×720) for Easy / Medium / Hard pills
const DIFF_BTN_W_NORM: f32 = 0.20;
const DIFF_BTN_H_NORM: f32 = 0.08;
const DIFF_BTN_X_NORM: f32 = 0.40;
const EASY_HIT_Y_NORM: f32 = 0.54;
const MED_HIT_Y_NORM: f32 = 0.64;
const HARD_HIT_Y_NORM: f32 = 0.74;

fn initInGameBgAnim() void {
    if (bg_anim_inited) return;

    var dir = std.fs.cwd().openDir(VS_AI_FRAMES_DIR, .{ .iterate = true }) catch return;
    defer dir.close();

    var frame_files: std.ArrayList(FrameFile) = .empty;
    defer {
        for (frame_files.items) |entry| bg_gpa.free(entry.name);
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
            return;
        };
    }

    if (frame_files.items.len == 0) return;

    std.mem.sort(FrameFile, frame_files.items, {}, struct {
        fn less(_: void, a: FrameFile, b: FrameFile) bool {
            return a.num < b.num;
        }
    }.less);

    var tex_list: std.ArrayList(rl.Texture2D) = .empty;
    errdefer {
        for (tex_list.items) |tex| rl.unloadTexture(tex);
        tex_list.deinit(bg_gpa);
    }

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

    if (tex_list.items.len != frame_files.items.len) return;

    bg_textures = tex_list.toOwnedSlice(bg_gpa) catch return;
    bg_anim_inited = true;
}

fn updateInGameBgFrame() void {
    if (bg_textures.len == 0) return;
    bg_frame_timer += rl.getFrameTime();
    const frame_count: u32 = @intCast(bg_textures.len);
    while (bg_frame_timer >= BG_FRAME_DURATION) {
        bg_frame_timer -= BG_FRAME_DURATION;
        bg_current_frame = (bg_current_frame + 1) % frame_count;
    }
}

fn drawInGameBgFrame() void {
    rl.clearBackground(COL_BLACK);
    if (bg_textures.len == 0) return;
    const idx = @as(usize, @intCast(bg_current_frame));
    if (idx >= bg_textures.len) return;

    const tex = bg_textures[idx];
    const src = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(tex.width),
        .height = @floatFromInt(tex.height),
    };
    const dest = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(WIN_W),
        .height = @floatFromInt(WIN_H),
    };
    rl.drawTexturePro(tex, src, dest, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
}

fn drawUiTexture(tex: rl.Texture2D) void {
    const src: rl.Rectangle = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(tex.width),
        .height = @floatFromInt(tex.height),
    };
    const dest: rl.Rectangle = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(WIN_W),
        .height = @floatFromInt(WIN_H),
    };
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

fn drawTextWithShadow(text: [:0]const u8, x: i32, y: i32, font_size: i32, color: rl.Color) void {
    // Draw shadow (1px offset)
    rl.drawText(text, x + 1, y + 1, font_size, COL_BLACK);
    // Draw text on top
    rl.drawText(text, x, y, font_size, color);
}

// ── Board layout descriptor ───────────────────────────────────────────────────
const BoardLayout = struct {
    left_x: i32, // X position for left-side stack (Hold, Prob A, Prob B)
    board_x: i32, // X position for game board
    right_x: i32, // X position for right-side stack (Next, Stats)
    hold_y: i32,
    prob_a_y: i32,
    prob_b_y: i32,
    next_y: i32,
    stats_y: i32,
    label: [:0]const u8,
};

const PLAYER_LAYOUT = BoardLayout{
    .left_x = L_BOX_X,
    .board_x = L_BOARD_X,
    .right_x = L_STATS_X,
    .hold_y = L_HOLD_Y,
    .prob_a_y = L_PROB_A_Y,
    .prob_b_y = L_PROB_B_Y,
    .next_y = L_NEXT_Y,
    .stats_y = L_STATS_Y,
    .label = "PLAYER",
};

const AI_LAYOUT = BoardLayout{
    .left_x = R_BOX_X,
    .board_x = R_BOARD_X,
    .right_x = R_STATS_X,
    .hold_y = R_HOLD_Y,
    .prob_a_y = R_PROB_A_Y,
    .prob_b_y = R_PROB_B_Y,
    .next_y = R_NEXT_Y,
    .stats_y = R_STATS_Y,
    .label = "AI",
};

// ── Primitives ────────────────────────────────────────────────────────────────
fn cellAt(board_x: i32, bx: i32, by: i32, color: rl.Color) void {
    const px = board_x + bx * CELL;
    const py = BOARD_Y + by * CELL;
    rl.drawRectangle(px + 1, py + 1, CELL - 2, CELL - 2, color);
}

fn miniCellAt(ox: i32, oy: i32, col: usize, row: usize, color: rl.Color) void {
    const px = ox + @as(i32, @intCast(col)) * CELL;
    const py = oy + @as(i32, @intCast(row)) * CELL;
    rl.drawRectangle(px + 1, py + 1, CELL - 2, CELL - 2, color);
}

// ── Piece drawing — mirrors overlayPiece projection exactly ──────────────────
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

// ── Per-board sections ────────────────────────────────────────────────────────
// Locked cells only; game_board.png is the sole playfield background (see drawInGameBoardOverlay).
fn drawBoard(layout: BoardLayout, state: *const GameState) void {
    var row: usize = 0;
    while (row < Board.HEIGHT) : (row += 1) {
        var col: usize = 0;
        while (col < Board.WIDTH) : (col += 1) {
            const bit: u16 = @as(u16, 1) << @as(u4, @intCast(col));
            const locked = (state.board.grid[row] & bit) != 0;
            if (!locked) continue;
            cellAt(layout.board_x, @intCast(col), @intCast(row), COL_LOCKED);
        }
    }
}

fn drawCurrentPiece(layout: BoardLayout, state: *const GameState) void {
    const qp = &state.current_piece;
    if (!qp.locked_a)
        drawPieceOnBoard(layout.board_x, &qp.state_a, shapeColor(qp.state_a.shape_type));
    if (!qp.locked_b)
        drawPieceOnBoard(layout.board_x, &qp.state_b, withAlpha(shapeColor(qp.state_b.shape_type), 130));
}

fn drawHold(layout: BoardLayout, state: *const GameState) void {
    // Draw Hold box with block.png texture
    drawTexturedBox(layout.left_x, layout.hold_y, BOX_SIZE, BOX_SIZE);

    // Draw tetromino inside Hold box
    if (state.held_piece) |held| {
        drawPieceMini(&held.state_a, layout.left_x, layout.hold_y, shapeColor(held.state_a.shape_type));
        drawPieceMini(&held.state_b, layout.left_x, layout.hold_y, withAlpha(shapeColor(held.state_b.shape_type), 130));
    }
}

fn drawProbabilityBoxes(layout: BoardLayout, state: *const GameState) void {
    var buf: [16]u8 = undefined;

    // Probability A box
    drawTexturedBox(layout.left_x, layout.prob_a_y, BOX_SIZE, BOX_SIZE);
    const pct: u32 = @intFromFloat(state.current_piece.prob_a * 100.0);
    const prob_a_text = std.fmt.bufPrintZ(&buf, "A {d}%", .{pct}) catch return;
    const text_w = rl.measureText(prob_a_text, 14);
    const text_x = layout.left_x + @divTrunc(BOX_SIZE - text_w, 2);
    const text_y = layout.prob_a_y + @divTrunc(BOX_SIZE - 14, 2);
    rl.drawText(prob_a_text, text_x, text_y, 14, shapeColor(state.current_piece.state_a.shape_type));

    // Probability B box
    drawTexturedBox(layout.left_x, layout.prob_b_y, BOX_SIZE, BOX_SIZE);
    const prob_b_text = std.fmt.bufPrintZ(&buf, "B {d}%", .{100 - pct}) catch return;
    const text_w_b = rl.measureText(prob_b_text, 14);
    const text_x_b = layout.left_x + @divTrunc(BOX_SIZE - text_w_b, 2);
    const text_y_b = layout.prob_b_y + @divTrunc(BOX_SIZE - 14, 2);
    rl.drawText(prob_b_text, text_x_b, text_y_b, 14, shapeColor(state.current_piece.state_b.shape_type));
}

fn drawNext(layout: BoardLayout, state: *const GameState) void {
    // Draw Next box with block.png texture
    drawTexturedBox(layout.right_x, layout.next_y, BOX_SIZE, BOX_SIZE);

    // Draw tetromino inside Next box
    drawPieceMini(&state.next_piece.state_a, layout.right_x, layout.next_y, shapeColor(state.next_piece.state_a.shape_type));
    drawPieceMini(&state.next_piece.state_b, layout.right_x, layout.next_y, withAlpha(shapeColor(state.next_piece.state_b.shape_type), 130));
}

fn drawStats(layout: BoardLayout, state: *const GameState) void {
    // Draw stats with spacing (no background)
    var buf: [48]u8 = undefined;
    const text_x = layout.right_x;
    const text_y = layout.stats_y;
    const font_size_header: i32 = 14;
    const font_size_label: i32 = 12;
    const line_height: i32 = 22; // Spacing between lines

    // Draw header (PLAYER/AI) with shadow
    const header_text = std.fmt.bufPrintZ(&buf, "{s}", .{layout.label}) catch return;
    drawTextWithShadow(header_text, text_x, text_y, font_size_header, rl.Color.white);

    // Draw score with shadow
    const score_text = std.fmt.bufPrintZ(&buf, "SCORE: {d}", .{state.score}) catch return;
    drawTextWithShadow(score_text, text_x, text_y + line_height, font_size_label, rl.Color.white);

    // Draw lines with shadow
    const lines_text = std.fmt.bufPrintZ(&buf, "LINES: {d}", .{state.lines_cleared}) catch return;
    drawTextWithShadow(lines_text, text_x, text_y + line_height * 2, font_size_label, rl.Color.white);

    // Draw level with shadow
    const level_text = std.fmt.bufPrintZ(&buf, "LEVEL: {d}", .{state.level}) catch return;
    drawTextWithShadow(level_text, text_x, text_y + line_height * 3, font_size_label, rl.Color.white);
}

fn drawGameOverOverlay(layout: BoardLayout, comptime subtitle: [:0]const u8) void {
    rl.drawRectangle(layout.board_x, BOARD_Y, BOARD_W, BOARD_H, withAlpha(COL_BG, 210));
    const msg = "GAME OVER";
    const sz: i32 = 28;
    const mid_y = BOARD_Y + @divTrunc(BOARD_H, 2);
    const w = rl.measureText(msg, sz);
    rl.drawText(msg, layout.board_x + @divTrunc(BOARD_W - w, 2), mid_y - sz, sz, COL_RED);
    const sw = rl.measureText(subtitle, 14);
    rl.drawText(subtitle, layout.board_x + @divTrunc(BOARD_W - sw, 2), mid_y + 10, 14, COL_LABEL);
}

fn drawDifficultySelect() void {
    initDifficultyAssets();
    const tex = difficulty_texture orelse return;
    drawUiTexture(tex);

    const mouse = rl.getMousePosition();
    const clicked = rl.isMouseButtonPressed(rl.MouseButton.left);

    const easy = scaledHitRect(DIFF_BTN_X_NORM, EASY_HIT_Y_NORM, DIFF_BTN_W_NORM, DIFF_BTN_H_NORM);
    if (clicked and rl.checkCollisionPointRec(mouse, easy)) {
        current_ai_config = .{
            .weights = "easy_weights.bin",
            .ai_depth = 2,
            .ai_beam_width = 4,
        };
        ui_screen = .InGame;
        return;
    }

    const medium = scaledHitRect(DIFF_BTN_X_NORM, MED_HIT_Y_NORM, DIFF_BTN_W_NORM, DIFF_BTN_H_NORM);
    if (clicked and rl.checkCollisionPointRec(mouse, medium)) {
        current_ai_config = .{
            .weights = "med_weights.bin",
            .ai_depth = 4,
            .ai_beam_width = 8,
        };
        ui_screen = .InGame;
        return;
    }

    const hard = scaledHitRect(DIFF_BTN_X_NORM, HARD_HIT_Y_NORM, DIFF_BTN_W_NORM, DIFF_BTN_H_NORM);
    if (clicked and rl.checkCollisionPointRec(mouse, hard)) {
        current_ai_config = .{
            .weights = "hard_weights.bin",
            .ai_depth = 6,
            .ai_beam_width = 16,
        };
        ui_screen = .InGame;
    }
}

pub fn enterDifficultySelect() void {
    ui_screen = .DifficultySelect;
}

// ── Public entry point ────────────────────────────────────────────────────────
pub fn drawFrame(player: *const GameState, ai: *const GameState) void {
    rl.beginDrawing();
    defer rl.endDrawing();

    rl.clearBackground(COL_BG);

    switch (ui_screen) {
        .DifficultySelect => {
            drawDifficultySelect();
            return;
        },
        .InGame => {},
    }

    initInGameBgAnim();
    updateInGameBgFrame();
    drawInGameBgFrame();

    initGameBoardAsset();
    initBlockBoxAsset();
    drawInGameBoardOverlay();

    // Draw divider
    rl.drawRectangle(DIVIDER_X, 0, 1, WIN_H, COL_DIVIDER);

    // Draw player UI
    drawBoard(PLAYER_LAYOUT, player);
    if (!player.game_over) drawCurrentPiece(PLAYER_LAYOUT, player);
    drawHold(PLAYER_LAYOUT, player);
    drawProbabilityBoxes(PLAYER_LAYOUT, player);
    drawNext(PLAYER_LAYOUT, player);
    drawStats(PLAYER_LAYOUT, player);
    if (player.game_over) drawGameOverOverlay(PLAYER_LAYOUT, "Press R to restart");

    // Draw AI UI
    drawBoard(AI_LAYOUT, ai);
    if (!ai.game_over) drawCurrentPiece(AI_LAYOUT, ai);
    drawHold(AI_LAYOUT, ai);
    drawProbabilityBoxes(AI_LAYOUT, ai);
    drawNext(AI_LAYOUT, ai);
    drawStats(AI_LAYOUT, ai);
    if (ai.game_over) drawGameOverOverlay(AI_LAYOUT, "Restarting...");
}
