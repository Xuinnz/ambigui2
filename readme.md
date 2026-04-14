# ambigui2

Dual-State Tetromino Engine and Artificial Intelligence Agent

ambigui2 is a terminal-first Zig project focused on high-performance gameplay simulation and probabilistic decision-making. The design extends classic tetromino mechanics with dual-state pieces and targets an AI stack that combines expectimax search, beam pruning, transposition caching, and evolutionary optimization.

## Project Status

Current repository state: Ongoing Engine Development
- Implemented Board and Pieces logic.
- Next to implement is physics and RNG.
This README documents the intended production architecture and development workflow.

## Core Concepts

### Dual-State Mechanics

Each spawned piece is represented as a probabilistic dual-state candidate and collapses into a concrete shape under placement or rule-triggered conditions.

### Bitboard-Centric Engine

Board and piece operations are designed around compact integer bitboards to enable fast collision checks, state transforms, and line processing.

### Probabilistic Decision Agent

The AI is designed for uncertainty-aware planning through expectimax and chance-node evaluation, with strict runtime budgeting for real-time play.

## Target Feature Set

### Engine

- Dual-state tetromino lifecycle (spawn, transform, collapse, lock)
- Deterministic board updates and line clear resolution
- Terminal renderer and low-latency input loop
- Reproducible simulation mode for AI training

### AI

- Expectimax search over deterministic and stochastic branches
- Beam search pruning to bound combinatorial growth
- Zobrist hashing and transposition table reuse
- Heuristic evaluation over board quality metrics
- Offline genetic training for heuristic weight evolution

### RNG

- Xoshiro256** class generator for high-throughput simulation
- Controlled seeding for repeatable experiments

## Architecture

ambigui2 is organized into two decoupled pipelines.

### 1) Offline Training Pipeline

Headless simulation environment for large-volume self-play.

- Population initialization
- Tournament selection and elitism
- Crossover and mutation
- Fitness evaluation over multi-game batches
- Best-weight snapshot export for runtime use

### 2) Online Execution Engine

Real-time gameplay loop for terminal play.

- Current board state ingestion
- Time-bounded expectimax inference
- Transposition-aware evaluation
- Move emission to engine loop

## Prerequisites

- Linux or WSL2
- Zig 0.15.2

Version pinning matters for compiler behavior and reproducible builds.

## Getting Started

### 1) Clone

```bash
git clone https://github.com/yourusername/ambigui2.git
cd ambigui2
```

### 2) Verify Zig Version

```bash
zig version
```

Expected output:

```text
0.15.2
```

### 3) Build (After Implementation Milestone)

```bash
zig build
```

### 4) Run (After Runtime Entry Is Wired)

```bash
zig build run
```

## Development Workflow

### Suggested Local Loop

```bash
zig fmt src/**/*.zig tests/**/*.zig
zig test src/main.zig
zig build
```

Adjust test commands as module-level test targets are introduced.

### Engineering Priorities

- Correctness-first collision and lock semantics
- Deterministic behavior under fixed seeds
- Predictable frame-time budget in online mode
- Measurable search quality improvements from training

## Testing Strategy

Planned testing layers:

- Unit tests: board transforms, collision checks, line clear logic
- Property tests: piece invariants and rotation legality
- Determinism tests: seed-to-sequence reproducibility
- AI regression tests: fixed-state move quality and latency caps

## Roadmap

1. Data structures and tetromino encoding
2. Core physics and collision system
3. Dual-state collapse and line clear rules
4. Terminal rendering and interactive loop
5. Expectimax agent and genetic training pipeline

## Contributing

Contributions are welcome. For substantial changes, open an issue first to align on scope, performance targets, and testing expectations.

When submitting a pull request:

- Keep changes modular and documented
- Include or update tests where applicable
- Preserve deterministic behavior under fixed seeds

## License

MIT (intended). Add a `LICENSE` file at repository root to finalize licensing terms.

## Academic Context

This project was initiated for Intro to Modern AI coursework and is maintained as a systems-and-AI engineering project.
