//AI strength and speed across search configurations, on fixed seeds.
//  zig build bench                          trained weights
//  zig build bench -- --weights other.json  compare a different weights file
//  zig build bench -- --games 50 --moves 1000
const std = @import("std");
const game_mod = @import("engine/game.zig");
const expectimax = @import("ai/expectimax.zig");
const heuristics = @import("ai/heuristics.zig");

const GameState = game_mod.GameState;
const Weights = game_mod.Weights;

const Config = struct {
    name: []const u8,
    search: expectimax.SearchOptions,
};

const CONFIGS = [_]Config{
    .{ .name = "greedy (1 piece)", .search = .{ .depth = 1, .beam_width = 0, .use_hold = false } },
    .{ .name = "2 pieces", .search = .{ .depth = 2, .beam_width = 8, .use_hold = false } },
    .{ .name = "1 piece + hold", .search = .{ .depth = 1, .beam_width = 0 } },
    .{ .name = "2 pieces + hold", .search = .{ .depth = 2, .beam_width = 8 } },
    .{ .name = "3 pieces + hold (Hard)", .search = .{ .depth = 3, .beam_width = 8 } },
};

const GameStats = struct {
    lines: u32 = 0,
    score: u32 = 0,
    moves: u64 = 0,
    survived: bool = false,
    nanos: u64 = 0,
    nodes: u64 = 0,
};

const Job = struct {
    weights: Weights,
    search: expectimax.SearchOptions,
    max_moves: usize,
    results: []GameStats,
    next: std.atomic.Value(usize) = .init(0),

    fn worker(job: *Job) void {
        while (true) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.results.len) return;
            job.results[i] = playGame(job.weights, job.search, job.max_moves, 1000 + i);
        }
    }
};

fn playGame(weights: Weights, search: expectimax.SearchOptions, max_moves: usize, seed: u64) GameStats {
    var state = GameState.init(seed);
    var stats = GameStats{};
    expectimax.node_count = 0;
    var timer = std.time.Timer.start() catch unreachable;
    while (!state.game_over and stats.moves < max_moves) : (stats.moves += 1) {
        const move = expectimax.bestMoveWithOptions(&state, &weights, search) orelse break;
        state.applyMove(&move);
    }
    stats.nanos = timer.read();
    stats.nodes = expectimax.node_count;
    stats.lines = state.lines_cleared;
    stats.score = state.score;
    stats.survived = !state.game_over;
    return stats;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var weights = heuristics.trainedWeights();
    var weights_name: []const u8 = "data/weights.json (embedded)";
    var games: usize = 30;
    var max_moves: usize = 1000;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--weights")) {
            weights = try heuristics.loadWeightsFile(args[i + 1]);
            weights_name = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--games")) {
            games = try std.fmt.parseInt(usize, args[i + 1], 10);
        } else if (std.mem.eql(u8, args[i], "--moves")) {
            max_moves = try std.fmt.parseInt(usize, args[i + 1], 10);
        } else {
            return error.InvalidArgument;
        }
    }

    const results = try allocator.alloc(GameStats, games);
    defer allocator.free(results);
    const thread_count = std.Thread.getCpuCount() catch 4;

    std.debug.print("weights: {s}\n{d} games per config (seeds 1000..{d}), capped at {d} pieces\n\n", .{ weights_name, games, 1000 + games - 1, max_moves });
    std.debug.print("| Search | Mean lines | Mean score | Survived cap | ms / move | Nodes / s |\n", .{});
    std.debug.print("|---|---:|---:|---:|---:|---:|\n", .{});

    for (CONFIGS) |config| {
        var job = Job{ .weights = weights, .search = config.search, .max_moves = max_moves, .results = results };
        var threads: [64]std.Thread = undefined;
        var spawned: usize = 0;
        while (spawned + 1 < @min(thread_count, threads.len)) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, Job.worker, .{&job}) catch break;
        }
        job.worker();
        for (threads[0..spawned]) |t| t.join();

        var lines: u64 = 0;
        var score: u64 = 0;
        var moves: u64 = 0;
        var nanos: u64 = 0;
        var nodes: u64 = 0;
        var survived: usize = 0;
        for (results) |r| {
            lines += r.lines;
            score += r.score;
            moves += r.moves;
            nanos += r.nanos;
            nodes += r.nodes;
            if (r.survived) survived += 1;
        }
        const g: f64 = @floatFromInt(games);
        const ms_per_move = @as(f64, @floatFromInt(nanos)) / 1e6 / @as(f64, @floatFromInt(@max(moves, 1)));
        const nodes_per_sec = @as(f64, @floatFromInt(nodes)) / (@as(f64, @floatFromInt(@max(nanos, 1))) / 1e9);
        std.debug.print("| {s} | {d:.1} | {d:.0} | {d}/{d} | {d:.2} | {d:.0}k |\n", .{
            config.name,
            @as(f64, @floatFromInt(lines)) / g,
            @as(f64, @floatFromInt(score)) / g,
            survived,
            games,
            ms_per_move,
            nodes_per_sec / 1000.0,
        });
    }
}
