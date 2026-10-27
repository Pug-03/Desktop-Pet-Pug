"""Cut the figures out of reference/sheet3.png and resample them all onto one pixel grid.

Writes art/raw3/front.png, back.png, side.png, walk0..7.png and head_hi.png (for expression work).
Every figure is scaled so a standing body is TARGET_H pixels tall, so all share the same pixel size.
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from pixel import quantize  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "reference", "sheet3.png")
OUT = os.path.join(ROOT, "art", "raw3")
TARGET_H = 168

# panel boxes (x0, y0, x1, y1) in the 1254x1254 sheet, below the panel labels
PANELS = {
    "front": (5, 40, 265, 648),
    "back": (270, 40, 520, 648),
    "side": (526, 40, 742, 648),
}
WALK = (12, 688, 928, 932)


def figure_mask(a):
    """Everything that is not sheet background or the soft floor shadow."""
    a = a.astype(int)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    bg = np.array([191, 197, 204])
    diff = np.abs(a - bg).sum(2)
    lum = .3 * r + .59 * g + .11 * b
    shadow = (b - r >= 6) & (lum > 95)          # blue-grey floor shadow / panel lines
    return (diff > 34) & ~shadow


def components(mask, min_size):
    """Label 8-connected components (simple flood fill), return list of boolean masks."""
    h, w = mask.shape
    seen = np.zeros_like(mask)
    out = []
    for y0, x0 in zip(*np.where(mask)):
        if seen[y0, x0]:
            continue
        stack = [(y0, x0)]
        seen[y0, x0] = True
        pts = []
        while stack:
            y, x = stack.pop()
            pts.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
        if len(pts) >= min_size:
            m = np.zeros_like(mask)
            ys, xs = zip(*pts)
            m[list(ys), list(xs)] = True
            out.append(m)
    return out


def fill_holes(mask):
    """Close small gaps inside the figure (e.g. white shoe areas near the background colour)."""
    h, w = mask.shape
    outside = np.zeros_like(mask)
    stack = [(y, x) for y in (0, h - 1) for x in range(w) if not mask[y, x]]
    stack += [(y, x) for x in (0, w - 1) for y in range(h) if not mask[y, x]]
    for y, x in stack:
        outside[y, x] = True
    while stack:
        y, x = stack.pop()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and not mask[ny, nx] and not outside[ny, nx]:
                outside[ny, nx] = True
                stack.append((ny, nx))
    return ~outside


def cut(rgb, mask):
    ys, xs = np.where(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    m = fill_holes(mask[y0:y1, x0:x1])
    rgba = np.zeros((y1 - y0, x1 - x0, 4), np.uint8)
    rgba[..., :3] = rgb[y0:y1, x0:x1]
    rgba[..., 3] = m * 255
    return rgba


def resample(rgba, scale):
    """Area-average with premultiplied alpha, then hard alpha: crisp pixels at the new size."""
    h, w = rgba.shape[:2]
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    a = rgba[..., 3:4].astype(float) / 255
    pre = np.concatenate([rgba[..., :3] * a, a * 255], 2).astype(np.float32)
    chans = [np.asarray(Image.fromarray(pre[..., i]).resize((nw, nh), Image.BOX)) for i in range(4)]
    alpha = chans[3] / 255
    out = np.zeros((nh, nw, 4), np.uint8)
    keep = alpha >= 0.5
    for i in range(3):
        out[..., i] = np.clip(np.where(alpha > 0, chans[i] / np.maximum(alpha, 1e-6), 0), 0, 255)
    out[..., 3] = keep * 255
    out[~keep, :3] = 0
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    rgb = np.asarray(Image.open(SRC).convert("RGB"))
    figs = {}
    for name, (x0, y0, x1, y1) in PANELS.items():
        sub = rgb[y0:y1, x0:x1]
        comps = components(figure_mask(sub), 400)
        m = np.zeros(sub.shape[:2], bool)
        for c in comps:
            m |= c
        figs[name] = cut(sub, m)
    scale = TARGET_H / figs["front"].shape[0]

    x0, y0, x1, y1 = WALK
    sub = rgb[y0:y1, x0:x1]
    comps = components(figure_mask(sub), 150)
    # group components into the 8 frames by horizontal position
    comps.sort(key=lambda c: np.where(c)[1].mean())
    frames = []
    for c in comps:
        cx = np.where(c)[1].mean()
        if frames and abs(frames[-1][0] - cx) < 45:
            frames[-1] = (frames[-1][0], frames[-1][1] | c)
        else:
            frames.append((cx, c))
    walk = [cut(sub, c) for _, c in frames]
    print("walk frames:", len(walk))
    walk_scale = TARGET_H / max(f.shape[0] for f in walk)

    out = {k: resample(v, scale) for k, v in figs.items()}
    for i, f in enumerate(walk):
        out[f"walk{i}"] = resample(f, walk_scale)
    names = list(out)
    q = quantize([out[n] for n in names], 40)
    for n, img in zip(names, q):
        Image.fromarray(img).save(os.path.join(OUT, f"{n}.png"))
        print(n, img.shape[1], "x", img.shape[0])


if __name__ == "__main__":
    main()
