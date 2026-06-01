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
const HOLD_SIZE: i32 = @as(i32, Piece.BOUND_SIZE) * CELL;
const PANEL_W: i32 = 100;
const GAP: i32 = 8;
const MARGIN: i32 = 10;
const BOARD_Y: i32 = 60;

// Left (player)
const L_HOLD_X: i32 = MARGIN;
const L_BOARD_X: i32 = L_HOLD_X + HOLD_SIZE + GAP;
const L_PANEL_X: i32 = L_BOARD_X + BOARD_W + GAP;

// Right (AI)
const DIVIDER_X: i32 = L_PANEL_X + PANEL_W + MARGIN;
const R_HOLD_X: i32 = DIVIDER_X + MARGIN;
const R_BOARD_X: i32 = R_HOLD_X + HOLD_SIZE + GAP;
const R_PANEL_X: i32 = R_BOARD_X + BOARD_W + GAP;

pub const WIN_W: i32 = R_PANEL_X + PANEL_W + MARGIN;
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
const BG_FRAME_DURATION: f32 = 1.0 / 24.0;

var difficulty_texture: ?rl.Texture2D = null;
var difficulty_assets_inited: bool = false;

var game_board_texture: ?rl.Texture2D = null;
var game_board_inited: bool = false;

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

// ── Board layout descriptor ───────────────────────────────────────────────────
const BoardLayout = struct {
    hold_x: i32,
    board_x: i32,
    panel_x: i32,
    label: [:0]const u8,
};

const PLAYER_LAYOUT = BoardLayout{
    .hold_x = L_HOLD_X,
    .board_x = L_BOARD_X,
    .panel_x = L_PANEL_X,
    .label = "PLAYER",
};

const AI_LAYOUT = BoardLayout{
    .hold_x = R_HOLD_X,
    .board_x = R_BOARD_X,
    .panel_x = R_PANEL_X,
    .label = "AI",
};

// ── Primitives ────────────────────────────────────────────────────────────────
fn cellAt(board_x: i32, bx: i32, by: i32, color: rl.Color) void {
    const px = board_x + bx * CELL;
    const py = BOARD_Y + by * CELL;
    rl.drawRectangle(px + 1, py + 1, CELL - 2, CELL - 2, color);
}
fn cellAtOutline(board_x: i32, bx: i32, by: i32, color: rl.Color) void {
    const px = board_x + bx * CELL;
    const py = BOARD_Y + by * CELL;
    rl.drawRectangleLines(px + 1, py + 1, CELL - 2, CELL - 2, color);
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

fn drawGhostPiece(layout: BoardLayout, state: *const GameState) void {
    const ghost_a = state.projectGhostPiece(&state.current_piece.state_a);
    const ghost_b = state.projectGhostPiece(&state.current_piece.state_b);
    // A ghost: crisp outline, matches the solid A piece above it
    drawPieceOnBoardOutline(layout.board_x, &ghost_a, withAlpha(shapeColor(ghost_a.shape_type), 180));
    // B ghost: barely-there fill, matches the faint B piece above it
    drawPieceOnBoard(layout.board_x, &ghost_b, withAlpha(shapeColor(ghost_b.shape_type), 25));
}

fn drawHold(layout: BoardLayout, state: *const GameState) void {
    rl.drawText("HOLD", layout.hold_x, BOARD_Y - 20, 14, COL_LABEL);
    rl.drawRectangleLines(
        layout.hold_x - 1,
        BOARD_Y - 1,
        HOLD_SIZE + 2,
        HOLD_SIZE + 2,
        COL_BORDER,
    );
    if (state.held_piece) |held| {
        drawPieceMini(&held.state_a, layout.hold_x, BOARD_Y, shapeColor(held.state_a.shape_type));
        drawPieceMini(&held.state_b, layout.hold_x, BOARD_Y, withAlpha(shapeColor(held.state_b.shape_type), 130));
    }
}

fn drawPanel(layout: BoardLayout, state: *const GameState) void {
    const px = layout.panel_x;
    var buf: [32]u8 = undefined;

    // Board label
    rl.drawText(layout.label, px, BOARD_Y - 20, 18, COL_WHITE);

    // Score
    rl.drawText("SCORE", px, BOARD_Y + 10, 13, COL_LABEL);
    const s1 = std.fmt.bufPrintZ(&buf, "{d}", .{state.score}) catch return;
    rl.drawText(s1, px, BOARD_Y + 26, 20, COL_WHITE);

    // Lines
    rl.drawText("LINES", px, BOARD_Y + 62, 13, COL_LABEL);
    const s2 = std.fmt.bufPrintZ(&buf, "{d}", .{state.lines_cleared}) catch return;
    rl.drawText(s2, px, BOARD_Y + 78, 20, COL_WHITE);

    // Level
    rl.drawText("LEVEL", px, BOARD_Y + 114, 13, COL_LABEL);
    const s3 = std.fmt.bufPrintZ(&buf, "{d}", .{state.level}) catch return;
    rl.drawText(s3, px, BOARD_Y + 130, 20, COL_WHITE);

    // Quantum prob
    rl.drawText("PROB", px, BOARD_Y + 174, 13, COL_LABEL);
    const pct: u32 = @intFromFloat(state.current_piece.prob_a * 100.0);
    const s4 = std.fmt.bufPrintZ(&buf, "A {d}%", .{pct}) catch return;
    rl.drawText(s4, px, BOARD_Y + 190, 15, shapeColor(state.current_piece.state_a.shape_type));
    const s5 = std.fmt.bufPrintZ(&buf, "B {d}%", .{100 - pct}) catch return;
    rl.drawText(s5, px, BOARD_Y + 208, 15, shapeColor(state.current_piece.state_b.shape_type));

    // Next piece
    const next_y: i32 = BOARD_Y + 250;
    rl.drawText("NEXT", px, next_y, 13, COL_LABEL);
    rl.drawRectangleLines(px - 1, next_y + 16, HOLD_SIZE + 2, HOLD_SIZE + 2, COL_BORDER);
    drawPieceMini(&state.next_piece.state_a, px, next_y + 17, shapeColor(state.next_piece.state_a.shape_type));
    drawPieceMini(&state.next_piece.state_b, px, next_y + 17, withAlpha(shapeColor(state.next_piece.state_b.shape_type), 130));
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
    drawInGameBoardOverlay();

    drawBoard(PLAYER_LAYOUT, player);
    if (!player.game_over) drawGhostPiece(PLAYER_LAYOUT, player);
    if (!player.game_over) drawCurrentPiece(PLAYER_LAYOUT, player);
    drawHold(PLAYER_LAYOUT, player);
    drawPanel(PLAYER_LAYOUT, player);
    if (player.game_over) drawGameOverOverlay(PLAYER_LAYOUT, "Press R to restart");

    drawBoard(AI_LAYOUT, ai);
    if (!ai.game_over) drawGhostPiece(AI_LAYOUT, ai);
    if (!ai.game_over) drawCurrentPiece(AI_LAYOUT, ai);
    drawHold(AI_LAYOUT, ai);
    drawPanel(AI_LAYOUT, ai);
    if (ai.game_over) drawGameOverOverlay(AI_LAYOUT, "Restarting...");
}
