"""Cut the pet out of reference/sheet3.png and reference/expressions.png at full detail.

Nothing is pixelated or colour-reduced: figures keep their original pixels, are scaled once
to a common working size (WORK_H pixels for a standing body) with smooth resampling,
and keep soft anti-aliased edges. Each expression head from the expression sheet is fitted
onto the front body (and the closed-eye profile onto the side body).

Writes art/parts/*.png
"""
import os

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHEET = os.path.join(ROOT, "reference", "sheet3.png")
EXPR = os.path.join(ROOT, "reference", "expressions.png")
OUT = os.path.join(ROOT, "art", "parts")
WORK_H = 354  # standing body height in the app's sprites (0.6 of the sheet)

PANELS = {"front": (5, 40, 265, 648), "back": (270, 40, 520, 648), "side": (526, 40, 742, 648)}
WALK = (12, 688, 928, 932)
EXPRESSIONS = {
    "blink": (18, 58, 304, 371), "happy": (319, 58, 608, 371), "shy": (622, 58, 911, 371),
    "love": (926, 58, 1214, 371), "surprised": (1230, 58, 1517, 371),
    "scared": (18, 430, 304, 714), "dizzy": (319, 430, 608, 714), "sleepy": (622, 430, 911, 714),
    "yawn": (926, 430, 1214, 714), "sleep": (1230, 430, 1517, 714),
    "side_sleep": (1230, 766, 1517, 1007),
}


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


def mask_from_bg(a, bg, tol=40):
    a = a.astype(int)
    r, b = a[..., 0], a[..., 2]
    lum = .3 * a[..., 0] + .59 * a[..., 1] + .11 * b
    shadow = (b - r >= 6) & (lum > 95)
    return (np.abs(a - np.array(bg)).sum(2) > tol) & ~shadow


def erode(m):
    out = m.copy()
    out[1:] &= m[:-1]
    out[:-1] &= m[1:]
    out[:, 1:] &= m[:, :-1]
    out[:, :-1] &= m[:, 1:]
    return out


def white_rim(rgb, mask, top=0.15):
    """The sheets draw a thin white sticker outline round the figure. Outside it is trimmed by
    erode(), but where the outline runs into a narrow enclosed gap (between arm and body, inside
    a curled fist) it was kept, with a sliver of blue-grey sheet background inside it, and both
    showed as light slivers on a dark desktop. Those are thin, upright patches of light grey or
    light blue-grey; wide patches (white sneakers, a white or light-blue shirt) and flat ones
    (a white stripe at a sleeve hem) and specks shorter than 5 px (the soft edges of navy
    stripes) are kept. Rows above `top` (the face) are left alone."""
    c = rgb.astype(int)
    lum, sat = luminance(rgb), c.max(2) - c.min(2)
    body = mask.copy()
    body[: int(top * mask.shape[0])] = False
    bluish = body & (lum > 110) & (c[..., 2] - c[..., 0] >= 8) & (sat < 45)
    grey = body & (lum > 140) & (sat < 25)
    out = np.zeros_like(mask)
    for light in (bluish, grey & ~bluish):  # background first, so the rim beside a white shirt separates
        core = erode(erode(light))  # survives only where a patch is wider than 4 px
        for comp in components(light & ~out, 1):
            ys, xs = np.where(comp)
            h, w = np.ptp(ys) + 1, np.ptp(xs) + 1
            if not (comp & core).any() and h >= 5 and h >= 0.8 * w:
                out |= comp
    return out


def cut(rgb, mask, rim=False):
    """Crop the figure. With `rim`, the sheet's white outline is also cleared inside enclosed
    gaps (see white_rim), so it never shows as light slivers on a dark desktop."""
    ys, xs = np.where(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    m = fill_holes(mask[y0:y1, x0:x1])
    if rim:
        m &= ~white_rim(rgb[y0:y1, x0:x1], m)
    m = erode(m)  # drop the background-tinted fringe (also round the cleared gaps)
    rgba = np.zeros((y1 - y0, x1 - x0, 4), np.uint8)
    rgba[..., :3] = rgb[y0:y1, x0:x1]
    rgba[..., 3] = m * 255
    return rgba


def resize(rgba, scale=None, size=None):
    """Smooth resample with premultiplied alpha; soft edges are kept."""
    h, w = rgba.shape[:2]
    nw, nh = size or (max(1, round(w * scale)), max(1, round(h * scale)))
    a = rgba[..., 3:4].astype(np.float32) / 255
    pre = np.concatenate([rgba[..., :3] * a, a * 255], 2).astype(np.float32)
    ch = [np.asarray(Image.fromarray(pre[..., i]).resize((nw, nh), Image.LANCZOS)) for i in range(4)]
    al = np.clip(ch[3], 0, 255) / 255
    out = np.zeros((nh, nw, 4), np.uint8)
    for i in range(3):
        out[..., i] = np.clip(np.where(al > 0.004, ch[i] / np.maximum(al, 1e-6), 0), 0, 255)
    out[..., 3] = np.clip(ch[3], 0, 255)
    out[out[..., 3] < 8] = 0
    return out


def blend(dst, src, x, y):
    """Alpha-composite src over dst at integer offset."""
    sh, sw = src.shape[:2]
    dh, dw = dst.shape[:2]
    sx0, sy0, dx0, dy0 = max(0, -x), max(0, -y), max(0, x), max(0, y)
    w, h = min(sw - sx0, dw - dx0), min(sh - sy0, dh - dy0)
    if w <= 0 or h <= 0:
        return
    s = src[sy0:sy0 + h, sx0:sx0 + w].astype(np.float32)
    d = dst[dy0:dy0 + h, dx0:dx0 + w].astype(np.float32)
    sa, da = s[..., 3:4] / 255, d[..., 3:4] / 255
    oa = sa + da * (1 - sa)
    oc = (s[..., :3] * sa + d[..., :3] * da * (1 - sa)) / np.maximum(oa, 1e-6)
    dst[dy0:dy0 + h, dx0:dx0 + w, :3] = np.clip(oc, 0, 255)
    dst[dy0:dy0 + h, dx0:dx0 + w, 3] = np.clip(oa[..., 0] * 255, 0, 255)


def head_metrics(rgba, max_rows):
    """Top of the hair, and the head's widest span (ear to ear) in the first max_rows rows."""
    m = rgba[..., 3] > 128
    rows = np.where(m.any(1))[0]
    top = rows.min()
    best = (0, 0, 0)
    for y in range(top, min(top + max_rows, m.shape[0])):
        xs = np.where(m[y])[0]
        if len(xs) and xs.max() - xs.min() > best[0]:
            best = (xs.max() - xs.min() + 1, (xs.max() + xs.min()) / 2, y)
    return top, best[0], best[1]


def flood(mask, seeds):
    """Pixels of `mask` 4-connected to any seed."""
    out = np.zeros_like(mask)
    stack = [(y, x) for y, x in seeds if mask[y, x]]
    for y, x in stack:
        out[y, x] = True
    h, w = mask.shape
    while stack:
        y, x = stack.pop()
        for dy_, dx_ in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy_, x + dx_
            if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not out[ny, nx]:
                out[ny, nx] = True
                stack.append((ny, nx))
    return out


def luminance(img):
    rgb = img[..., :3].astype(float)
    return rgb[..., 0] * .3 + rgb[..., 1] * .59 + rgb[..., 2] * .11


def neck_span(img, row):
    """Leftmost and rightmost skin pixel on a row (skin: opaque, reddish, not dark)."""
    rgb = img[row, :, :3].astype(int)
    skin = (img[row, :, 3] > 128) & (rgb[:, 0] - rgb[:, 2] > 25) & (luminance(img[row:row + 1])[0] > 70)
    xs = np.where(skin)[0]
    return (xs.min(), xs.max()) if len(xs) else None


def fit_head(body, head_img, collar_row, dy=3):
    """Replace the body's head and neck with an expression head.

    Layers, bottom to top: the body's own neck (as a filler under any gap), the new head with
    its neck (source jacket removed, slid sideways so its neck lines up with the body's neck,
    and trimmed to the body's neck width near the collar), then the body's jacket, which keeps
    its real collar shape (also the diagonal collar at the back in the side view).
    """
    btop, bw, bcx = head_metrics(body, int(collar_row * 0.7))
    h = head_img.copy()
    H, W = h.shape[:2]
    dark = (luminance(h) < 75) & (h[..., 3] > 0)
    dark[: int(H * 0.5)] = False
    # the source jacket: dark area reaching the bottom; an open mouth is dark but enclosed
    seeds = [(y, x) for y in range(int(H * 0.96), H) for x in range(W)]
    h[flood(dark, seeds)] = 0
    etop, ew, ecx = head_metrics(h, int(H * 0.5))
    s = bw / ew
    head = resize(h, s)
    ox = int(round(bcx - ecx * s))
    oy = int(round(btop - etop * s)) + dy

    # slide sideways so the new neck sits on the body's neck (tilted heads)
    ref = collar_row - 3
    bspan = neck_span(body, ref)
    if bspan and 0 <= ref - oy < head.shape[0]:
        hspan = neck_span(head, ref - oy)
        if hspan:
            ox += int(round((bspan[0] + bspan[1]) / 2 - (hspan[0] + hspan[1]) / 2 - ox))

    keep = collar_row + 8 - oy
    if 0 < keep < head.shape[0]:
        head = head[:keep].copy()
    # near the collar, keep the new neck inside the body's neck and drop source-jacket leftovers
    for r in range(max(0, collar_row - 6 - oy), head.shape[0]):
        y = oy + r
        span = neck_span(body, min(y, body.shape[0] - 1))
        row = head[r]
        xs = np.arange(head.shape[1]) + ox
        if span:
            row[(xs < span[0]) | (xs > span[1])] = 0
        row[luminance(head[r:r + 1])[0] < 75] = 0

    body_lum = luminance(body)
    yy = np.arange(body.shape[0])[:, None]
    jacket_dark = (body[..., 3] > 0) & (body_lum < 75) & (yy >= collar_row - 14)
    jacket = flood(jacket_dark, [(body.shape[0] - 1, x) for x in range(body.shape[1])])
    rest = body.copy()
    rest[(yy < collar_row) & ~jacket] = 0  # old head, hair and neck gone; the collar stays

    # drop stray specks: opaque head pixels with fewer than 3 opaque neighbours
    a = head[..., 3] > 0
    nb = sum(np.roll(np.roll(a, j, 0), i, 1) for j in (-1, 0, 1) for i in (-1, 0, 1)) - a
    head[a & (nb < 3)] = 0

    filler = body.copy()
    filler[: collar_row - 7] = 0
    filler[luminance(filler) < 80] = 0  # skin only: the old neck's dark outline would peek out beside tilted jaws
    out = np.zeros_like(body)
    blend(out, filler, 0, 0)
    blend(out, head, ox, oy)
    blend(out, rest, 0, 0)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    rgb = np.asarray(Image.open(SHEET).convert("RGB"))
    bg = (191, 197, 204)
    figs = {}
    for name, (x0, y0, x1, y1) in PANELS.items():
        sub = rgb[y0:y1, x0:x1]
        m = np.zeros(sub.shape[:2], bool)
        for c in components(mask_from_bg(sub, bg, 34), 400):
            m |= c
        figs[name] = cut(sub, m, rim=True)
    scale = WORK_H / figs["front"].shape[0]
    work = {k: resize(v, scale) for k, v in figs.items()}

    sub = rgb[WALK[1]:WALK[3], WALK[0]:WALK[2]]
    comps = components(mask_from_bg(sub, bg, 34), 150)
    comps.sort(key=lambda c: np.where(c)[1].mean())
    frames = []
    for c in comps:
        cx = np.where(c)[1].mean()
        if frames and abs(frames[-1][0] - cx) < 45:
            frames[-1] = (frames[-1][0], frames[-1][1] | c)
        else:
            frames.append((cx, c))
    walk = [cut(sub, c, rim=True) for _, c in frames]
    ws = WORK_H / max(f.shape[0] for f in walk)
    for i, f in enumerate(walk):
        work[f"walk{i}"] = resize(f, ws)

    # expressions
    ergb = np.asarray(Image.open(EXPR).convert("RGB"))
    ebg = (188, 199, 211)
    front, side = work["front"], work["side"]
    fh = front.shape[0]
    collar_front = 57  # first row of the jacket collar on the front body
    collar_side = 60
    sources = {name: (ergb, box, ebg) for name, box in EXPRESSIONS.items()}
    yawn = np.asarray(Image.open(os.path.join(ROOT, "reference", "yawn.jpg")).convert("RGB"))
    sources["yawn"] = (yawn, (12, 145, 883, 1000), tuple(int(v) for v in yawn[300, 60]))
    for name, (img, (x0, y0, x1, y1), bgc) in sources.items():
        sub = img[y0:y1, x0:x1]
        comps = components(mask_from_bg(sub, bgc, 45), 2000)
        biggest = max(comps, key=lambda c: c.sum())
        head = cut(sub, biggest)
        if name == "side_sleep":
            head = np.ascontiguousarray(head[:, ::-1])  # drawn facing left; the body faces right
            work[name] = fit_head(side, head, collar_side)
        else:
            work[f"front_{name}"] = fit_head(front, head, collar_front)

    for n, img in work.items():
        Image.fromarray(img).save(os.path.join(OUT, f"{n}.png"))
    print({n: img.shape[:2] for n, img in work.items()})


if __name__ == "__main__":
    main()
