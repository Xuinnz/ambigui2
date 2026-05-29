const std = @import("std");
const game_mod = @import("../engine/game.zig");
const expectimax = @import("expectimax.zig");
const heuristics = @import("heuristics.zig");

const GameState = game_mod.GameState;
const Weights = game_mod.Weights;

pub const TrainerConfig = struct {
    population_size: usize,
    generations: usize,
    games_per_candidate: usize,
    tournament_size: usize,
    elite_count: usize,
    max_moves: usize,
    thread_count: usize,
    mutation_rate: f32,
    mutation_scale: f32,
    weight_min: f32,
    weight_max: f32,
    search_depth: u32,
    search_beam_width: usize,
    seed: u64,
};

const Candidate = struct {
    weights: Weights,
    fitness: f32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = defaultConfig();
    const best = try runTrainer(allocator, config);
    try writeWeightsJson("data/weights.json", best);
}

// fn defaultConfig() TrainerConfig {
//     return .{
//         .population_size = 100,
//         .generations = 100,
//         .games_per_candidate = 5,
//         .tournament_size = 4,
//         .elite_count = 4,
//         .max_moves = 2000,
//         .thread_count = 1,
//         .mutation_rate = 0.2,
//         .mutation_scale = 0.5,
//         .weight_min = -5.0,
//         .weight_max = 0.0,
//         .search_depth = 3,
//         .search_beam_width = 5,
//         .seed = 0xA5A5_1EE7_F00D_BA5E,
//     };
// }
fn defaultConfig() TrainerConfig {
    return .{
        .population_size = 8,
        .generations = 2,
        .games_per_candidate = 2,
        .tournament_size = 2,
        .elite_count = 1,
        .max_moves = 200,
        .thread_count = 1,
        .mutation_rate = 0.2,
        .mutation_scale = 0.5,
        .weight_min = -5.0,
        .weight_max = 0.0,
        .search_depth = 2,
        .search_beam_width = 3,
        .seed = 0x1234_5678_9ABC_DEF0,
    };
}

pub fn runTrainer(allocator: std.mem.Allocator, config: TrainerConfig) !Weights {
    std.debug.assert(config.population_size > 0);
    std.debug.assert(config.tournament_size > 0);
    std.debug.assert(config.games_per_candidate > 0);
    std.debug.assert(config.elite_count <= config.population_size);
    std.debug.assert(config.thread_count > 0);

    var population = try allocator.alloc(Candidate, config.population_size);
    defer allocator.free(population);
    var next_population = try allocator.alloc(Candidate, config.population_size);
    defer allocator.free(next_population);

    const seeds = try allocator.alloc(u64, config.games_per_candidate);
    defer allocator.free(seeds);

    var rng = std.Random.Xoshiro256.init(config.seed);
    var random = rng.random();

    initPopulation(population, &random, config);

    var best_overall = population[0];
    best_overall.fitness = -1.0;

    var gen: usize = 0;
    while (gen < config.generations) : (gen += 1) {
        fillSeeds(seeds, &random);

        evaluatePopulation(population, config, seeds);

        var total_fitness: f32 = 0.0;
        for (population) |candidate| {
            total_fitness += candidate.fitness;
            if (candidate.fitness > best_overall.fitness) {
                best_overall = candidate;
            }
        }

        sortCandidates(population);
        const avg = total_fitness / @as(f32, @floatFromInt(population.len));
        std.debug.print(
            "gen {d} best {d:.2} avg {d:.2} weights({d:.3},{d:.3},{d:.3})\n",
            .{
                gen,
                population[0].fitness,
                avg,
                population[0].weights.w_aggregate,
                population[0].weights.w_holes,
                population[0].weights.w_bumpiness,
            },
        );

        var i: usize = 0;
        while (i < config.elite_count) : (i += 1) {
            next_population[i] = population[i];
        }

        while (i < population.len) : (i += 1) {
            const parent_a = tournamentSelect(population, &random, config.tournament_size);
            const parent_b = tournamentSelect(population, &random, config.tournament_size);
            var child_weights = crossover(parent_a.weights, parent_b.weights, &random);
            mutate(&child_weights, &random, config);
            next_population[i] = .{ .weights = child_weights, .fitness = 0.0 };
        }

        std.mem.swap([]Candidate, &population, &next_population);
    }

    return best_overall.weights;
}

fn initPopulation(population: []Candidate, random: *std.Random, config: TrainerConfig) void {
    if (population.len == 0) return;
    population[0] = .{ .weights = heuristics.DEFAULT_WEIGHTS, .fitness = 0.0 };
    var i: usize = 1;
    while (i < population.len) : (i += 1) {
        population[i] = .{ .weights = randomWeights(random, config), .fitness = 0.0 };
    }
}

fn fillSeeds(seeds: []u64, random: *std.Random) void {
    for (seeds) |*seed| {
        seed.* = random.int(u64);
    }
}

fn evaluatePopulation(population: []Candidate, config: TrainerConfig, seeds: []const u64) void {
    const threads = if (config.thread_count == 0) 1 else config.thread_count;
    const chunk = (population.len + threads - 1) / threads;

    var start: usize = 0;
    while (start < population.len) : (start += chunk) {
        const end = @min(start + chunk, population.len);
        evaluateRange(population, config, seeds, start, end);
    }
}

fn evaluateRange(population: []Candidate, config: TrainerConfig, seeds: []const u64, start: usize, end: usize) void {
    var i: usize = start;
    while (i < end) : (i += 1) {
        population[i].fitness = evaluateCandidate(population[i].weights, config, seeds);
    }
}

fn evaluateCandidate(weights: Weights, config: TrainerConfig, seeds: []const u64) f32 {
    expectimax.resetTranspositionTable();
    var total: u64 = 0;
    for (seeds) |seed| {
        total += playGame(weights, config, seed);
    }
    return @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(seeds.len));
}

fn playGame(weights: Weights, config: TrainerConfig, seed: u64) u32 {
    var state = GameState.init(seed);
    var moves: usize = 0;
    while (!state.game_over and moves < config.max_moves) : (moves += 1) {
        const move = expectimax.bestMoveWithOptions(&state, &weights, .{
            .depth = config.search_depth,
            .beam_width = config.search_beam_width,
        });
        if (move) |chosen| {
            state.applyMove(&chosen);
        } else {
            state.game_over = true;
            state.top_out_reason = .block_out;
            break;
        }
    }
    return state.lines_cleared;
}

fn sortCandidates(population: []Candidate) void {
    var i: usize = 0;
    while (i < population.len) : (i += 1) {
        var best_idx = i;
        var j: usize = i + 1;
        while (j < population.len) : (j += 1) {
            if (population[j].fitness > population[best_idx].fitness) {
                best_idx = j;
            }
        }
        if (best_idx != i) {
            std.mem.swap(Candidate, &population[i], &population[best_idx]);
        }
    }
}

fn tournamentSelect(population: []Candidate, random: *std.Random, tournament_size: usize) Candidate {
    var best = population[random.intRangeLessThan(usize, 0, population.len)];
    var i: usize = 1;
    while (i < tournament_size) : (i += 1) {
        const contender = population[random.intRangeLessThan(usize, 0, population.len)];
        if (contender.fitness > best.fitness) {
            best = contender;
        }
    }
    return best;
}

fn crossover(a: Weights, b: Weights, random: *std.Random) Weights {
    return .{
        .w_aggregate = pickWeight(random, a.w_aggregate, b.w_aggregate),
        .w_holes = pickWeight(random, a.w_holes, b.w_holes),
        .w_bumpiness = pickWeight(random, a.w_bumpiness, b.w_bumpiness),
    };
}

fn pickWeight(random: *std.Random, a: f32, b: f32) f32 {
    return if (random.boolean()) a else b;
}

fn mutate(weights: *Weights, random: *std.Random, config: TrainerConfig) void {
    weights.w_aggregate = mutateWeight(weights.w_aggregate, random, config);
    weights.w_holes = mutateWeight(weights.w_holes, random, config);
    weights.w_bumpiness = mutateWeight(weights.w_bumpiness, random, config);
}

fn mutateWeight(value: f32, random: *std.Random, config: TrainerConfig) f32 {
    var out = value;
    if (random.float(f32) < config.mutation_rate) {
        const delta = (random.float(f32) * 2.0 - 1.0) * config.mutation_scale;
        out += delta;
    }
    return std.math.clamp(out, config.weight_min, config.weight_max);
}

fn randomWeights(random: *std.Random, config: TrainerConfig) Weights {
    return .{
        .w_aggregate = randomWeight(random, config),
        .w_holes = randomWeight(random, config),
        .w_bumpiness = randomWeight(random, config),
    };
}

fn randomWeight(random: *std.Random, config: TrainerConfig) f32 {
    const t = random.float(f32);
    return config.weight_min + (config.weight_max - config.weight_min) * t;
}

fn writeWeightsJson(path: []const u8, weights: Weights) !void {
    try std.fs.cwd().makePath("data");
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var out_buf: [512]u8 = undefined;
    var cursor: usize = 0;

    // write prefix
    const p1 = "{\"w_aggregate\": ";
    @memcpy(out_buf[cursor .. cursor + p1.len], p1);
    cursor += p1.len;

    var float_buf: [128]u8 = undefined;
    const s_agg = try std.fmt.float.render(float_buf[0..], weights.w_aggregate, .{});
    @memcpy(out_buf[cursor .. cursor + s_agg.len], s_agg);
    cursor += s_agg.len;

    const p2 = ", \"w_holes\": ";
    @memcpy(out_buf[cursor .. cursor + p2.len], p2);
    cursor += p2.len;

    const s_holes = try std.fmt.float.render(float_buf[0..], weights.w_holes, .{});
    @memcpy(out_buf[cursor .. cursor + s_holes.len], s_holes);
    cursor += s_holes.len;

    const p3 = ", \"w_bumpiness\": ";
    @memcpy(out_buf[cursor .. cursor + p3.len], p3);
    cursor += p3.len;

    const s_bump = try std.fmt.float.render(float_buf[0..], weights.w_bumpiness, .{});
    @memcpy(out_buf[cursor .. cursor + s_bump.len], s_bump);
    cursor += s_bump.len;

    const p4 = "}\n";
    @memcpy(out_buf[cursor .. cursor + p4.len], p4);
    cursor += p4.len;

    try file.writeAll(out_buf[0..cursor]);
}
