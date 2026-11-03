//Screen flow and per-frame game logic shared by the desktop and web frontends.
const std = @import("std");
const rl = @import("rl.zig").c;
const game_mod = @import("../engine/game.zig");
const agent = @import("../ai/agent.zig");
const renderer = @import("renderer.zig");
const input = @import("input.zig");

const GameState = game_mod.GameState;
const Move = game_mod.Move;

const AppState = enum {
    Landing,
    DifficultySelect,
    PlayingVsAI,
    PlayingSolo,
    BothGameOver,
};

/// `Ai` computes the opponent's moves without blocking the frame. It must provide:
///   configure(*Ai, agent.Profile) void
///   post(*Ai, *const GameState) void   start thinking about a position
///   poll(*Ai) ??Move                   null while thinking
///   update(*Ai) void                   called once per frame
pub fn App(comptime Ai: type) type {
    return struct {
        const Self = @This();

        app_state: AppState = .Landing,
        game_mode: renderer.GameMode = .VsAI,
        profile: agent.Profile,
        ai_driver: *Ai,
        player: GameState,
        ai: GameState,
        controller: input.Controller = .{},
        last_gravity: i64 = 0,
        last_ai_step: i64 = 0,
        /// Fixed seed for reproducible matches, or 0 for a new random seed each game.
        fixed_seed: u64,
        random_seed: *const fn () u64,

        pub fn init(ai_driver: *Ai, fixed_seed: u64, random_seed: *const fn () u64) Self {
            return .{
                .profile = agent.profileFor(.Medium),
                .ai_driver = ai_driver,
                .player = GameState.init(1),
                .ai = GameState.init(1),
                .fixed_seed = fixed_seed,
                .random_seed = random_seed,
            };
        }

        fn startGame(self: *Self, difficulty: agent.Difficulty, now: i64) void {
            self.profile = agent.profileFor(difficulty);
            // Player and AI get the same piece sequence, so the match is fair.
            const seed = if (self.fixed_seed != 0) self.fixed_seed else self.random_seed();
            self.player = GameState.init(seed);
            self.ai = GameState.init(seed);
            self.controller = .{};
            self.last_gravity = now;
            self.last_ai_step = now;

            self.ai_driver.configure(self.profile);
            self.ai_driver.post(&self.ai);

            self.app_state = switch (self.game_mode) {
                .VsAI => .PlayingVsAI,
                .Solo => .PlayingSolo,
            };
        }

        fn readKeys() input.Keys {
            return .{
                .left = rl.IsKeyDown(rl.KEY_LEFT),
                .right = rl.IsKeyDown(rl.KEY_RIGHT),
                .soft_drop = rl.IsKeyDown(rl.KEY_DOWN),
                .rotate_cw = rl.IsKeyDown(rl.KEY_UP) or rl.IsKeyDown(rl.KEY_X),
                .rotate_ccw = rl.IsKeyDown(rl.KEY_Z) or rl.IsKeyDown(rl.KEY_LEFT_CONTROL),
                .hold = rl.IsKeyDown(rl.KEY_C) or rl.IsKeyDown(rl.KEY_LEFT_SHIFT),
                .hard_drop = rl.IsKeyDown(rl.KEY_SPACE),
            };
        }

        fn updatePlayer(self: *Self, now: i64) void {
            const actions = self.controller.update(readKeys(), now);
            if (self.player.game_over) return;

            for (actions.slice()) |action| {
                switch (action) {
                    .left => self.player.tryMoveHorizontal(-1),
                    .right => self.player.tryMoveHorizontal(1),
                    .rotate_cw => self.player.tryRotateCW(),
                    .rotate_ccw => self.player.tryRotateCCW(),
                    .hold => self.player.tryHold(),
                    .hard_drop => self.player.hardDrop(),
                    .soft_drop => {
                        _ = self.player.tickGravity();
                        self.last_gravity = now;
                    },
                }
                if (self.player.game_over) return;
            }

            if (now - self.last_gravity >= self.player.gravityIntervalMs()) {
                _ = self.player.tickGravity();
                self.last_gravity = now;
            }
        }

        fn updateAi(self: *Self, now: i64) void {
            self.ai_driver.update();
            if (self.ai.game_over) return;
            if (now - self.last_ai_step < self.profile.step_ms) return;

            const result = self.ai_driver.poll() orelse return;
            self.last_ai_step = now;
            if (result) |move| {
                self.ai.applyMove(&move);
                if (!self.ai.game_over) self.ai_driver.post(&self.ai);
            } else {
                self.ai.game_over = true;
            }
        }

        pub fn frame(self: *Self, now: i64) void {
            switch (self.app_state) {
                .Landing => {
                    if (renderer.drawLandingFrame()) |mode| {
                        self.game_mode = mode;
                        self.app_state = .DifficultySelect;
                    }
                },

                .DifficultySelect => {
                    if (renderer.drawDifficultyFrame()) |difficulty| self.startGame(difficulty, now);
                },

                .PlayingVsAI => {
                    self.updatePlayer(now);
                    self.updateAi(now);
                    // Wait for BOTH to die before showing winner
                    if (self.player.game_over and self.ai.game_over) self.app_state = .BothGameOver;
                    renderer.drawVsAiFrame(&self.player, &self.ai, false);
                },

                .PlayingSolo => {
                    self.updatePlayer(now);
                    if (self.player.game_over and rl.IsKeyPressed(rl.KEY_R)) self.app_state = .Landing;
                    renderer.drawSoloFrame(&self.player);
                },

                .BothGameOver => {
                    renderer.drawVsAiFrame(&self.player, &self.ai, true);
                    if (rl.IsKeyPressed(rl.KEY_R)) self.app_state = .Landing;
                },
            }
        }
    };
}

/// Single-threaded AI driver: runs a few root candidates of the search per
/// frame until a time budget is used up, so the frame rate stays smooth.
pub fn IncrementalAi(comptime now_ms: fn () f64) type {
    return struct {
        const Self = @This();

        /// Milliseconds of search per frame (out of ~16.7ms at 60fps).
        budget_ms: f64 = 6.0,
        profile: agent.Profile = agent.profileFor(.Medium),
        search: agent.Search = undefined,
        searching: bool = false,
        result: ?Move = null,
        has_result: bool = false,

        pub fn configure(self: *Self, profile: agent.Profile) void {
            self.profile = profile;
        }

        pub fn post(self: *Self, state: *const GameState) void {
            self.search.init(state, &self.profile.weights, self.profile.search);
            self.searching = true;
            self.has_result = false;
        }

        pub fn update(self: *Self) void {
            if (!self.searching) return;
            const deadline = now_ms() + self.budget_ms;
            // One root candidate per step keeps the overshoot past the budget small.
            while (now_ms() < deadline) {
                if (self.search.step(1)) {
                    self.result = self.search.result();
                    self.has_result = true;
                    self.searching = false;
                    return;
                }
            }
        }

        pub fn poll(self: *Self) ??Move {
            if (!self.has_result) return null;
            self.has_result = false;
            return self.result;
        }
    };
}
