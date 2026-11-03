//CMA-ES (Covariance Matrix Adaptation Evolution Strategy) weight trainer.
//
//An alternative to genetic.zig. Instead of mixing parents it learns a
//multivariate normal distribution over the weights: the mean moves towards
//the best samples and the covariance learns which directions (and which
//weight correlations) improve fitness. For a handful of continuous
//parameters it typically needs far fewer evaluations than a GA.
//
//Follows N. Hansen, "The CMA Evolution Strategy: A Tutorial" (2016).
const std = @import("std");
const game_mod = @import("../engine/game.zig");
const heuristics = @import("heuristics.zig");
const training = @import("training.zig");

const Weights = game_mod.Weights;
const N = Weights.COUNT;
const Vec = [N]f64;
const Mat = [N][N]f64;

pub const CmaesConfig = struct {
    lambda: usize, //samples per generation
    generations: usize,
    initial_sigma: f64, //initial step size, in weight units
    weight_min: f32, //samples are clamped to this box before being played
    weight_max: f32,
    validation_games: usize,
    seed: u64,
    eval: training.EvalConfig,
};

pub fn defaultConfig() CmaesConfig {
    return .{
        .lambda = 24,
        .generations = 60,
        .initial_sigma = 2.0,
        .weight_min = -15.0,
        .weight_max = 0.0,
        .validation_games = 40,
        .seed = 0xC3A5_0001,
        .eval = .{
            .games_per_candidate = 10,
            .max_moves = 2000,
            .thread_count = std.Thread.getCpuCount() catch 4,
            .search = .{ .depth = 2, .beam_width = 10 },
        },
    };
}

const Sample = struct {
    y: Vec, //B*D*z: the step from the mean, before scaling by sigma
    fitness: f32,
};

pub fn runTrainer(allocator: std.mem.Allocator, config: CmaesConfig, history: ?*training.History) !Weights {
    std.debug.assert(config.lambda >= 4);
    const n: f64 = N;
    const lambda = config.lambda;
    const mu = lambda / 2;

    // Recombination weights: log-decreasing over the best mu samples.
    const rec_weights = try allocator.alloc(f64, mu);
    defer allocator.free(rec_weights);
    var weight_sum: f64 = 0;
    for (rec_weights, 0..) |*w, i| {
        w.* = @log(@as(f64, @floatFromInt(mu)) + 0.5) - @log(@as(f64, @floatFromInt(i + 1)));
        weight_sum += w.*;
    }
    var weight_sq_sum: f64 = 0;
    for (rec_weights) |*w| {
        w.* /= weight_sum;
        weight_sq_sum += w.* * w.*;
    }
    const mu_eff = 1.0 / weight_sq_sum;

    // Strategy parameters (Hansen's defaults).
    const c_sigma = (mu_eff + 2.0) / (n + mu_eff + 5.0);
    const d_sigma = 1.0 + 2.0 * @max(0.0, @sqrt((mu_eff - 1.0) / (n + 1.0)) - 1.0) + c_sigma;
    const c_c = (4.0 + mu_eff / n) / (n + 4.0 + 2.0 * mu_eff / n);
    const c_1 = 2.0 / ((n + 1.3) * (n + 1.3) + mu_eff);
    const c_mu = @min(1.0 - c_1, 2.0 * (mu_eff - 2.0 + 1.0 / mu_eff) / ((n + 2.0) * (n + 2.0) + mu_eff));
    const chi_n = @sqrt(n) * (1.0 - 1.0 / (4.0 * n) + 1.0 / (21.0 * n * n));

    var mean: Vec = undefined;
    for (heuristics.DEFAULT_WEIGHTS.toArray(), &mean) |w, *m| m.* = w;
    var sigma = config.initial_sigma;
    var cov: Mat = identity();
    var basis: Mat = identity(); // eigenvectors of cov (columns)
    var scales: Vec = @splat(1.0); // sqrt of the eigenvalues
    var p_sigma: Vec = @splat(0.0);
    var p_c: Vec = @splat(0.0);

    const samples = try allocator.alloc(Sample, lambda);
    defer allocator.free(samples);
    const candidates = try allocator.alloc(Weights, lambda);
    defer allocator.free(candidates);
    const fitness = try allocator.alloc(f32, lambda);
    defer allocator.free(fitness);
    const seeds = try allocator.alloc(u64, config.eval.games_per_candidate);
    defer allocator.free(seeds);

    var hall_of_fame: std.ArrayList(Weights) = .empty;
    defer hall_of_fame.deinit(allocator);

    var rng = std.Random.Xoshiro256.init(config.seed);
    const random = rng.random();

    var gen: usize = 0;
    while (gen < config.generations) : (gen += 1) {
        // Sample lambda candidates: x = mean + sigma * B * D * z.
        for (samples, candidates) |*sample, *candidate| {
            var z: Vec = undefined;
            for (&z) |*zi| zi.* = random.floatNorm(f64);
            var scaled: Vec = undefined;
            for (&scaled, z, scales) |*s, zi, d| s.* = d * zi;
            sample.y = matVec(&basis, &scaled);

            var x: Vec = undefined;
            for (&x, mean, sample.y) |*xi, m, yi| xi.* = m + sigma * yi;
            candidate.* = toWeights(x, config);
        }

        training.fillSeeds(seeds, random);
        training.evaluateAll(candidates, fitness, seeds, config.eval);

        var total: f32 = 0;
        for (samples, fitness) |*sample, f| {
            sample.fitness = f;
            total += f;
        }

        // Order samples best first, keeping candidates aligned with them.
        const order = try allocator.alloc(usize, lambda);
        defer allocator.free(order);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, samples, struct {
            fn better(s: []const Sample, a: usize, b: usize) bool {
                return s[a].fitness > s[b].fitness;
            }
        }.better);

        try hall_of_fame.append(allocator, candidates[order[0]]);
        if (history) |h| try h.record(gen, samples[order[0]].fitness, total / @as(f32, @floatFromInt(lambda)), candidates[order[0]]);

        // Weighted mean of the best mu steps.
        var y_w: Vec = @splat(0.0);
        for (rec_weights, 0..) |w, rank| {
            for (&y_w, samples[order[rank]].y) |*acc, yi| acc.* += w * yi;
        }
        for (&mean, y_w) |*m, yi| m.* += sigma * yi;

        // Step-size path uses C^(-1/2) * y_w = B * D^-1 * B^T * y_w.
        var bt_y = matTVec(&basis, &y_w);
        for (&bt_y, scales) |*v, d| v.* /= d;
        const c_inv_sqrt_y = matVec(&basis, &bt_y);
        const ps_factor = @sqrt(c_sigma * (2.0 - c_sigma) * mu_eff);
        for (&p_sigma, c_inv_sqrt_y) |*p, v| p.* = (1.0 - c_sigma) * p.* + ps_factor * v;

        const ps_norm = norm(&p_sigma);
        const gen_f: f64 = @floatFromInt(gen + 1);
        const h_sigma: f64 = if (ps_norm / @sqrt(1.0 - std.math.pow(f64, 1.0 - c_sigma, 2.0 * gen_f)) < (1.4 + 2.0 / (n + 1.0)) * chi_n) 1.0 else 0.0;

        const pc_factor = h_sigma * @sqrt(c_c * (2.0 - c_c) * mu_eff);
        for (&p_c, y_w) |*p, yi| p.* = (1.0 - c_c) * p.* + pc_factor * yi;

        // Covariance update: rank-one (evolution path) + rank-mu (best steps).
        const delta_h = (1.0 - h_sigma) * c_c * (2.0 - c_c);
        for (0..N) |i| {
            for (0..N) |j| {
                var rank_mu: f64 = 0;
                for (rec_weights, 0..) |w, rank| {
                    const y = &samples[order[rank]].y;
                    rank_mu += w * y[i] * y[j];
                }
                cov[i][j] = (1.0 - c_1 - c_mu) * cov[i][j] +
                    c_1 * (p_c[i] * p_c[j] + delta_h * cov[i][j]) +
                    c_mu * rank_mu;
            }
        }

        sigma *= @exp((c_sigma / d_sigma) * (ps_norm / chi_n - 1.0));

        // Re-derive B and D from the updated covariance.
        jacobiEigen(cov, &basis, &scales);
        for (&scales) |*s| s.* = @sqrt(@max(s.*, 1e-20));
    }

    var finalists: std.ArrayList(Weights) = .empty;
    defer finalists.deinit(allocator);
    try finalists.appendSlice(allocator, hall_of_fame.items[hall_of_fame.items.len -| 8..]);
    try finalists.append(allocator, toWeights(mean, config));

    std.debug.print("validating {d} finalists on {d} held-out games\n", .{ finalists.items.len, config.validation_games });
    const winner = try training.validate(allocator, finalists.items, config.eval, config.validation_games);
    std.debug.print("FINAL validation fitness {d:.1} (sigma {d:.3})\n", .{ winner.fitness, sigma });
    return winner.weights;
}

fn toWeights(x: Vec, config: CmaesConfig) Weights {
    var values: [N]f32 = undefined;
    for (&values, x) |*v, xi| v.* = std.math.clamp(@as(f32, @floatCast(xi)), config.weight_min, config.weight_max);
    return Weights.fromArray(values);
}

fn identity() Mat {
    var m: Mat = undefined;
    for (0..N) |i| {
        for (0..N) |j| m[i][j] = if (i == j) 1.0 else 0.0;
    }
    return m;
}

fn matVec(m: *const Mat, v: *const Vec) Vec {
    var out: Vec = @splat(0.0);
    for (0..N) |i| {
        for (0..N) |j| out[i] += m[i][j] * v[j];
    }
    return out;
}

fn matTVec(m: *const Mat, v: *const Vec) Vec {
    var out: Vec = @splat(0.0);
    for (0..N) |i| {
        for (0..N) |j| out[i] += m[j][i] * v[j];
    }
    return out;
}

fn norm(v: *const Vec) f64 {
    var sum: f64 = 0;
    for (v) |x| sum += x * x;
    return @sqrt(sum);
}

/// Cyclic Jacobi eigen-decomposition of a symmetric matrix.
/// Eigenvectors are written as the columns of `vectors`.
fn jacobiEigen(matrix: Mat, vectors: *Mat, values: *Vec) void {
    var a = matrix;
    vectors.* = identity();

    var sweep: usize = 0;
    while (sweep < 64) : (sweep += 1) {
        var off: f64 = 0;
        for (0..N) |i| {
            for (i + 1..N) |j| off += a[i][j] * a[i][j];
        }
        if (off < 1e-24) break;

        for (0..N) |p| {
            for (p + 1..N) |q| {
                if (@abs(a[p][q]) < 1e-30) continue;
                // Rotation angle that zeroes a[p][q].
                const theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
                const t = std.math.sign(theta) / (@abs(theta) + @sqrt(theta * theta + 1.0));
                const t_signed = if (theta == 0) 1.0 else t;
                const c = 1.0 / @sqrt(t_signed * t_signed + 1.0);
                const s = t_signed * c;

                for (0..N) |k| {
                    const akp = a[k][p];
                    const akq = a[k][q];
                    a[k][p] = c * akp - s * akq;
                    a[k][q] = s * akp + c * akq;
                }
                for (0..N) |k| {
                    const apk = a[p][k];
                    const aqk = a[q][k];
                    a[p][k] = c * apk - s * aqk;
                    a[q][k] = s * apk + c * aqk;
                }
                for (0..N) |k| {
                    const vkp = vectors[k][p];
                    const vkq = vectors[k][q];
                    vectors[k][p] = c * vkp - s * vkq;
                    vectors[k][q] = s * vkp + c * vkq;
                }
            }
        }
    }

    for (0..N) |i| values[i] = a[i][i];
}

test "jacobiEigen reconstructs a symmetric matrix" {
    var m: Mat = undefined;
    var rng = std.Random.Xoshiro256.init(3);
    // Random symmetric positive definite matrix: A * A^T + I.
    var a: Mat = undefined;
    for (0..N) |i| {
        for (0..N) |j| a[i][j] = rng.random().float(f64) - 0.5;
    }
    for (0..N) |i| {
        for (0..N) |j| {
            var sum: f64 = if (i == j) 1.0 else 0.0;
            for (0..N) |k| sum += a[i][k] * a[j][k];
            m[i][j] = sum;
        }
    }

    var vectors: Mat = undefined;
    var values: Vec = undefined;
    jacobiEigen(m, &vectors, &values);

    // B * diag(values) * B^T must give back m.
    for (0..N) |i| {
        for (0..N) |j| {
            var sum: f64 = 0;
            for (0..N) |k| sum += vectors[i][k] * values[k] * vectors[j][k];
            try std.testing.expectApproxEqAbs(m[i][j], sum, 1e-9);
        }
    }
}

test "cmaes smoke run" {
    var config = defaultConfig();
    config.lambda = 4;
    config.generations = 2;
    config.validation_games = 2;
    config.eval.games_per_candidate = 1;
    config.eval.max_moves = 10;
    config.eval.thread_count = 2;
    config.eval.search = .{ .depth = 1, .beam_width = 2 };
    _ = try runTrainer(std.testing.allocator, config, null);
}
