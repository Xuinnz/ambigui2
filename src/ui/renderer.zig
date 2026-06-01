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
    LandingPage,
    DifficultySelect,
    InGame,
};

var ui_screen: UiScreen = .LandingPage;

const MENU_BTN_W: i32 = 200;
const MENU_BTN_H: i32 = 44;
const MENU_BTN_GAP: i32 = 16;

const LANDING_ASSET: [:0]const u8 = "assets/landing_page/main_page.png";
var landing_texture: ?rl.Texture2D = null;
var landing_assets_inited: bool = false;

// Normalized hit box on main_page.png (3840×2160) for the "Player vs AI" pill
const PVP_HIT_X_NORM: f32 = 0.40;
const PVP_HIT_Y_NORM: f32 = 0.685;
const PVP_HIT_W_NORM: f32 = 0.20;
const PVP_HIT_H_NORM: f32 = 0.08;

fn initLandingAssets() void {
    if (landing_assets_inited) return;
    landing_assets_inited = true;
    landing_texture = rl.loadTexture(LANDING_ASSET) catch null;
    if (landing_texture) |tex| {
        rl.setTextureFilter(tex, .bilinear);
    }
}

fn pvpHitRect() rl.Rectangle {
    const w = @as(f32, @floatFromInt(WIN_W));
    const h = @as(f32, @floatFromInt(WIN_H));
    return .{
        .x = w * PVP_HIT_X_NORM,
        .y = h * PVP_HIT_Y_NORM,
        .width = w * PVP_HIT_W_NORM,
        .height = h * PVP_HIT_H_NORM,
    };
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
fn drawBoard(layout: BoardLayout, state: *const GameState) void {
    rl.drawRectangleLines(
        layout.board_x - 1,
        BOARD_Y - 1,
        BOARD_W + 2,
        BOARD_H + 2,
        COL_BORDER,
    );

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

fn drawCurrentPiece(layout: BoardLayout, state: *const GameState) void {
    const qp = &state.current_piece;
    if (!qp.locked_a)
        drawPieceOnBoard(layout.board_x, &qp.state_a, shapeColor(qp.state_a.shape_type));
    if (!qp.locked_b)
        drawPieceOnBoard(layout.board_x, &qp.state_b, withAlpha(shapeColor(qp.state_b.shape_type), 130));
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

fn drawLandingPage() void {
    initLandingAssets();
    const tex = landing_texture orelse return;

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

    const btn = pvpHitRect();
    const mouse = rl.getMousePosition();
    if (rl.isMouseButtonPressed(rl.MouseButton.left) and rl.checkCollisionPointRec(mouse, btn)) {
        ui_screen = .DifficultySelect;
    }
}

fn menuButtonRect(center_y: i32) rl.Rectangle {
    const x = @divTrunc(WIN_W - MENU_BTN_W, 2);
    return .{
        .x = @floatFromInt(x),
        .y = @floatFromInt(center_y),
        .width = @floatFromInt(MENU_BTN_W),
        .height = @floatFromInt(MENU_BTN_H),
    };
}

fn drawMenuButton(rect: rl.Rectangle, label: [:0]const u8) bool {
    const mouse = rl.getMousePosition();
    const hovered = rl.checkCollisionPointRec(mouse, rect);
    rl.drawRectangleRec(rect, if (hovered) COL_BTN_HOVER else COL_BTN);
    rl.drawRectangleLinesEx(rect, 1, COL_BORDER);

    const label_size: i32 = 20;
    const label_w = rl.measureText(label, label_size);
    const label_x = @as(i32, @intFromFloat(rect.x)) + @divTrunc(MENU_BTN_W - label_w, 2);
    const label_y = @as(i32, @intFromFloat(rect.y)) + @divTrunc(MENU_BTN_H - label_size, 2);
    rl.drawText(label, label_x, label_y, label_size, COL_WHITE);

    return rl.isMouseButtonPressed(rl.MouseButton.left) and hovered;
}

fn drawDifficultySelect() void {
    const heading = "Select Difficulty";
    const heading_size: i32 = 32;
    const heading_w = rl.measureText(heading, heading_size);
    const heading_x = @divTrunc(WIN_W - heading_w, 2);
    const heading_y: i32 = @divTrunc(WIN_H, 2) - 120;
    rl.drawText(heading, heading_x, heading_y, heading_size, COL_WHITE);

    const stack_h = MENU_BTN_H * 3 + MENU_BTN_GAP * 2;
    var y: i32 = @divTrunc(WIN_H - stack_h, 2);

    if (drawMenuButton(menuButtonRect(y), "Easy")) {
        current_ai_config = .{
            .weights = "easy_weights.bin",
            .ai_depth = 2,
            .ai_beam_width = 4,
        };
        ui_screen = .InGame;
        return;
    }
    y += MENU_BTN_H + MENU_BTN_GAP;

    if (drawMenuButton(menuButtonRect(y), "Medium")) {
        current_ai_config = .{
            .weights = "med_weights.bin",
            .ai_depth = 4,
            .ai_beam_width = 8,
        };
        ui_screen = .InGame;
        return;
    }
    y += MENU_BTN_H + MENU_BTN_GAP;

    if (drawMenuButton(menuButtonRect(y), "Hard")) {
        current_ai_config = .{
            .weights = "hard_weights.bin",
            .ai_depth = 6,
            .ai_beam_width = 16,
        };
        ui_screen = .InGame;
    }
}

// ── Public entry point ────────────────────────────────────────────────────────
pub fn drawFrame(player: *const GameState, ai: *const GameState) void {
    rl.beginDrawing();
    defer rl.endDrawing();

    rl.clearBackground(COL_BG);

    switch (ui_screen) {
        .LandingPage => {
            drawLandingPage();
            return;
        },
        .DifficultySelect => {
            drawDifficultySelect();
            return;
        },
        .InGame => {},
    }

    // Red: current_ai_config is set from the difficulty button (weights, ai_depth, ai_beam_width).
    // Feed current_ai_config into engine / AI worker pipelines before tick and draw.
    // TODO: Hook Red's game engine loop functions here
    // TODO: Red — tick/update player and AI GameState each frame before draw
    // TODO: Red — drawFrame(player, ai) using existing board helpers below
    // TODO: Red — wire keyboard/input handler for in-match controls

    rl.drawRectangle(DIVIDER_X, 0, 1, WIN_H, COL_DIVIDER);

    drawBoard(PLAYER_LAYOUT, player);
    if (!player.game_over) drawCurrentPiece(PLAYER_LAYOUT, player);
    drawHold(PLAYER_LAYOUT, player);
    drawPanel(PLAYER_LAYOUT, player);
    if (player.game_over) drawGameOverOverlay(PLAYER_LAYOUT, "Press R to restart");

    drawBoard(AI_LAYOUT, ai);
    if (!ai.game_over) drawCurrentPiece(AI_LAYOUT, ai);
    drawHold(AI_LAYOUT, ai);
    drawPanel(AI_LAYOUT, ai);
    if (ai.game_over) drawGameOverOverlay(AI_LAYOUT, "Restarting...");
}
