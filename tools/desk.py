"""The pet working at his desk: cut the six seated poses from reference/desk.png.

The two bottom rows of the sheet have twelve poses (TYPE 1 ... STRETCH), each with the same
black desk, chair and MacBook. The sheet's drawn "z z" and "!" marks are dropped; the app
animates its own. The cells are lined up on the desk (so switching poses never
shakes the furniture) and scaled to match the standing sprites.
Writes art/parts/desk_<pose>.png
"""
import os

import numpy as np
from PIL import Image

from extract import components, erode, resize

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHEET = os.path.join(ROOT, "reference", "desk.png")
OUT = os.path.join(ROOT, "art", "parts")
ROWS = [(728, 956), (990, 1206)]
CELLS = [
    [("type1", 18, 217), ("type2", 230, 419), ("think", 432, 621), ("lookup", 636, 824), ("turn", 838, 1029), ("sleep", 1042, 1233)],
    [("happy", 23, 211), ("surprised", 229, 417), ("angry", 435, 622), ("drink", 851, 1035), ("stretch", 1055, 1229)],
]
SCALE = 0.85  # heads come out the same size as on the standing sprites


def small_holes(mask, max_size=40):
    """Fill specks of background inside the figure, but keep real gaps (under the desk, between
    the chair and the body) see-through."""
    out = mask.copy()
    for hole in components(~mask, 1):
        if hole.sum() <= max_size:
            out |= hole
    return out


def cell(a, x0, x1, y0, y1):
    sub = a[y0:y1, x0:x1].astype(int)
    bg = np.median(np.concatenate([sub[:, :3], sub[:, -3:]], 1).reshape(-1, 3), 0)
    lum = .3 * sub[..., 0] + .59 * sub[..., 1] + .11 * sub[..., 2]
    # soft floor shadow under the desk (lighter than the dark blue-grey table top)
    shadow = (sub[..., 2] - sub[..., 0] >= 6) & (lum > 130)
    m = (np.abs(sub - bg).sum(2) > 34) & ~shadow
    # the desk and the person are one piece; the floating "z z" of the sleep pose is not
    m = max(components(m, 50), key=lambda c: c.sum())
    m = small_holes(m)
    # the sheet draws a light sticker outline round everything: peel light pixels off the edge
    light = (lum > 135) & (sub.max(2) - sub.min(2) < 30)
    for _ in range(3):
        m &= ~(light & ~erode(m))
    m = erode(m)
    rgba = np.zeros(sub.shape[:2] + (4,), np.uint8)
    rgba[..., :3] = sub
    rgba[..., 3] = m * 255
    return rgba


def desk_marks(c):
    """Table-top row (the widest row), the table's left edge on it, and the floor row."""
    m = c[..., 3] > 128
    top = int(np.argmax(m.sum(1)))
    return top, int(np.where(m[top])[0].min()), int(np.where(m.any(1))[0].max())


def main():
    a = np.asarray(Image.open(SHEET).convert("RGB"))
    cuts = [(name, cell(a, x0, x1, *ROWS[r])) for r, row in enumerate(CELLS) for name, x0, x1 in row]
    # the second row is drawn a little smaller: scale every cell to the first one's desk height,
    # then line the cells up on the table's top-left corner
    top0, _, floor0 = desk_marks(cuts[0][1])
    placed = []
    for name, c in cuts:
        top, left, floor = desk_marks(c)
        k = (floor0 - top0) / (floor - top)
        if abs(k - 1) > 0.01:
            c = resize(c, k)
            top, left, floor = desk_marks(c)
        placed.append((name, c, top, left))
    up = max(t for _, _, t, _ in placed)
    lf = max(l for _, _, _, l in placed)
    h = max(c.shape[0] - t for _, c, t, _ in placed) + up
    w = max(c.shape[1] - l for _, c, _, l in placed) + lf
    aligned = []
    for name, c, t, l in placed:
        img = np.zeros((h, w, 4), np.uint8)
        img[up - t:up - t + c.shape[0], lf - l:lf - l + c.shape[1]] = c
        aligned.append((name, img))
    # one shared crop box so every pose keeps the same anchor
    alpha = np.any([im[..., 3] > 0 for _, im in aligned], 0)
    ys, xs = np.where(alpha)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    os.makedirs(OUT, exist_ok=True)
    for name, im in aligned:
        Image.fromarray(resize(im[y0:y1, x0:x1], SCALE)).save(os.path.join(OUT, f"desk_{name}.png"))
    print("desk poses", len(aligned))


if __name__ == "__main__":
    main()
