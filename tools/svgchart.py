"""Shared look for the SVG charts in docs/ (stdlib only).

Colors are role tokens defined once in a <style> block, with a dark-mode
variant, so the charts follow the viewer's light/dark setting on GitHub.
"""

FONT = 'system-ui, -apple-system, "Segoe UI", sans-serif'

STYLE = """
<style>
  .surface { fill: #fcfcfb; }
  .ink { fill: #0b0b0b; }
  .ink-2 { fill: #52514e; }
  .muted { fill: #898781; }
  .grid { stroke: #e1e0d9; stroke-width: 1; }
  .axis { stroke: #c3c2b7; stroke-width: 1; }
  .s1 { fill: #2a78d6; }
  .s1-line { stroke: #2a78d6; }
  .s2-line { stroke: #eb6834; }
  .before { fill: #898781; }
  @media (prefers-color-scheme: dark) {
    .surface { fill: #1a1a19; }
    .ink { fill: #f0efec; }
    .ink-2 { fill: #c3c2b7; }
    .grid { stroke: #2c2c2a; }
    .axis { stroke: #383835; }
    .s1 { fill: #3987e5; }
    .s1-line { stroke: #3987e5; }
    .s2-line { stroke: #d95926; }
    .before { fill: #6e6d68; }
  }
</style>
"""


def open_svg(width, height, title):
    """Start an SVG with the shared style, a surface and an accessible title."""
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}" font-family=\'{FONT}\' font-size="12" role="img">',
        f"<title>{escape(title)}</title>",
        STYLE,
        f'<rect class="surface" width="{width}" height="{height}" rx="8"/>',
    ]


def text(x, y, content, cls="ink", size=12, anchor="start", weight="normal"):
    return (
        f'<text class="{cls}" x="{x:.1f}" y="{y:.1f}" font-size="{size}" '
        f'text-anchor="{anchor}" font-weight="{weight}">{escape(content)}</text>'
    )


def hbar(x, y, length, thickness, cls):
    """Horizontal bar: square at the baseline (left), 4px rounded data end (right)."""
    r = min(4.0, length / 2, thickness / 2)
    if length <= 0:
        return ""
    return (
        f'<path class="{cls}" d="M{x:.1f},{y:.1f} h{length - r:.1f} '
        f"a{r},{r} 0 0 1 {r},{r} v{thickness - 2 * r:.1f} "
        f'a{r},{r} 0 0 1 {-r},{r} h{-(length - r):.1f} z"/>'
    )


def nice_axis(v, max_ticks=6):
    """Axis maximum and tick step: the smallest 1/2/2.5/5 x 10^k step that
    covers `v` in at most `max_ticks` intervals."""
    if v <= 0:
        return 1, 1
    magnitude = 10 ** (len(str(int(v))) - 1) if v >= 1 else 1
    for scale in (magnitude / 10, magnitude, magnitude * 10):
        for m in (1, 2, 2.5, 5):
            step = m * scale
            intervals = -(-v // step)
            if intervals <= max_ticks:
                return step * intervals, step
    return v, v


def fmt(v):
    """Compact number: 96375 -> 96.4k, 21.73 -> 21.7, 0.07 -> 0.07."""
    if v >= 10_000:
        return f"{v / 1000:.1f}k"
    if v >= 1000:
        return f"{v:,.0f}"
    if v >= 10:
        return f"{v:.1f}"
    return f"{v:.2f}"


def escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
