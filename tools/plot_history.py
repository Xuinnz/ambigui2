#!/usr/bin/env python3
"""Plot a training history CSV (written by `zig build train`) as an SVG.

Uses only the standard library, so it runs anywhere Python 3 does:

    python3 tools/plot_history.py data/training_history.csv docs/training.svg
"""
import csv
import sys

from svgchart import nice_axis, open_svg, text

WIDTH, HEIGHT = 780, 380
LEFT, RIGHT, TOP, BOTTOM = 70, 150, 76, 50


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: plot_history.py <history.csv> <out.svg>")
    src, out = sys.argv[1], sys.argv[2]

    with open(src, newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit(f"{src} has no rows")

    gens = [int(r["generation"]) for r in rows]
    series = [
        ("Best sample", [float(r["best_fitness"]) for r in rows], "s1-line"),
        ("Generation mean", [float(r["mean_fitness"]) for r in rows], "s2-line"),
    ]

    y_max, y_step = nice_axis(max(max(values) for _, values, _ in series))
    x_max = max(gens) or 1

    def x(g):
        return LEFT + (WIDTH - LEFT - RIGHT) * g / x_max

    def y(v):
        return HEIGHT - BOTTOM - (HEIGHT - TOP - BOTTOM) * v / y_max

    parts = open_svg(WIDTH, HEIGHT, "CMA-ES training fitness by generation")
    parts.append(text(20, 30, "CMA-ES training: mean game score per generation", size=16, weight="bold"))
    parts.append(
        text(20, 50, f"{len(rows)} generations, 24 samples each, 10 fresh games per generation", cls="ink-2")
    )

    # Recessive horizontal grid with labels.
    for i in range(int(round(y_max / y_step)) + 1):
        v = y_step * i
        parts.append(f'<line class="grid" x1="{LEFT}" x2="{WIDTH - RIGHT}" y1="{y(v):.1f}" y2="{y(v):.1f}"/>')
        parts.append(text(LEFT - 8, y(v) + 4, f"{v / 1000:.0f}k", cls="muted", anchor="end"))
    parts.append(f'<line class="axis" x1="{LEFT}" x2="{WIDTH - RIGHT}" y1="{y(0):.1f}" y2="{y(0):.1f}"/>')

    # Generation ticks.
    step = 10 if x_max >= 30 else max(1, x_max // 6)
    for g in range(0, x_max + 1, step):
        parts.append(text(x(g), HEIGHT - BOTTOM + 18, str(g), cls="muted", anchor="middle"))
    parts.append(text((LEFT + WIDTH - RIGHT) / 2, HEIGHT - 12, "Generation", cls="ink-2", anchor="middle"))

    for name, values, cls in series:
        points = " ".join(f"{x(g):.1f},{y(v):.1f}" for g, v in zip(gens, values))
        parts.append(
            f'<polyline class="{cls}" points="{points}" fill="none" stroke-width="2" '
            f'stroke-linejoin="round" stroke-linecap="round"/>'
        )

    # Direct end labels double as the legend; nudged apart if they would overlap.
    ends = sorted(((y(values[-1]), name, cls) for name, values, cls in series), key=lambda e: e[0])
    for i in range(1, len(ends)):
        if ends[i][0] - ends[i - 1][0] < 16:
            ends[i] = (ends[i - 1][0] + 16, ends[i][1], ends[i][2])
    for ly, name, cls in ends:
        lx = WIDTH - RIGHT + 10
        parts.append(f'<line class="{cls}" x1="{lx}" x2="{lx + 14}" y1="{ly:.1f}" y2="{ly:.1f}" stroke-width="2"/>')
        parts.append(text(lx + 20, ly + 4, name, cls="ink-2"))

    parts.append("</svg>")
    with open(out, "w") as f:
        f.write("\n".join(parts) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
