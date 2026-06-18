//Implementation of Expectimax Search Algorithm with Beam Search Pruning
const game_mod = @import("../engine/game.zig");
const heuristics = @import("heuristics.zig");

pub const GameState = game_mod.GameState;
pub const Move = game_mod.Move;
pub const MoveList = game_mod.MoveList;
pub const Weights = game_mod.Weights;

//search configurations. depth for look ahead and beam_width for pruning
pub const SearchOptions = struct {
    depth: u32,
    beam_width: usize,
};
pub var node_count: u64 = 0;

//game over has biggest penalty, line clear will give reward
const GAME_OVER_SCORE: f32 = -1.0e9;
const LINE_CLEAR_REWARD: f32 = 1.0;

const MoveArrayType = @typeInfo(MoveList).@"struct".fields[0].type;
const MAX_MOVES: usize = @typeInfo(MoveArrayType).array.len;

//used by beam pruning
const MoveScore = struct {
    move: Move,
    score: f32,
};

//this will give the best move (the highest value move) according the weights
pub fn bestMoveWithOptions(state: *const GameState, weights: *const Weights, options: SearchOptions) ?Move {
    if (state.game_over) return null;
    if (options.depth == 0) return null;

    //get all possible moves
    const moves = state.getMoves();
    if (moves.len == 0) return null;

    var best_move: ?Move = null;
    var best_score: f32 = GAME_OVER_SCORE;

    //Pruning the results. if we only have beam width of 5
    //we get the top 5 highest ev of all the possible moves
    if (options.beam_width > 0 and moves.len > options.beam_width) {
        var beam: [MAX_MOVES]MoveScore = undefined;
        var beam_len: usize = 0;

        var i: usize = 0;

        //for every move, we estimate its Estimated Value
        while (i < moves.len) : (i += 1) {
            const candidate = moves.items[i];
            const estimate = estimateMoveValue(state, &candidate, weights);
            pushBeam(&beam, &beam_len, options.beam_width, .{ .move = candidate, .score = estimate });
        }

        //the highest value will be evaluated with next pieces. basically a look ahead evaluation.
        //the number of depth is the number of look ahead.
        i = 0;
        while (i < beam_len) : (i += 1) {
            const entry = beam[i];
            //we check the Estimated Value of this move along with it's future pieces.
            const value = chanceNode(state, &entry.move, weights, options.depth - 1, options.beam_width);
            if (value > best_score or best_move == null) {
                best_score = value;
                best_move = entry.move;
            }
        }
        //we return the best move. the one with the highest EV
        return best_move;
    }

    //executed if beam search is turned off or number of legal moves is lower than indicated beam width.
    var i: usize = 0;
    while (i < moves.len) : (i += 1) {
        const candidate = moves.items[i];
        const value = chanceNode(state, &candidate, weights, options.depth - 1, options.beam_width);
        if (value > best_score or best_move == null) {
            best_score = value;
            best_move = candidate;
        }
    }

    return best_move;
}

//this is used to simulate the future timelines
fn maxNode(state: *const GameState, weights: *const Weights, depth: u32, beam_width: usize, prev_lines: u32) f32 {
    if (state.game_over) return GAME_OVER_SCORE;
    node_count += 1;
    if (depth == 0) return scoreLeaf(state, weights, prev_lines);

    const moves = state.getMoves();
    if (moves.len == 0) return GAME_OVER_SCORE;

    var best_score: f32 = GAME_OVER_SCORE;

    //prune using beam width so we just calculate the top performing
    if (beam_width > 0 and moves.len > beam_width) {
        var beam: [MAX_MOVES]MoveScore = undefined;
        var beam_len: usize = 0;

        var i: usize = 0;
        //we check for each moves Estimated Valueu
        while (i < moves.len) : (i += 1) {
            const candidate = moves.items[i];
            const estimate = estimateMoveValue(state, &candidate, weights);
            pushBeam(&beam, &beam_len, beam_width, .{ .move = candidate, .score = estimate });
        }
        //we get the highest EVs
        i = 0;
        while (i < beam_len) : (i += 1) {
            const entry = beam[i];
            //we recursion to chanceNode for another lookahead
            const value = chanceNode(state, &entry.move, weights, depth - 1, beam_width);
            if (value > best_score) {
                best_score = value;
            }
        }
        return best_score;
    }

    //executed when list of available moves is lower than sorting.
    var i: usize = 0;
    while (i < moves.len) : (i += 1) {
        const candidate = moves.items[i];
        const value = chanceNode(state, &candidate, weights, depth - 1, beam_width);
        if (value > best_score) {
            best_score = value;
        }
    }

    return best_score;
}

//we use this to calculate the Estimated Values of each moves.
fn chanceNode(state: *const GameState, move: *const Move, weights: *const Weights, depth: u32, beam_width: usize) f32 {
    if (state.game_over) return GAME_OVER_SCORE;
    node_count += 1;

    //we get the probability of state_a and state_b
    const prob_a = state.current_piece.prob_a;
    const prob_b = 1.0 - prob_a;
    const prev_lines = state.lines_cleared;

    //we clone the current game state in a universe where the piece collapsed into 'state_a'
    var branch_a = state.clone();
    branch_a.applyMoveDeterministic(move, true, true);

    //we evaluate the score
    const score_a = if (branch_a.game_over) //if game is over, then it fails
        GAME_OVER_SCORE
    else if (depth == 0) //if depth is now zero, we score the grid layout
        scoreLeaf(&branch_a, weights, prev_lines)
    else //if there is still depth, we consider the future pieces EV as well
        maxNode(&branch_a, weights, depth - 1, beam_width, prev_lines);

    //we do the same for 'state_b'
    var branch_b = state.clone();
    branch_b.applyMoveDeterministic(move, false, true);
    const score_b = if (branch_b.game_over) //if game is over, then it fails
        GAME_OVER_SCORE
    else if (depth == 0) //if depth is now zero, we score the grid layout
        scoreLeaf(&branch_b, weights, prev_lines)
    else //if there is still depth, we consider the future pieces EV as well
        maxNode(&branch_b, weights, depth - 1, beam_width, prev_lines);

    //we blend the EV of both realities into a unified EV.
    //basically, if we have a prob_a = 0.1, score_a = 10, prob_b = 0.9, score_b = 2
    //its EV is 2.8
    return (prob_a * score_a) + (prob_b * score_b);
}

fn estimateMoveValue(state: *const GameState, move: *const Move, weights: *const Weights) f32 {
    //fetch probabilities
    const prob_a = state.current_piece.prob_a;
    const prob_b = 1.0 - prob_a;
    const prev_lines = state.lines_cleared;

    //check immediate EV of the 'state_a' universe
    var branch_a = state.clone();
    branch_a.applyMoveDeterministic(move, true, true);
    const score_a = if (branch_a.game_over) GAME_OVER_SCORE else scoreLeaf(&branch_a, weights, prev_lines);

    //check immediate EV of the 'state_a' universe
    var branch_b = state.clone();
    branch_b.applyMoveDeterministic(move, false, true);
    const score_b = if (branch_b.game_over) GAME_OVER_SCORE else scoreLeaf(&branch_b, weights, prev_lines);

    //give back the unified EV of the move.
    return (prob_a * score_a) + (prob_b * score_b);
}

//evaluator of the final score. calculates the penalty + reward
fn scoreLeaf(state: *const GameState, weights: *const Weights, prev_lines: u32) f32 {
    //we evaluate the state based on our weights model.
    const base = heuristics.score(state, weights);
    //evaluate how many lines burned through this branch
    const delta = state.lines_cleared - prev_lines;
    //multiple by the clear reward
    const reward = LINE_CLEAR_REWARD * @as(f32, @floatFromInt(delta));
    //with the penalty and rewards. we return the actual EV
    return base + reward;
}

//beam tracker
fn pushBeam(beam: *[MAX_MOVES]MoveScore, beam_len: *usize, beam_width: usize, candidate: MoveScore) void {
    //no beam_width
    if (beam_width == 0) {
        beam[beam_len.*] = candidate;
        beam_len.* += 1;
        return;
    }

    //beam not full
    if (beam_len.* < beam_width) {
        beam[beam_len.*] = candidate;
        beam_len.* += 1;
        return;
    }

    //beam is full
    //we insert the idx into its position. then eliminates the worst idx
    var worst_idx: usize = 0;
    var worst_score = beam[0].score;
    var i: usize = 1;
    while (i < beam_len.*) : (i += 1) {
        if (beam[i].score < worst_score) {
            worst_score = beam[i].score;
            worst_idx = i;
        }
    }

    if (candidate.score > worst_score) {
        beam[worst_idx] = candidate;
    }
}
