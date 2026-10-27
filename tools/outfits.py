"""Outfits: swap the pet's top (shirt / jacket) for one from reference/outfits.png.

Only the top changes: the pet keeps its own head and expressions, trousers and shoes.
Writes art/parts/outfit<N>_<face>.png for every outfit and front-facing expression.
"""
import os

import numpy as np
from PIL import Image

from extract import blend, components, cut, luminance, resize

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "reference", "outfits.png")
PARTS = os.path.join(ROOT, "art", "parts")

NAMES = ["เสื้อยืดดำ", "เสื้อยืดขาว", "เสื้อโปโล", "เสื้อลายขวาง", "ฮู้ด", "สเวตเตอร์", "เชิ้ตแขนสั้น", "เชิ้ตแขนยาว",
         "แจ็กเก็ตสีอ่อน", "แจ็กเก็ตสีเข้ม", "คาร์ดิแกน", "ฮู้ดซิป", "สเวตเชิ้ต", "เสื้อกั๊ก", "โอเวอร์เชิ้ต", "โค้ทยาว"]
COLS = [(40, 172), (234, 365), (431, 561), (617, 745), (799, 932), (985, 1111), (1173, 1306), (1367, 1491)]
ROWS = [(96, 528), (572, 1004)]
FACES = ["normal", "blink", "happy", "shy", "love", "surprised", "scared", "dizzy", "sleepy", "sleep", "yawn"]

HIP = 214        # below this the pet keeps its own trousers and shoes
NECK = 48        # rows above this are the head
COAT_HEM = 0.80  # the long coat covers the trousers down to here (fraction of height)


def is_skin(img):
    rgb = img[..., :3].astype(int)
    return (img[..., 3] > 0) & (rgb[..., 0] - rgb[..., 2] > 25) & (luminance(img) > 70)


def grow(m, n=1):
    for _ in range(n):
        g = m.copy()
        g[1:] |= m[:-1]
        g[:-1] |= m[1:]
        g[:, 1:] |= m[:, :-1]
        g[:, :-1] |= m[:, 1:]
        m = g
    return m


def shrink(m, n=1):
    return ~grow(~m, n)


def edges(a):
    return a & ~(np.roll(a, 1, 0) & np.roll(a, -1, 0) & np.roll(a, 1, 1) & np.roll(a, -1, 1))


def matte(img, bg, depth=3):
    """Clean the outline after scaling: drop faint pixels, then for the outer `depth` rings
    replace any pixel tinted by the sheet background with its inner neighbours' colour."""
    img[img[..., 3] < 100] = 0
    a = img[..., 3] > 0
    ring = a & ~shrink(a, depth)
    c = img[..., :3].astype(int)
    blue = c[..., 2] - c[..., 0]
    tinted = (np.abs(c - np.array(bg)).sum(2) < 90) | ((blue > 10) & (blue < 35) & (c.max(2) - c.min(2) < 35))
    bad = ring & (tinted | edges(a))
    for _ in range(depth + 1):
        if not bad.any():
            break
        bad = _fill_from_neighbours(img, bad)
    img[edges(a), 3] = 255
    return img


def _fill_from_neighbours(img, bad):
    """One pass: give every bad pixel the mean colour of its good opaque neighbours."""
    a = img[..., 3] > 0
    good = a & ~bad
    rgb = img[..., :3].astype(float)
    acc = np.zeros_like(rgb)
    cnt = np.zeros(a.shape)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            m = np.roll(np.roll(good, dy, 0), dx, 1)
            acc += np.roll(np.roll(rgb, dy, 0), dx, 1) * m[..., None]
            cnt += m
    fix = bad & (cnt > 0)
    img[fix, :3] = (acc[fix] / cnt[fix][:, None]).astype(np.uint8)
    return bad & ~fix


def figures():
    rgb = np.asarray(Image.open(SRC).convert("RGB"))
    out = []
    for y0, y1 in ROWS:
        for x0, x1 in COLS:
            sub = rgb[y0:y1, x0 - 6:x1 + 6]
            bg = np.median(np.concatenate([sub[:, :3].reshape(-1, 3), sub[:, -3:].reshape(-1, 3)]), axis=0)
            a = sub.astype(int)
            # colour distance plus a chroma term: the light blue shirt is close to the
            # sheet's blue-grey in brightness but is bluer and more saturated
            sat = a.max(2) - a.min(2)
            bsat = bg.max() - bg.min()
            diff = (np.abs(a - bg).sum(2) > 28) | (sat - bsat > 14)
            m = np.zeros(sub.shape[:2], bool)
            for c in components(diff, 300):
                m |= c
            m = shrink(grow(m, 1), 1)  # close 1-px bites along the outline
            # slivers of sheet background (e.g. between arm and body) must stay see-through
            tint = (a[..., 2] - a[..., 0]) - (bg[2] - bg[0])
            m &= ~((np.abs(a - bg).sum(2) < 75) & (np.abs(tint) < 10) & (sat <= bsat + 4))
            # shave 1-px spikes so the silhouette stays smooth
            for _ in range(2):
                n8 = sum(np.roll(np.roll(m, j, 0), i, 1) for j in (-1, 0, 1) for i in (-1, 0, 1)) - m
                m &= n8 > 2
            fig = cut(sub, m)
            out.append((fig, tuple(int(v) for v in bg)))
    return out


def torso_center(img):
    h = img.shape[0]
    a = img[int(h * 0.3):int(h * 0.5), :, 3] > 128
    xs = np.where(a.any(0))[0]
    return (xs.min() + xs.max()) / 2


def suit_mask(front):
    """Pixels of the pet's own suit/tee around the neck (dark and grey, below the chin)."""
    rgb = front[..., :3].astype(int)
    sat = rgb.max(2) - rgb.min(2)
    yy = np.arange(front.shape[0])[:, None]
    return (front[..., 3] > 0) & (luminance(front) < 85) & (sat < 30) & (yy >= 46)


def dress(front_face, legs_src, top, coat=False):
    """front_face: the pet's front image with an expression; top: outfit figure scaled to match."""
    h, w = front_face.shape[:2]
    pad = 30
    W = w + 2 * pad
    out = np.zeros((h, W, 4), np.uint8)
    ox = int(round(pad + torso_center(legs_src) - torso_center(top)))
    oy = h - top.shape[0]
    cut_row = int(h * COAT_HEM) if coat else HIP

    legs = legs_src.copy()
    legs[:HIP - 10] = 0  # overlap the cut so the faded hem blends into trousers, not background
    # near the cut keep only the trousers: the suit's hands and jacket hem sit beside them
    ref = np.where(legs_src[HIP + 20, :, 3] > 128)[0]
    x0, x1 = ref.min(), ref.max()
    xs = np.arange(w)[None, :]
    legs[HIP - 10:HIP + 20][((xs < x0) | (xs > x1))[0][None, :].repeat(30, 0)] = 0
    near = legs[HIP - 10:HIP + 20]
    near[is_skin(near)] = 0
    blend(out, legs, pad, 0)

    upper = top.copy()
    upper[cut_row - oy:] = 0
    # fade the hem into the trousers only where trousers are underneath; elsewhere keep it crisp
    under = np.zeros(upper.shape[:2], bool)
    for r in range(upper.shape[0]):
        y = r + oy
        if 0 <= y < h:
            cols = np.arange(upper.shape[1]) + ox - pad
            ok = (cols >= 0) & (cols < w)
            under[r, ok] = legs[y, cols[ok], 3] > 0
    for i in range(6):
        r = cut_row - oy - 6 + i
        if 0 <= r < upper.shape[0]:
            fade = (1 - (i + 1) / 7)
            upper[r, under[r], 3] = (upper[r, under[r], 3] * fade).astype(np.uint8)
    upper[: NECK - oy] = 0  # the outfit sheet's own head
    blend(out, upper, ox, oy)

    # the pet's head and neck: everything opaque above the collar except its own suit
    head = front_face.copy()
    yy = np.arange(h)[:, None]
    keep = (head[..., 3] > 0) & (yy < 70) & ~suit_mask(front_face)
    head[~keep] = 0
    head_on = np.zeros((h, W), bool)
    head_on[:, pad:pad + w] = keep
    blend(out, head, pad, 0)

    # the outfit's neckline (collar, hood) goes over the neck, never over the chin
    collar = top.copy()
    skin = is_skin(collar)
    garment = (collar[..., 3] > 0) & ~grow(skin, 2)
    garment = grow(shrink(garment, 1), 1)  # thin contour lines (the sheet's jaw/chin) drop out
    cy = np.arange(collar.shape[0])[:, None] + oy
    garment &= (cy >= NECK + 2) & (cy <= 80)
    collar[~garment] = 0
    placed = np.zeros((h, W, 4), np.uint8)
    blend(placed, collar, ox, oy)
    chin = head_on & (yy < 54)
    placed[chin] = 0
    # a soft shadow on the neck just above the collar line
    c_on = placed[..., 3] > 0
    above = np.roll(c_on, -1, 0) & ~c_on & head_on
    for k in (1, 2):
        sh = np.roll(c_on, -k, 0) & ~c_on & head_on & (out[..., 3] > 0)
        out[sh, :3] = (out[sh, :3] * (0.82 if k == 1 else 0.9)).astype(np.uint8)
    _ = above
    blend(out, placed, 0, 0)

    # light gaps inside the fists (sheet background showing through the curled fingers)
    hand = out[180:215]
    a = hand[..., 3] > 0
    light = a & (luminance(hand) > 185) & (hand[..., 2].astype(int) - hand[..., 0].astype(int) > 0)
    hand[light, :3] = (150, 100, 78)

    # a soft dark outline all round, like the suit art has
    a = out[..., 3] > 0
    ring = grow(a, 1) & ~a
    out[ring] = (30, 30, 34, 70)
    return out, pad


def main():
    front = {f: np.asarray(Image.open(os.path.join(PARTS, "front" if f == "normal" else f"front_{f}") + ".png")).copy()
             for f in FACES}
    base = front["normal"]
    tops = figures()
    for n, (fig, bg) in enumerate(tops, 1):
        top = matte(resize(fig, size=(round(fig.shape[1] * base.shape[0] / fig.shape[0]), base.shape[0])), bg)
        for face in FACES:
            img, _ = dress(front[face], base, top, coat=(n == 16))
            Image.fromarray(img).save(os.path.join(PARTS, f"outfit{n}_{face}.png"))
    print("outfits:", len(tops))


if __name__ == "__main__":
    main()
