// src/ai/ai_worker.zig
const std = @import("std");
const game_mod = @import("../engine/game.zig");
const expectimax = @import("expectimax.zig");
const heuristics = @import("heuristics.zig");

const GameState = game_mod.GameState;
const Move = game_mod.Move;

pub const AiWorker = struct {
    mutex: std.Thread.Mutex = .{},

    // Main thread writes
    input: GameState = undefined,
    has_input: bool = false,
    shutdown: bool = false,

    // AI thread writes
    output: ?Move = null,
    has_output: bool = false,

    depth: u32,
    beam_width: usize,

    pub fn init(depth: u32, beam_width: usize) AiWorker {
        return .{ .depth = depth, .beam_width = beam_width };
    }

    // Main thread: send a state for the AI to evaluate
    pub fn post(self: *AiWorker, state: *const GameState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.input = state.*; // value copy — AI works on its own snapshot
        self.has_input = true;
        self.has_output = false;
    }

    // Main thread: check if a result is ready.
    // Returns null        → still computing, don't block
    // Returns ?Move       → result ready (null inner = no valid move = game over)
    pub fn poll(self: *AiWorker) ??Move {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.has_output) return null;
        const result = self.output;
        self.has_output = false;
        return result;
    }

    pub fn stop(self: *AiWorker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutdown = true;
    }
};

pub fn aiThreadEntry(worker: *AiWorker) void {
    while (true) {
        // Check for work
        worker.mutex.lock();
        if (worker.shutdown) {
            worker.mutex.unlock();
            break;
        }
        if (!worker.has_input) {
            worker.mutex.unlock();
            std.Thread.sleep(1 * std.time.ns_per_ms); // poll every 1ms
            continue;
        }
        const snapshot = worker.input; // local copy
        worker.has_input = false;
        const depth = worker.depth;
        const beam_width = worker.beam_width;
        worker.mutex.unlock();

        // Heavy computation — no lock held here, renderer runs freely
        const move = expectimax.bestMoveWithOptions(&snapshot, &heuristics.TRAINED_WEIGHTS, .{
            .depth = depth,
            .beam_width = beam_width,
        });

        worker.mutex.lock();
        worker.output = move;
        worker.has_output = true;
        worker.mutex.unlock();
    }
}
