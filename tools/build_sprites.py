"""Build every sprite atlas the app needs.

Usage: python3 tools/build_sprites.py [--preview DIR]
Run tools/extract4.py first if reference/sheet3.png changed.
"""
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import effects  # noqa: E402
import pet4  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "App", "Resources", "sprites")


def pack(frames, path_png, path_json, pad=1):
    """Shelf-pack frames (name -> (img, meta)) into one atlas."""
    # identical images (same pose reused under several names) are stored once
    uniq, alias = {}, {}
    for name, (img, meta) in frames.items():
        key = (img.shape, hash(img.tobytes()))
        alias[name] = uniq.setdefault(key, name)
    items = sorted(((n, frames[n]) for n in set(alias.values())), key=lambda kv: -kv[1][0].shape[0])
    width = 2048
    x = y = shelf = 0
    rects = {}
    for name, (img, meta) in items:
        h, w = img.shape[:2]
        if x + w > width:
            x, y, shelf = 0, y + shelf + pad, 0
        rects[name] = (x, y, w, h)
        x += w + pad
        shelf = max(shelf, h)
    atlas = np.zeros((y + shelf, width, 4), np.uint8)
    for name, (x, y, w, h) in rects.items():
        atlas[y:y + h, x:x + w] = frames[name][0]
    out = {name: {"rect": list(rects[alias[name]]), **meta} for name, (img, meta) in frames.items()}
    Image.fromarray(atlas).save(path_png, optimize=True)
    with open(path_json, "w") as f:
        json.dump(out, f, indent=0, sort_keys=True)


def preview(frames, path, scale=3, cols=12):
    names = sorted(frames)
    cw = max(frames[n][0].shape[1] for n in names)
    ch = max(frames[n][0].shape[0] for n in names)
    rows = (len(names) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cw, rows * ch), (150, 190, 210, 255))
    for i, n in enumerate(names):
        img = Image.fromarray(frames[n][0])
        sheet.alpha_composite(img, ((i % cols) * cw, (i // cols) * ch))
    sheet = sheet.resize((sheet.width * scale, sheet.height * scale), Image.NEAREST)
    sheet.save(path)


def main():
    styles = {"pet": pet4.build()}
    fx = effects.build()
    prev = None
    if "--preview" in sys.argv:
        prev = sys.argv[sys.argv.index("--preview") + 1]
    os.makedirs(OUT, exist_ok=True)
    for name, frames in styles.items():
        if not frames:
            continue
        pack(frames, os.path.join(OUT, f"{name}.png"), os.path.join(OUT, f"{name}.json"))
        if prev:
            preview(frames, os.path.join(prev, f"{name}.png"))
    pack(fx, os.path.join(OUT, "effects.png"), os.path.join(OUT, "effects.json"))
    if prev:
        preview(fx, os.path.join(prev, "effects.png"), scale=6, cols=8)
    print({k: len(v) for k, v in styles.items()}, "effects", len(fx))


if __name__ == "__main__":
    main()
