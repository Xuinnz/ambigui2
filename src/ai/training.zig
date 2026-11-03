//Shared pieces of the offline weight trainers (genetic.zig, cmaes.zig):
//self-play evaluation across threads, validation and result files.
const std = @import("std");
const game_mod = @import("../engine/game.zig");
const expectimax = @import("expectimax.zig");

const GameState = game_mod.GameState;
const Weights = game_mod.Weights;

pub const EvalConfig = struct {
    games_per_candidate: usize, //number of independent games played per candidate
    max_moves: usize, //upper limit of moves permitted per game
    thread_count: usize, //number of threads for concurrent games
    search: expectimax.SearchOptions,
};

pub const GameResult = struct {
    score: u32,
    lines: u32,
};

//simulates one game and returns how the agent did
pub fn playGame(weights: Weights, config: EvalConfig, seed: u64) GameResult {
    var state = GameState.init(seed);
    var moves: usize = 0;
    while (!state.game_over and moves < config.max_moves) : (moves += 1) {
        const move = expectimax.bestMoveWithOptions(&state, &weights, config.search) orelse break;
        state.applyMove(&move);
    }
    return .{ .score = state.score, .lines = state.lines_cleared };
}

/// Fitness is the mean game score. Score (not lines) keeps rewarding agents
/// that clear multiple lines at once after they survive until the move cap.
pub fn evaluateCandidate(weights: Weights, config: EvalConfig, seeds: []const u64) f32 {
    var total: u64 = 0;
    for (seeds) |seed| total += playGame(weights, config, seed).score;
    return @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(seeds.len));
}

const EvalJob = struct {
    candidates: []const Weights,
    fitness: []f32,
    seeds: []const u64,
    config: EvalConfig,
    next: std.atomic.Value(usize) = .init(0),

    fn worker(job: *EvalJob) void {
        while (true) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.candidates.len) return;
            job.fitness[i] = evaluateCandidate(job.candidates[i], job.config, job.seeds);
        }
    }
};

const MAX_THREADS: usize = 64;

/// Evaluates every candidate on the same seeds (common random numbers, so
/// differences come from the weights, not from luckier piece sequences).
/// Threads pull candidates from a shared counter, so slow games do not leave
/// other threads idle.
pub fn evaluateAll(candidates: []const Weights, fitness: []f32, seeds: []const u64, config: EvalConfig) void {
    std.debug.assert(candidates.len == fitness.len);
    var job = EvalJob{ .candidates = candidates, .fitness = fitness, .seeds = seeds, .config = config };

    const wanted = std.math.clamp(config.thread_count, 1, MAX_THREADS);
    var threads: [MAX_THREADS]std.Thread = undefined;
    var spawned: usize = 0;
    // The calling thread is one of the workers.
    while (spawned + 1 < wanted) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, EvalJob.worker, .{&job}) catch break;
    }
    job.worker();
    for (threads[0..spawned]) |thread| thread.join();
}

pub fn fillSeeds(seeds: []u64, random: std.Random) void {
    for (seeds) |*seed| seed.* = random.int(u64);
}

/// Picks the strongest of `finalists` on a larger set of fixed seeds that were
/// never used during training. A single lucky generation cannot win this way.
pub fn validate(allocator: std.mem.Allocator, finalists: []const Weights, config: EvalConfig, games: usize) !struct { weights: Weights, fitness: f32 } {
    std.debug.assert(finalists.len > 0);
    const seeds = try allocator.alloc(u64, games);
    defer allocator.free(seeds);
    var rng = std.Random.Xoshiro256.init(0x5EED_0F_7E57);
    fillSeeds(seeds, rng.random());

    const fitness = try allocator.alloc(f32, finalists.len);
    defer allocator.free(fitness);
    evaluateAll(finalists, fitness, seeds, config);

    var best: usize = 0;
    for (fitness, 0..) |f, i| {
        std.debug.print("  finalist {d}: validation fitness {d:.1}\n", .{ i, f });
        if (f > fitness[best]) best = i;
    }
    return .{ .weights = finalists[best], .fitness = fitness[best] };
}

/// Per-generation log, written as CSV so it can be plotted (tools/plot_history.py).
pub const History = struct {
    file: std.fs.File,

    pub fn create(path: []const u8) !History {
        if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        var history = History{ .file = file };
        var header: [256]u8 = undefined;
        var len: usize = 0;
        len += (try std.fmt.bufPrint(header[len..], "generation,best_fitness,mean_fitness", .{})).len;
        inline for (@typeInfo(Weights).@"struct".fields) |field| {
            len += (try std.fmt.bufPrint(header[len..], ",{s}", .{field.name})).len;
        }
        len += (try std.fmt.bufPrint(header[len..], "\n", .{})).len;
        try history.file.writeAll(header[0..len]);
        return history;
    }

    pub fn record(self: *History, generation: usize, best: f32, mean: f32, best_weights: Weights) !void {
        var line: [512]u8 = undefined;
        var len: usize = 0;
        len += (try std.fmt.bufPrint(line[len..], "{d},{d:.2},{d:.2}", .{ generation, best, mean })).len;
        for (best_weights.toArray()) |w| {
            len += (try std.fmt.bufPrint(line[len..], ",{d:.4}", .{w})).len;
        }
        len += (try std.fmt.bufPrint(line[len..], "\n", .{})).len;
        try self.file.writeAll(line[0..len]);

        std.debug.print("gen {d} best {d:.1} mean {d:.1}\n", .{ generation, best, mean });
    }

    pub fn close(self: *History) void {
        self.file.close();
    }
};

pub fn writeWeightsJson(path: []const u8, weights: Weights) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    try std.json.Stringify.value(weights, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

test "evaluateAll matches serial evaluation" {
    const heuristics = @import("heuristics.zig");
    const candidates = [_]Weights{ heuristics.DEFAULT_WEIGHTS, heuristics.trainedWeights(), heuristics.DEFAULT_WEIGHTS };
    var fitness: [candidates.len]f32 = undefined;
    const seeds = [_]u64{ 1, 2 };
    const config = EvalConfig{
        .games_per_candidate = seeds.len,
        .max_moves = 30,
        .thread_count = 3,
        .search = .{ .depth = 1, .beam_width = 0 },
    };
    evaluateAll(&candidates, &fitness, &seeds, config);
    for (candidates, fitness) |w, f| {
        try std.testing.expectEqual(evaluateCandidate(w, config, &seeds), f);
    }
}
