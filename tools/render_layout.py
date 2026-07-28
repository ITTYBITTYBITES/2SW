#!/usr/bin/env python3
"""Draw a to-scale diagram of a screen's real, measured node rects.

WHY THIS EXISTS
---------------
The sandbox has no display server, so Godot cannot open a window and no
screenshot can be taken here. Every layout claim in this project has been a
number in a log, which is exactly how three "structurally present but visually
wrong" bugs shipped: the invisible Iris, the elliptical pupil, and shard
markers positioned 269px from where the eye actually was.

This is NOT a renderer and not a test. It takes the geometry a headless Godot
run measured from the LIVE tree and draws it at true viewport proportions, so
a human can see overlap, clipping and dead space at a glance.

Input: JSON emitted by tools/dump_layout.gd.  Output: an SVG per screen.
"""
from __future__ import annotations

import json
import pathlib
import sys

PALETTE = {
    "bg": "#06080e",
    "edge": "#39506b",
    "eye": "#2ab7c8",
    "label": "#d1dbf0",
    "button": "#e0a33c",
    "field": "#8a6bd1",
    "clip": "#f5484a",
    "text": "#aab6cc",
}


def kind(name: str, cls: str) -> str:
    n = name.lower()
    if "coreeye" in n or "iris" in n:
        return "eye"
    if "minigame" in n or "stage" in n:
        return "field"
    if cls == "Button":
        return "button"
    if cls == "Label":
        return "label"
    return "edge"


def render(screen: dict, out_path: pathlib.Path) -> None:
    vw, vh = screen["viewport"]
    scale = 380.0 / vw
    w, h = vw * scale, vh * scale
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" '
        f'height="{h + 26:.0f}" viewBox="0 0 {w:.0f} {h + 26:.0f}">',
        f'<rect width="{w:.0f}" height="{h:.0f}" fill="{PALETTE["bg"]}"/>',
    ]
    clipped = 0
    for node in screen["nodes"]:
        x, y = node["pos"]
        nw, nh = node["size"]
        if nw <= 0 or nh <= 0 or not node.get("visible", True):
            continue
        off = x < -1 or y < -1 or x + nw > vw + 1 or y + nh > vh + 1
        if off:
            clipped += 1
        colour = PALETTE["clip"] if off else PALETTE[kind(node["name"], node["cls"])]
        parts.append(
            f'<rect x="{x * scale:.1f}" y="{y * scale:.1f}" '
            f'width="{nw * scale:.1f}" height="{nh * scale:.1f}" '
            f'fill="none" stroke="{colour}" stroke-width="1.2" '
            f'{"stroke-dasharray=\'4 3\'" if off else ""}/>'
        )
        text = (node.get("text") or node["name"])[:20]
        if nh * scale > 9:
            parts.append(
                f'<text x="{(x + 4) * scale:.1f}" y="{(y * scale) + 11:.1f}" '
                f'font-family="monospace" font-size="9" fill="{colour}">{text}</text>'
            )
    verdict = f"{clipped} node(s) off-screen" if clipped else "all nodes inside"
    parts.append(
        f'<text x="2" y="{h + 18:.0f}" font-family="monospace" font-size="11" '
        f'fill="{PALETTE["clip"] if clipped else PALETTE["eye"]}">'
        f'{screen["name"]}  {vw}x{vh}  —  {verdict}</text>'
    )
    parts.append("</svg>")
    out_path.write_text("\n".join(parts))


def main() -> int:
    src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/layout_dump.json")
    out_dir = pathlib.Path("/home/user/2sw_previews")
    out_dir.mkdir(parents=True, exist_ok=True)
    data = json.loads(src.read_text())
    for screen in data:
        safe = screen["name"].replace("/", "_")
        target = out_dir / f"layout_{safe}_{screen['viewport'][0]}x{screen['viewport'][1]}.svg"
        render(screen, target)
        print(f"  {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
