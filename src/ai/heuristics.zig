const std = @import("std");
const game_mod = @import("../engine/game.zig");
const GameState = game_mod.GameState;
const Weights = game_mod.Weights;

/// data/weights.json, embedded at build time (see build.zig) so the game does
/// not depend on the working directory and also works in the browser.
const trained_weights_json: []const u8 = @import("trained_weights").json;

pub const DEFAULT_WEIGHTS = Weights{
    .w_aggregate = -0.5,
    .w_holes = -7.9,
    .w_bumpiness = -1.8,
    .w_wells = -3.4,
    .w_row_transitions = -3.4,
    .w_col_transitions = -5.2,
};

pub fn parseWeights(json: []const u8) !Weights {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    return std.json.parseFromSliceLeaky(Weights, fba.allocator(), json, .{});
}

/// The weights produced by the last `zig build train` run, parsed at compile
/// time: a malformed data/weights.json is a build error, not a runtime crash.
pub const TRAINED_WEIGHTS: Weights = blk: {
    @setEvalBranchQuota(100_000);
    break :blk parseWeights(trained_weights_json) catch |err|
        @compileError("data/weights.json is invalid: " ++ @errorName(err));
};

pub fn trainedWeights() Weights {
    return TRAINED_WEIGHTS;
}

/// Reads weights from a JSON file at runtime, e.g. to compare training runs.
pub fn loadWeightsFile(path: []const u8) !Weights {
    var buffer: [4096]u8 = undefined;
    const data = try std.fs.cwd().readFile(path, &buffer);
    return parseWeights(data);
}

pub fn score(state: *const GameState, weights: *const Weights) f32 {
    return state.evaluate(weights);
}

test "embedded weights parse" {
    _ = trainedWeights();
}
