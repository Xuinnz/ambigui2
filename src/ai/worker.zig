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
    weights: game_mod.Weights,

    pub fn init(depth: u32, beam_width: usize, weights: game_mod.Weights) AiWorker {
        return .{
            .depth = depth,
            .beam_width = beam_width,
            .weights = weights,
        };
    }

    // Main thread: update the difficulty settings dynamically
    pub fn reconfigure(self: *AiWorker, new_depth: u32, new_beam_width: usize, new_weights: game_mod.Weights) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.depth = new_depth;
        self.beam_width = new_beam_width;
        self.weights = new_weights;
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
        worker.mutex.lock();

        // 1. Check shutdown flag
        if (worker.shutdown) {
            worker.mutex.unlock();
            break;
        }

        // 2. Check for work
        if (!worker.has_input) {
            worker.mutex.unlock();
            std.Thread.sleep(1 * std.time.ns_per_ms); // poll every 1ms
            continue;
        }

        // 3. SECURE LOCAL COPIES
        // We MUST copy the configuration variables into the thread's local stack
        // before unlocking the mutex. This ensures that if the main thread calls
        // `reconfigure()` mid-search, it won't corrupt the current calculation.
        const snapshot = worker.input;
        const local_depth = worker.depth;
        const local_beam_width = worker.beam_width;
        const local_weights = worker.weights;

        worker.has_input = false;
        worker.mutex.unlock();

        // 4. Heavy computation — no lock held here, renderer runs freely
        const move = expectimax.bestMoveWithOptions(&snapshot, &local_weights, .{
            .depth = local_depth,
            .beam_width = local_beam_width,
        });

        // 5. Deliver result
        worker.mutex.lock();
        worker.output = move;
        worker.has_output = true;
        worker.mutex.unlock();
    }
}
