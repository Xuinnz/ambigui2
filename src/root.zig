test "include all module tests" {
    _ = @import("engine/board.zig");
    _ = @import("engine/game.zig");
    _ = @import("engine/physics.zig");
    _ = @import("engine/piece.zig");
    _ = @import("engine/rng.zig");

    _ = @import("ai/agent.zig");
    _ = @import("ai/expectimax.zig");
    _ = @import("ai/genetic.zig");
    _ = @import("ai/heuristics.zig");

    _ = @import("ui/input.zig");
    _ = @import("ui/terminal.zig");

    _ = @import("main.zig");
}
