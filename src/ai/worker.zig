const std = @import("std");
const game_mod = @import("../engine/game.zig");
const expectimax = @import("expectimax.zig");

const GameState = game_mod.GameState;
const Move = game_mod.Move;

/// Runs expectimax on a background thread so the renderer never blocks.
///
/// Every posted state gets a new generation number. A search result is only
/// published if no newer state was posted while it ran, so `poll` can never
/// return a move computed for an outdated board.
pub const AiWorker = struct {
    mutex: std.Thread.Mutex = .{},
    work_ready: std.Thread.Condition = .{},

    // Main thread writes
    input: GameState = undefined,
    has_input: bool = false,
    generation: u64 = 0,
    shutdown: bool = false,

    // AI thread writes
    output: ?Move = null,
    has_output: bool = false,

    options: expectimax.SearchOptions,
    weights: game_mod.Weights,

    pub fn init(options: expectimax.SearchOptions, weights: game_mod.Weights) AiWorker {
        return .{
            .options = options,
            .weights = weights,
        };
    }

    // Main thread: update the difficulty settings dynamically
    pub fn reconfigure(self: *AiWorker, options: expectimax.SearchOptions, weights: game_mod.Weights) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.options = options;
        self.weights = weights;
    }

    // Main thread: send a state for the AI to evaluate. Supersedes any search in flight.
    pub fn post(self: *AiWorker, state: *const GameState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.input = state.*; // value copy — AI works on its own snapshot
        self.has_input = true;
        self.has_output = false;
        self.generation += 1;
        self.work_ready.signal();
    }

    // Main thread: check if a result is ready.
    // null = still thinking; ?Move null = the AI has no legal move.
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
        self.work_ready.signal();
    }
};

pub fn aiThreadEntry(worker: *AiWorker) void {
    while (true) {
        worker.mutex.lock();
        while (!worker.has_input and !worker.shutdown) {
            worker.work_ready.wait(&worker.mutex);
        }
        if (worker.shutdown) {
            worker.mutex.unlock();
            return;
        }

        // Copy everything the search needs before unlocking, so a concurrent
        // `post()` or `reconfigure()` cannot change it mid-search.
        const snapshot = worker.input;
        const generation = worker.generation;
        const options = worker.options;
        const weights = worker.weights;
        worker.has_input = false;
        worker.mutex.unlock();

        // Heavy computation — no lock held here, renderer runs freely
        const move = expectimax.bestMoveWithOptions(&snapshot, &weights, options);

        worker.mutex.lock();
        // Drop the result if a newer state arrived while we were searching.
        if (worker.generation == generation) {
            worker.output = move;
            worker.has_output = true;
        }
        worker.mutex.unlock();
    }
}

test "a result for a superseded state is never delivered" {
    const heuristics = @import("heuristics.zig");
    var worker = AiWorker.init(.{ .depth = 1, .beam_width = 4 }, heuristics.DEFAULT_WEIGHTS);
    const thread = try std.Thread.spawn(.{}, aiThreadEntry, .{&worker});
    defer {
        worker.stop();
        thread.join();
    }

    var state = GameState.init(77);
    for (0..20) |_| {
        worker.post(&state);
        // Wait for the answer to the latest post.
        const move = while (true) {
            if (worker.poll()) |result| break result;
            std.Thread.sleep(std.time.ns_per_ms);
        };
        const expected = expectimax.bestMoveWithOptions(&state, &heuristics.DEFAULT_WEIGHTS, .{ .depth = 1, .beam_width = 4 });
        try std.testing.expectEqualDeep(expected, move);
        state.applyMove(&move.?);
        if (state.game_over) break;
    }
}
