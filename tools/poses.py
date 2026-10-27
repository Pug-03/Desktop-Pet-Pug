"""Frames for the pet at full detail, built from art/parts (see extract.py).

Sprites keep soft anti-aliased edges; the app draws them with smooth scaling.
"""
import os

import numpy as np
from PIL import Image, ImageDraw

from extract import blend

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "art", "parts")

HIP = 214  # rows below this are legs on the front body
FACES = ["normal", "blink", "happy", "shy", "love", "surprised", "scared", "dizzy", "sleepy", "sleep", "yawn"]

PILLOW, PILLOW_S = (250, 250, 253, 255), (218, 222, 234, 255)
BLANKET, BLANKET_S, BLANKET_D, SHEET = (246, 172, 194, 255), (228, 142, 170, 255), (236, 112, 146, 255), (252, 246, 248, 255)
INK = (40, 28, 36, 255)


def load(name):
    return np.asarray(Image.open(os.path.join(RAW, name + ".png")).convert("RGBA")).copy()


def canvas(w, h):
    return np.zeros((h, w, 4), np.uint8)


class Pet:
    def __init__(self, outfit=0):
        """outfit 0 is the black suit from the character sheet; 1-16 come from outfits.py."""
        self.outfit = outfit
        self.hip = HIP if outfit != 16 else 283  # the long coat moves with the body, not the legs
        if outfit:
            self.front = {f: load(f"outfit{outfit}_{f}") for f in FACES}
        else:
            self.front = {f: load("front" if f == "normal" else f"front_{f}") for f in FACES}
        self.side = load("side")
        self.side_sleep = load("side_sleep")
        self.walk = [load(f"walk{i}") for i in range(8)]

    def stand(self, face="normal", bob=0, dx=0, legs=((0, 0), (0, 0))):
        src = self.front[face]
        h, w = src.shape[:2]
        pad = 12
        img = canvas(w + 2 * pad, h + pad)
        mid = w // 2
        for i, (ldx, lift) in enumerate(legs):
            part = np.zeros_like(src)
            cols = slice(0, mid) if i == 0 else slice(mid, None)
            part[self.hip - 4:, cols] = src[self.hip - 4:, cols]
            blend(img, part, pad + ldx, pad - lift)
        upper = src.copy()
        upper[self.hip:] = 0
        # soften the cut so the jacket hem blends over the legs
        upper[self.hip - 3:self.hip, :, 3] = (upper[self.hip - 3:self.hip, :, 3] * 0.98).astype(np.uint8)
        blend(img, upper, pad + dx, pad + bob)
        ax, ay = pad + mid, pad + h - 1
        return img, {"anchor": [ax, ay], "head": [ax + dx, pad + bob], "face": [ax + dx, pad + bob + 34]}

    def walk_frame(self, i):
        src = self.walk[i]
        h = src.shape[0]
        a = src[..., 3] > 128
        cols = np.where(a[int(h * 0.25):int(h * 0.55)].any(0))[0]
        tx = int(round((cols.min() + cols.max()) / 2))
        heads = np.where(a[:int(h * 0.12)].any(0))[0]
        hx = int(round((heads.min() + heads.max()) / 2))
        return src, {"anchor": [tx, h - 1], "head": [hx, 0], "face": [hx + 6, 34]}

    def lying(self, face, breath=0):
        """Asleep on his back under a blanket, head on a pillow (seen from the side)."""
        side = self.side_sleep if face in ("sleep", "sleepy", "blink") else self.side
        body = np.ascontiguousarray(np.rot90(side, 1))  # head left, face up
        ys, xs = np.where(body[..., 3] > 0)
        body = body[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
        bh, bw = body.shape[:2]
        pad_top, pad_l, pad_r = 14, 18, 8
        W, H = bw + pad_l + pad_r, bh + pad_top + 2
        ground = pad_top + bh

        # props are drawn 4x larger and scaled down, for smooth edges
        k = 4
        props = Image.new("RGBA", (W * k, H * k), (0, 0, 0, 0))
        d = ImageDraw.Draw(props)
        pcx, prx, pry = pad_l + 30, 40, 12
        d.ellipse([(pcx - prx) * k, (ground - 2 * pry) * k, (pcx + prx) * k, ground * k], fill=PILLOW, outline=INK, width=2 * k)
        d.ellipse([(pcx - prx + 6) * k, (ground - pry + 2) * k, (pcx + prx - 6) * k, (ground - 2) * k], fill=PILLOW_S)
        props = np.asarray(props.resize((W, H), Image.LANCZOS)).copy()

        out = canvas(W, H)
        blend(out, props, 0, 0)
        blend(out, body, pad_l, pad_top)

        # blanket follows the body's outline from the shoulders to the ankles and rises with each breath
        placed = np.zeros((H, W), bool)
        placed[pad_top:pad_top + bh, pad_l:pad_l + bw] = body[..., 3] > 128
        tops = np.array([np.argmax(placed[:, x]) if placed[:, x].any() else ground for x in range(W)], float)
        n = 25
        smooth = np.convolve(np.pad(tops, n // 2, mode="edge"), np.ones(n) / n, mode="valid")
        x0, x1 = pad_l + 56, pad_l + bw - 34  # up to the chin, so any outfit works under it
        top_at = smooth - 4 - breath * 2
        sheet = Image.new("RGBA", (W * k, H * k), (0, 0, 0, 0))
        d = ImageDraw.Draw(sheet)
        poly = [(x0 * k, ground * k)]
        for x in range(x0, x1 + 1, 2):
            rise = min(1.0, (x - x0) / 8, (x1 - x) / 8)
            y = ground - (ground - top_at[x]) * (0.4 + 0.6 * rise)
            poly.append((x * k, y * k))
        poly.append((x1 * k, ground * k))
        d.polygon(poly, fill=BLANKET)
        d.rectangle([x0 * k, (ground - 4) * k, x1 * k, ground * k], fill=BLANKET_S)
        d.polygon([(x0 * k, ground * k)] + [(x * k, y) for x, y in [(p[0] / k, p[1]) for p in poly[1:8]]] + [((x0 + 12) * k, ground * k)],
                  fill=SHEET)
        for i, hx in enumerate(range(x0 + 30, x1 - 12, 34)):
            hy = top_at[hx] + (12 if i % 2 else 22)
            if hy < ground - 10:
                r = 3.2 * k
                cx, cy = hx * k, hy * k
                d.ellipse([cx - 2 * r, cy - r, cx, cy + r], fill=BLANKET_D)
                d.ellipse([cx, cy - r, cx + 2 * r, cy + r], fill=BLANKET_D)
                d.polygon([(cx - 2 * r, cy + 0.2 * r), (cx + 2 * r, cy + 0.2 * r), (cx, cy + 2.6 * r)], fill=BLANKET_D)
        d.line(poly[1:-1], fill=INK, width=2 * k, joint="curve")
        d.line([poly[0], poly[1]], fill=INK, width=2 * k)
        d.line([poly[-2], poly[-1]], fill=INK, width=2 * k)
        sheet = np.asarray(sheet.resize((W, H), Image.LANCZOS)).copy()
        blend(out, sheet, 0, 0)
        return out, {"anchor": [W // 2, H - 1], "head": [pad_l + 30, pad_top], "face": [pad_l + 34, pad_top + 12]}


def build(outfit=0):
    p = Pet(outfit)
    F = {}
    for face in FACES:
        for b in (0, 1):
            F[f"stand.{face}.{b}"] = p.stand(face, bob=b * 2)
    for i in range(8):
        if outfit == 0:
            F[f"walk.normal.{i}"] = p.walk_frame(i)
        else:
            # the outfit sheet only has a front view: walk facing the viewer, stepping in turn
            s = np.sin(i / 8 * 2 * np.pi)
            F[f"walk.normal.{i}"] = p.stand("normal", bob=[0, 1, 2, 1][i % 4], dx=[0, 1, 0, -1, 0, -1, 0, 1][i],
                                            legs=((0, int(round(max(0, s) * 8))), (0, int(round(max(0, -s) * 8)))))
        F[f"walk.blink.{i}"] = F[f"walk.normal.{i}"]
    for i, (dx, b) in enumerate(((-2, 0), (2, 2), (-2, 0), (2, 2))):
        F[f"laugh.{i}"] = p.stand("happy", bob=b, dx=dx, legs=((0, 3 * (i == 1)), (0, 3 * (i == 3))))
    kicks = [((0, 0), (0, 7)), ((-2, 5), (2, 0)), ((0, 7), (0, 0)), ((2, 0), (-2, 5))]
    for face in ("surprised", "scared", "happy", "dizzy"):
        for i in range(4):
            F[f"held.{face}.{i}"] = p.stand(face, legs=kicks[i])
    for i in range(4):
        F[f"fall.{i}"] = p.stand("scared", legs=((-4, 3 + 2 * (i % 2)), (4, 5 - 2 * (i % 2))))
    for i, dx in enumerate((-2, 0, 2, 0)):
        F[f"dizzy.{i}"] = p.stand("dizzy", dx=dx)
    for i, (face, b) in enumerate((("sleepy", 0), ("yawn", -2), ("yawn", -2), ("sleepy", 0))):
        F[f"yawn.{i}"] = p.stand(face, bob=b)
    for i in range(2):
        F[f"rub.{i}"] = p.stand("sleepy" if i == 0 else "blink")
        F[f"wave.{i}"] = p.stand("happy" if i == 0 else "normal", bob=2 * i)
        F[f"wave.shy.{i}"] = p.stand("shy", bob=2 * i)
        F[f"shy.{i}"] = p.stand("shy", bob=2 * i)
        F[f"love.{i}"] = p.stand("love", bob=2 * i)
    for face in ("sleep", "sleepy", "normal", "blink"):
        for b in (0, 1):
            F[f"sit.{face}.{b}"] = p.lying(face, breath=b)
    return F
