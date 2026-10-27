#!/usr/bin/env python3
"""Draw Listener's app icon and build App/AppIcon.icns from it.

The icon is an L cut into lines, its last line slid out from under it in indigo, on ink.
Each size is drawn on its own pixel grid, with fewer lines at the smallest, so the lines
stay sharp rather than blurring into grey. App/AppIcon.svg is the full-size drawing.

    python3 scripts/make-icon.py

Needs rsvg-convert (brew install librsvg) and iconutil, which comes with Xcode.
"""

import math
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
INK, WHITE, INDIGO = "#0c0f17", "#f3f4f7", "#7d7aff"


def squircle():
    """Apple's macOS icon body: an 824 pt superellipse (n = 5) with a 100 pt margin."""
    points = []
    for step in range(720):
        angle = 2 * math.pi * step / 720
        c, s = math.cos(angle), math.sin(angle)
        x = 512 + 412 * math.copysign(abs(c) ** 0.4, c)
        y = 512 + 412 * math.copysign(abs(s) ** 0.4, s)
        points.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(points) + " Z"


# Per pixel size: how many lines, then each measure in that size's pixels: line height,
# the gap between lines, the stem's lines, the long line, and how far the last one slides.
# From 128 px up the 128 px drawing is scaled, so every edge stays on a pixel.
DRAWINGS = {
    16: (4, 1, 1, 2, 6, 2),
    32: (5, 2, 1, 4, 11, 3),
    64: (6, 3, 2, 9, 24, 7),
    128: (7, 5, 4, 19, 48, 14),
}


def drawing(size):
    n, line, gap, stem, long, slide = DRAWINGS[min(size, 128)]
    unit = 1024 / min(size, 128)
    left = (min(size, 128) - (long + slide)) // 2
    top = (min(size, 128) - (n * line + (n - 1) * gap)) // 2
    crisp = size <= 64
    rects = []
    for i in range(n):
        y = (top + i * (line + gap)) * unit
        x, width, fill = left * unit, (long if i >= n - 2 else stem) * unit, WHITE
        if i == n - 1:
            x, fill = (left + slide) * unit, INDIGO
        corner = "" if crisp else ' rx="3"'
        rects.append(
            f'    <rect x="{x:g}" y="{y:g}" width="{width:g}" height="{line * unit:g}"{corner} fill="{fill}"/>'
        )
    body = squircle()
    lines = "\n".join(rects)
    rendering = ' shape-rendering="crispEdges"' if crisp else ""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000000" flood-opacity="0.3"/>
    </filter>
  </defs>
  <path filter="url(#shadow)" fill="{INK}" d="{body}"/>
  <g{rendering}>
{lines}
  </g>
  <path fill="none" stroke="#ffffff" stroke-opacity="0.08" stroke-width="3" d="{body}"/>
</svg>
"""


def render(svg, size, path):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), "-o", str(path)], input=svg.encode(), check=True)


def main():
    (ROOT / "App/AppIcon.svg").write_text(drawing(1024))
    with tempfile.TemporaryDirectory() as temp:
        iconset = pathlib.Path(temp) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            render(drawing(points), points, iconset / f"icon_{points}x{points}.png")
            render(drawing(points * 2), points * 2, iconset / f"icon_{points}x{points}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "App/AppIcon.icns")], check=True)
    print("Wrote App/AppIcon.svg and App/AppIcon.icns")


if __name__ == "__main__":
    main()
