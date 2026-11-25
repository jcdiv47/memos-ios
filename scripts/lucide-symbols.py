#!/usr/bin/env python3
"""Builds the app's icon set: Lucide icons as custom symbols, and the Swift enum that names them.

    python3 -m venv /tmp/lucide-venv && /tmp/lucide-venv/bin/pip install picosvg
    /tmp/lucide-venv/bin/python scripts/lucide-symbols.py

Lucide (https://lucide.dev, ISC) draws 2-unit strokes in a 24-unit box. Custom symbols need
filled outlines, so picosvg outlines the strokes, and each icon lands in the Regular-M slot of a
symbol template, centred on the cap height like Apple's symbols. As symbols they scale with the
font beside them and work anywhere SwiftUI or UIKit takes an image: labels, menus, buttons.

Writes Memos/Resources/Assets.xcassets/Lucide/*.symbolset, shared by the app and its
extensions, and MemosKit/Sources/MemosCore/Lucide.swift.
"""
import json, pathlib, re, shutil, sys, tempfile, urllib.request
from picosvg.svg import SVG
from picosvg.svg_transform import Affine2D
from picosvg.svg_types import SVGPath

VERSION = "1.80.0"
ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Memos/Resources/Assets.xcassets/Lucide"
SWIFT = ROOT / "MemosKit/Sources/MemosCore/Lucide.swift"

# (asset, Lucide source, mode). Modes: "outline"; "fill", every shape solid (play, stop);
# "fill-N", shape N solid (a pin's head); "knockout", the first shape solid with the rest cut
# out of it (a filled circle with an x through it). Fills stand in for SF's `.fill` symbols.
ICONS = [
    ("archive", "archive", "outline"),
    ("archive-restore", "archive-restore", "outline"),
    ("arrow-up-right", "arrow-up-right", "outline"),
    ("audio-lines", "audio-lines", "outline"),
    ("bell", "bell", "outline"),
    ("bold", "bold", "outline"),
    ("bookmark-plus", "bookmark-plus", "outline"),
    ("bookmark-x", "bookmark-x", "outline"),
    ("braces", "braces", "outline"),
    ("calendar", "calendar", "outline"),
    ("camera", "camera", "outline"),
    ("check", "check", "outline"),
    ("chevron-down", "chevron-down", "outline"),
    ("chevron-right", "chevron-right", "outline"),
    ("circle", "circle", "outline"),
    ("circle-arrow-up-fill", "circle-arrow-up", "knockout"),
    ("circle-question-mark", "circle-question-mark", "outline"),
    ("circle-user-round", "circle-user-round", "outline"),
    ("circle-x-fill", "circle-x", "knockout"),
    ("clock", "clock", "outline"),
    ("cloud-upload", "cloud-upload", "outline"),
    ("code", "code", "outline"),
    ("copy", "copy", "outline"),
    ("ellipsis", "ellipsis", "outline"),
    ("eye", "eye", "outline"),
    ("eye-off", "eye-off", "outline"),
    ("file", "file", "outline"),
    ("file-question-mark", "file-question-mark", "outline"),
    ("file-text", "file-text", "outline"),
    ("film", "film", "outline"),
    ("flame-fill", "flame", "fill"),
    ("folder", "folder", "outline"),
    ("funnel", "funnel", "outline"),
    ("funnel-fill", "funnel", "fill"),
    ("git-fork", "git-fork", "outline"),
    ("globe", "globe", "outline"),
    ("hash", "hash", "outline"),
    ("heading-1", "heading-1", "outline"),
    ("heading-2", "heading-2", "outline"),
    ("heading-3", "heading-3", "outline"),
    ("history", "history", "outline"),
    ("image", "image", "outline"),
    ("images", "images", "outline"),
    ("italic", "italic", "outline"),
    ("key", "key-round", "outline"),
    ("layers", "layers", "outline"),
    ("library", "library", "outline"),
    ("link", "link", "outline"),
    ("list", "list", "outline"),
    ("list-checks", "list-checks", "outline"),
    ("list-ordered", "list-ordered", "outline"),
    ("locate-fixed", "locate-fixed", "outline"),
    ("lock", "lock", "outline"),
    ("map", "map", "outline"),
    ("map-pin", "map-pin", "outline"),
    ("mic", "mic", "outline"),
    ("mic-off", "mic-off", "outline"),
    ("notepad-text", "notepad-text", "outline"),
    ("paperclip", "paperclip", "outline"),
    ("pause-fill", "pause", "fill"),
    ("pencil", "pencil", "outline"),
    ("pencil-line", "pencil-line", "outline"),
    ("pin", "pin", "outline"),
    ("pin-fill", "pin", "fill-1"),
    ("pin-off", "pin-off", "outline"),
    ("play-fill", "play", "fill"),
    ("plus", "plus", "outline"),
    ("scan-text", "scan-text", "outline"),
    ("search", "search", "outline"),
    ("server", "server", "outline"),
    ("settings", "settings", "outline"),
    ("share", "share", "outline"),
    ("signpost", "signpost", "outline"),
    ("smartphone", "smartphone", "outline"),
    ("smile-plus", "smile-plus", "outline"),
    ("sparkles", "sparkles", "outline"),
    ("square", "square", "outline"),
    ("square-check-fill", "square-check", "knockout"),
    ("square-dashed", "square-dashed", "outline"),
    ("square-fill", "square", "fill"),
    ("square-pen", "square-pen", "outline"),
    ("square-stack", "square-stack", "outline"),
    ("strikethrough", "strikethrough", "outline"),
    ("tablet", "tablet", "outline"),
    ("text-quote", "text-quote", "outline"),
    ("trash", "trash-2", "outline"),
    ("triangle-alert", "triangle-alert", "outline"),
    ("type", "type", "outline"),
    ("user", "user", "outline"),
    ("user-lock", "user-lock", "outline"),
    ("user-x", "user-x", "outline"),
    ("users", "users", "outline"),
    ("x", "x", "outline"),
]

SHAPE = re.compile(r"<(path|circle|rect|line|polyline|polygon|ellipse)\b[^>]*/>")

# Template geometry, in the units of Apple's symbol template (100 pt type). Medium puts the
# 24-unit box at 120 units, so an 18-unit square matches SF's at about 0.9 em; small and large follow SF's image scales.
# Each row is centred on its cap height, like Apple's symbols.
SCALE = 5.0
CAP_HEIGHT = 70.459
LEFT = 1391.0
VARIANTS = [("S", 696.0, 0.783), ("M", 1126.0, 1.0), ("L", 1556.0, 1.29)]


def outlines(svg_text):
    """Every shape in an SVG as filled outlines, strokes included."""
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
    return [shape.as_path() for shape in SVG.parse(f.name).topicosvg().shapes()]


def solid(element):
    return re.sub(r"^<(\w+)", r'<\1 fill="#000"', element)


def symbol_paths(source, mode, baseline, factor):
    """One scale's outlines. The stroke is outlined thicker at small, thinner at large, so all
    three draw at the same weight, as SF's scales do."""
    text = re.sub(r"<!--.*?-->", "", source, flags=re.S).replace("currentColor", "#000")
    text = text.replace('stroke-width="2"', f'stroke-width="{2 / factor:.4f}"')
    elements = [m.group(0) for m in SHAPE.finditer(text)]
    opening = text[: text.index(">", text.index("<svg")) + 1]

    def document(parts):
        return opening + "".join(parts) + "</svg>"

    if mode == "knockout":
        import pathops
        from picosvg.svg_pathops import skia_path, svg_commands

        shape = pathops.Path()
        for path in outlines(document([solid(elements[0])])):
            shape = pathops.op(shape, skia_path(path.as_cmd_seq(), "nonzero"), pathops.PathOp.UNION)
        for path in outlines(document(elements[1:])):
            shape = pathops.op(shape, skia_path(path.as_cmd_seq(), "nonzero"), pathops.PathOp.DIFFERENCE)
        paths = [SVGPath.from_commands(svg_commands(shape))]
    elif mode == "fill":
        paths = outlines(document(solid(e) for e in elements))
    elif mode.startswith("fill-"):
        n = int(mode.removeprefix("fill-"))
        paths = outlines(document(solid(e) if i == n else e for i, e in enumerate(elements)))
    else:
        paths = outlines(document(elements))

    scale = SCALE * factor
    place = Affine2D(scale, 0, 0, scale, LEFT, baseline - CAP_HEIGHT / 2 - 12 * scale)
    return [p.apply_transform(place).round_floats(3).d for p in paths]


def template(source, mode, source_name):
    guides = "\n".join(
        f'  <line id="{name}" x1="263.818" y1="{y}" x2="3036.18" y2="{y}" stroke="#27aae1" stroke-width="0.5"/>'
        for name, y in [("Baseline-S", 696), ("Capline-S", 625.541), ("Baseline-M", 1126),
                        ("Capline-M", 1055.54), ("Baseline-L", 1556), ("Capline-L", 1485.54)]
    )
    margins, symbols = [], []
    for row, baseline, factor in VARIANTS:
        right = LEFT + 24 * SCALE * factor
        for side, x in [("left", LEFT), ("right", right)]:
            margins.append(f'  <line id="{side}-margin-Regular-{row}" x1="{x:.3f}" y1="{baseline - 95.21}" '
                           f'x2="{x:.3f}" y2="{baseline + 24.12}" stroke="#00ac8e" stroke-width="0.5"/>')
        paths = "\n".join(f'   <path d="{d}"/>' for d in symbol_paths(source, mode, baseline, factor))
        symbols.append(f'  <g id="Regular-{row}">\n{paths}\n  </g>')
    margins, symbols = "\n".join(margins), "\n".join(symbols)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Lucide {source_name} v{VERSION}, ISC licence. Generated by scripts/lucide-symbols.py. -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="3300" height="2200">
 <g id="Notes">
  <text id="template-version" x="2994" y="2100">Template v.3.0</text>
 </g>
 <g id="Guides">
{guides}
{margins}
 </g>
 <g id="Symbols">
{symbols}
 </g>
</svg>
"""


def case_name(asset):
    head, *rest = asset.split("-")
    return head + "".join(part.capitalize() for part in rest)


def swift_enum():
    cases = "\n".join(
        f'    case {case_name(a)}' + ("" if case_name(a) == a else f' = "{a}"') for a, _, _ in ICONS
    )
    return f"""// Generated by scripts/lucide-symbols.py. Don't edit; add icons to its list.

/// An icon in the app's set: Lucide's, drawn as a custom symbol in the shared asset catalog,
/// `Assets.xcassets/Lucide`. Scales with the font beside it, like an SF Symbol.
public enum Lucide: String, CaseIterable, Sendable {{
{cases}

    /// The symbol's name in the asset catalog.
    public var assetName: String {{ "Lucide/\\(rawValue)" }}
}}
"""


def main():
    cache = pathlib.Path(tempfile.mkdtemp(prefix="lucide-"))
    if ASSETS.exists():
        shutil.rmtree(ASSETS)
    ASSETS.mkdir(parents=True)
    (ASSETS / "Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}, indent=2) + "\n")
    for asset, source_name, mode in ICONS:
        source = cache / f"{source_name}.svg"
        if not source.exists():
            url = f"https://unpkg.com/lucide-static@{VERSION}/icons/{source_name}.svg"
            source.write_bytes(urllib.request.urlopen(url).read())
        folder = ASSETS / f"{asset}.symbolset"
        folder.mkdir()
        (folder / f"{asset}.svg").write_text(template(source.read_text(), mode, source_name))
        (folder / "Contents.json").write_text(json.dumps({
            "info": {"author": "xcode", "version": 1},
            "symbols": [{"filename": f"{asset}.svg", "idiom": "universal"}],
        }, indent=2) + "\n")
    SWIFT.write_text(swift_enum())
    print(f"{len(ICONS)} symbols in {ASSETS.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
