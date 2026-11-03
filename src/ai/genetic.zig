//Genetic algorithm that evolves the heuristic weights through self-play.
const std = @import("std");
const game_mod = @import("../engine/game.zig");
const heuristics = @import("heuristics.zig");
const training = @import("training.zig");

const Weights = game_mod.Weights;

pub const TrainerConfig = struct {
    population_size: usize, //total number of AI agents in 1 generation
    generations: usize, //total number of iterations before training terminates
    tournament_size: usize, //number of random candidates chosen to compete against each other
    elite_count: usize, //number of top performing agents preserved directly for next generation
    mutation_rate: f32, //probability that child agent's heuristic weights will undergo mutation
    mutation_scale: f32, //range of random values adjusted to the mutated agent
    weight_min: f32, //minimum value of weight
    weight_max: f32, //maximum value of weight
    validation_games: usize, //held-out games used to pick the final weights
    seed: u64, //masterseed number generator
    eval: training.EvalConfig,
};

const Candidate = struct {
    weights: Weights,
    fitness: f32,
};

pub fn defaultConfig() TrainerConfig {
    return .{
        .population_size = 100,
        .generations = 100,
        .tournament_size = 6,
        .elite_count = 4,
        .mutation_rate = 0.3,
        .mutation_scale = 0.5,
        .weight_min = -15.0,
        .weight_max = 0.0,
        .validation_games = 40,
        .seed = 0xA5A5_1EE7_F00D_BA5E,
        .eval = .{
            .games_per_candidate = 10,
            .max_moves = 2000,
            .thread_count = std.Thread.getCpuCount() catch 4,
            .search = .{ .depth = 2, .beam_width = 10 },
        },
    };
}

pub fn smokeTestConfig() TrainerConfig {
    var config = defaultConfig();
    config.population_size = 8;
    config.generations = 2;
    config.tournament_size = 2;
    config.elite_count = 1;
    config.validation_games = 4;
    config.eval.games_per_candidate = 2;
    config.eval.max_moves = 200;
    config.eval.search = .{ .depth = 1, .beam_width = 3 };
    return config;
}

//evolutionary iteration. returns the validated best weights.
pub fn runTrainer(allocator: std.mem.Allocator, config: TrainerConfig, history: ?*training.History) !Weights {
    std.debug.assert(config.population_size > 0);
    std.debug.assert(config.tournament_size > 0);
    std.debug.assert(config.eval.games_per_candidate > 0);
    std.debug.assert(config.elite_count <= config.population_size);

    var population = try allocator.alloc(Candidate, config.population_size);
    defer allocator.free(population);
    var next_population = try allocator.alloc(Candidate, config.population_size);
    defer allocator.free(next_population);
    const weights = try allocator.alloc(Weights, config.population_size);
    defer allocator.free(weights);
    const fitness = try allocator.alloc(f32, config.population_size);
    defer allocator.free(fitness);
    const seeds = try allocator.alloc(u64, config.eval.games_per_candidate);
    defer allocator.free(seeds);

    //the best candidate of every generation, validated at the end
    var hall_of_fame: std.ArrayList(Weights) = .empty;
    defer hall_of_fame.deinit(allocator);

    var rng = std.Random.Xoshiro256.init(config.seed);
    const random = rng.random();

    //populate generation 0 with baseline heuristic weights and random weights
    initPopulation(population, random, config);

    var gen: usize = 0;
    //starting point of the evolutionary loop
    while (gen < config.generations) : (gen += 1) {
        //fresh seeds every generation, shared by all agents
        training.fillSeeds(seeds, random);

        //every candidate (elites included) is re-evaluated on the new seeds
        for (population, weights) |candidate, *w| w.* = candidate.weights;
        training.evaluateAll(weights, fitness, seeds, config.eval);
        var total_fitness: f32 = 0.0;
        for (population, fitness) |*candidate, f| {
            candidate.fitness = f;
            total_fitness += f;
        }

        //sort population descending
        std.mem.sort(Candidate, population, {}, struct {
            fn better(_: void, a: Candidate, b: Candidate) bool {
                return a.fitness > b.fitness;
            }
        }.better);
        try hall_of_fame.append(allocator, population[0].weights);

        const avg = total_fitness / @as(f32, @floatFromInt(population.len));
        if (history) |h| try h.record(gen, population[0].fitness, avg, population[0].weights);

        //ELITISM: we copy the top performing agents directly to the next generation
        //this is to preserve the top performing weights
        var i: usize = 0;
        while (i < config.elite_count) : (i += 1) {
            next_population[i] = population[i];
        }

        //we fill the remaining population slots with tournament mating selection
        while (i < population.len) : (i += 1) {
            const parent_a = tournamentSelect(population, random, config.tournament_size);
            const parent_b = tournamentSelect(population, random, config.tournament_size);
            //we combine the parent weights
            var child_weights = crossover(parent_a.weights, parent_b.weights, random);
            //inject a random scale of mutation
            mutate(&child_weights, random, config);
            next_population[i] = .{ .weights = child_weights, .fitness = 0.0 };
        }

        std.mem.swap([]Candidate, &population, &next_population);
    }

    //finalists: recent generation winners plus the current elites
    var finalists: std.ArrayList(Weights) = .empty;
    defer finalists.deinit(allocator);
    const recent = hall_of_fame.items[hall_of_fame.items.len -| 8..];
    try finalists.appendSlice(allocator, recent);
    for (population[0..config.elite_count]) |elite| try finalists.append(allocator, elite.weights);

    std.debug.print("validating {d} finalists on {d} held-out games\n", .{ finalists.items.len, config.validation_games });
    const winner = try training.validate(allocator, finalists.items, config.eval, config.validation_games);
    std.debug.print("FINAL validation fitness {d:.1}\n", .{winner.fitness});
    return winner.weights;
}

//we initialize the population
fn initPopulation(population: []Candidate, random: std.Random, config: TrainerConfig) void {
    if (population.len == 0) return;
    population[0] = .{ .weights = heuristics.DEFAULT_WEIGHTS, .fitness = 0.0 };
    for (population[1..]) |*candidate| {
        candidate.* = .{ .weights = randomWeights(random, config), .fitness = 0.0 };
    }
}

//we use this to randomly pick a "good genes" parent
fn tournamentSelect(population: []const Candidate, random: std.Random, tournament_size: usize) Candidate {
    //randomly pick a candidate from the population
    var best = population[random.intRangeLessThan(usize, 0, population.len)];

    var i: usize = 1;
    while (i < tournament_size) : (i += 1) {
        //pick a contender at random and keep the fitter one
        const contender = population[random.intRangeLessThan(usize, 0, population.len)];
        if (contender.fitness > best.fitness) {
            best = contender;
        }
    }
    //we return the winner to be the parent
    return best;
}

//how parents will be bred together: each weight comes from one parent at random
fn crossover(a: Weights, b: Weights, random: std.Random) Weights {
    const wa = a.toArray();
    const wb = b.toArray();
    var child: [Weights.COUNT]f32 = undefined;
    for (&child, wa, wb) |*c, x, y| c.* = if (random.boolean()) x else y;
    return Weights.fromArray(child);
}

//mutated weights
fn mutate(weights: *Weights, random: std.Random, config: TrainerConfig) void {
    var values = weights.toArray();
    for (&values) |*value| {
        if (random.float(f32) < config.mutation_rate) {
            value.* += (random.float(f32) * 2.0 - 1.0) * config.mutation_scale;
        }
        value.* = std.math.clamp(value.*, config.weight_min, config.weight_max);
    }
    weights.* = Weights.fromArray(values);
}

//random weight for initializing population
fn randomWeights(random: std.Random, config: TrainerConfig) Weights {
    var values: [Weights.COUNT]f32 = undefined;
    for (&values) |*value| {
        value.* = config.weight_min + (config.weight_max - config.weight_min) * random.float(f32);
    }
    return Weights.fromArray(values);
}

test "genetic smoke run" {
    var config = smokeTestConfig();
    config.population_size = 4;
    config.generations = 1;
    config.eval.max_moves = 10;
    config.eval.thread_count = 2;
    config.validation_games = 2;
    _ = try runTrainer(std.testing.allocator, config, null);
}
