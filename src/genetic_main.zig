//Headless weight trainer.
//  zig build train                     genetic algorithm (default)
//  zig build train -- --cmaes          CMA-ES
//  zig build train -- --smoke          tiny run to check that everything works
//  zig build train -- --out path.json  where to write the weights (default data/weights.json)
const std = @import("std");
const genetic = @import("ai/genetic.zig");
const cmaes = @import("ai/cmaes.zig");
const training = @import("ai/training.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var use_cmaes = false;
    var smoke = false;
    var out_path: []const u8 = "data/weights.json";
    var history_path: []const u8 = "data/training_history.csv";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--cmaes")) {
            use_cmaes = true;
        } else if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--history") and i + 1 < args.len) {
            i += 1;
            history_path = args[i];
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    var history = try training.History.create(history_path);
    defer history.close();

    const best = if (use_cmaes) blk: {
        var config = cmaes.defaultConfig();
        if (smoke) {
            config.lambda = 6;
            config.generations = 3;
            config.validation_games = 4;
            config.eval.games_per_candidate = 2;
            config.eval.max_moves = 200;
            config.eval.search = .{ .depth = 1, .beam_width = 3 };
        }
        break :blk try cmaes.runTrainer(allocator, config, &history);
    } else blk: {
        const config = if (smoke) genetic.smokeTestConfig() else genetic.defaultConfig();
        break :blk try genetic.runTrainer(allocator, config, &history);
    };

    try training.writeWeightsJson(out_path, best);
    std.debug.print("wrote {s} and {s}\n", .{ out_path, history_path });
}
