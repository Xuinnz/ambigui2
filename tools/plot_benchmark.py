#!/usr/bin/env python3
"""Draw the benchmark charts in docs/ from docs/benchmark.csv (stdlib only).

    python3 tools/plot_benchmark.py docs/benchmark.csv docs

Writes:
  benchmark-hard.svg    Hard mode, original vs this version, three measures
  benchmark-search.svg  strength of each search setting in this version
"""
import csv
import os
import sys

from svgchart import fmt, hbar, nice_axis, open_svg, text

SUBTITLE = "40 games per setting (seeds 1000-1039), each capped at 1000 pieces"
BAR = 22  # bar thickness, under the 24px cap
GAP = 2  # surface gap between adjacent bars


def load(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for key in ("mean_lines", "mean_score", "ms_per_move"):
            r[key] = float(r[key])
    return rows


def hard_chart(rows, out):
    before = next(r for r in rows if r["version"] == "original" and r["search"].startswith("Hard"))
    after = next(r for r in rows if r["version"] == "current" and r["search"].startswith("Hard"))

    panels = [
        ("Lines cleared per game", "mean_lines", "higher is better"),
        ("Score per game", "mean_score", "higher is better"),
        ("Milliseconds per move", "ms_per_move", "lower is better"),
    ]
    width, label_w, panel_w, panel_gap = 780, 112, 210, 12
    top = 116
    height = top + 2 * BAR + GAP + 46

    parts = open_svg(width, height, "Hard mode AI, original vs this version")
    parts.append(text(20, 30, "Hard mode AI: original vs this version", size=16, weight="bold"))
    parts.append(text(20, 50, SUBTITLE, cls="ink-2"))

    # Legend: both series are also labeled on every row.
    lx = 20
    for cls, name in (("before", "Original (depth 5, saw a hidden piece)"), ("s1", "This version (3 pieces + hold)")):
        parts.append(f'<rect class="{cls}" x="{lx}" y="62" width="12" height="12" rx="2"/>')
        parts.append(text(lx + 18, 72, name, cls="ink-2"))
        lx += 18 + 7.2 * len(name) + 24

    rows_y = [top, top + BAR + GAP]
    parts.append(text(20, rows_y[0] + 15, "Original", cls="ink-2"))
    parts.append(text(20, rows_y[1] + 15, "This version", cls="ink-2"))

    for i, (title, key, direction) in enumerate(panels):
        x0 = label_w + i * (panel_w + panel_gap)
        parts.append(text(x0, top - 10, title, weight="bold"))
        values = (before[key], after[key])
        scale = (panel_w - 48) / max(values)  # leave room for the value label
        parts.append(f'<line class="axis" x1="{x0}" x2="{x0}" y1="{top - 2}" y2="{top + 2 * BAR + GAP + 2}"/>')
        for y, value, cls in ((rows_y[0], values[0], "before"), (rows_y[1], values[1], "s1")):
            length = value * scale
            parts.append(hbar(x0, y, length, BAR, cls))
            parts.append(text(x0 + length + 6, y + 15, fmt(value), cls="ink"))

        ratio = values[1] / values[0]
        change = f"{ratio:.1f}x" if ratio >= 1 else f"{1 / ratio:.1f}x faster"
        parts.append(text(x0, top + 2 * BAR + GAP + 22, f"{change} ({direction})", cls="ink-2"))

    parts.append("</svg>")
    write(out, parts)


def search_chart(rows, out):
    current = [r for r in rows if r["version"] == "current"]
    width, label_w = 780, 190
    top = 70
    row_h = BAR + 10
    height = top + row_h * len(current) + 36
    x_max, step = nice_axis(max(r["mean_lines"] for r in current))
    plot_w = width - label_w - 70

    parts = open_svg(width, height, "Mean lines cleared per game by search setting")
    parts.append(text(20, 30, "Lines cleared per game, by how far the AI looks ahead", size=16, weight="bold"))
    parts.append(text(20, 50, SUBTITLE + ". Same trained weights for every row.", cls="ink-2"))

    bottom = top + row_h * len(current) - 10
    for i in range(int(round(x_max / step)) + 1):
        v = step * i
        gx = label_w + plot_w * v / x_max
        parts.append(f'<line class="grid" x1="{gx:.1f}" x2="{gx:.1f}" y1="{top - 6}" y2="{bottom}"/>')
        parts.append(text(gx, bottom + 18, f"{v:.0f}", cls="muted", anchor="middle"))
    parts.append(f'<line class="axis" x1="{label_w}" x2="{label_w}" y1="{top - 6}" y2="{bottom}"/>')

    for i, r in enumerate(current):
        y = top + i * row_h
        length = plot_w * r["mean_lines"] / x_max
        parts.append(text(label_w - 10, y + 15, r["search"], cls="ink-2", anchor="end"))
        parts.append(hbar(label_w, y, length, BAR, "s1"))
        parts.append(text(label_w + length + 6, y + 15, fmt(r["mean_lines"]), cls="ink"))

    parts.append("</svg>")
    write(out, parts)


def write(path, parts):
    with open(path, "w") as f:
        f.write("\n".join(p for p in parts if p) + "\n")
    print(f"wrote {path}")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: plot_benchmark.py <benchmark.csv> <out-dir>")
    rows = load(sys.argv[1])
    hard_chart(rows, os.path.join(sys.argv[2], "benchmark-hard.svg"))
    search_chart(rows, os.path.join(sys.argv[2], "benchmark-search.svg"))


if __name__ == "__main__":
    main()
