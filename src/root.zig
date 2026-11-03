test "include all module tests" {
    _ = @import("engine/board.zig");
    _ = @import("engine/bag.zig");
    _ = @import("engine/eval.zig");
    _ = @import("engine/game.zig");
    _ = @import("engine/kicks.zig");
    _ = @import("engine/physics.zig");
    _ = @import("engine/piece.zig");

    _ = @import("ai/agent.zig");
    _ = @import("ai/cmaes.zig");
    _ = @import("ai/expectimax.zig");
    _ = @import("ai/genetic.zig");
    _ = @import("ai/heuristics.zig");
    _ = @import("ai/training.zig");
    _ = @import("ai/worker.zig");

    _ = @import("ui/input.zig");
}
