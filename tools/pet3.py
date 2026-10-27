"""Frames for the pet, built from art/raw3 (extracted from reference/sheet3.png by extract3.py).

All sprites share one pixel grid; expressions and props are drawn on that same grid.
"""
import os

import numpy as np
from PIL import Image

from pixel import alpha, canvas, outline, paste, rot90

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "art", "raw3")

OUTLINE = (24, 18, 22)
EYE = (30, 22, 24)
MOUTH, MOUTH_IN, TONGUE = (120, 50, 48), (90, 30, 34), (226, 112, 112)
BLUSH = (238, 132, 122)
HEART = (236, 64, 92)
SWEAT, SWEAT_L = (130, 190, 250), (225, 242, 255)
PILLOW, PILLOW_S = (250, 250, 253), (214, 218, 232)
BLANKET, BLANKET_S, BLANKET_D = (246, 170, 192), (226, 140, 168), (236, 112, 146)
SHEET = (252, 246, 248)

# face landmarks on front.png
EYE_L, EYE_R = (23, 14), (30, 14)   # centre pixel of each eye
MOUTH_C = (27, 21)                   # centre of the mouth line
CHEEKS = [(21, 18), (32, 18)]
HIP = 102                            # rows below this are legs (front view)

EYES = {
    "blink": ["###"],
    "happy": [".#.",
              "#.#"],
    "closed": ["#.#",
               ".#."],
    "squeeze": ["#..",
                ".##",
                "#.."],
    "cross": ["#.#",
              ".#.",
              "#.#"],
    "sleepy": ["###",
               ".#."],
    "heart": ["#.#",
              "###",
              ".#."],
}
MOUTHS = {
    "smile": ["#...#",
              ".###."],
    "laugh": ["#####",
              "#ttt#",
              ".###."],
    "o": ["###",
          "#m#",
          "###"],
    "wavy": [".#.#.",
             "#.#.#"],
    "yawn": [".###.",
             "#mmm#",
             "#mtm#",
             ".###."],
    "flat": ["###"],
    "sleep": ["#"],
}
FACES = {
    # eyes, mouth, blush, sweat
    "normal": (None, None, False, False),
    "blink": ("blink", None, False, False),
    "happy": ("happy", "laugh", True, False),
    "shy": ("happy", "smile", True, False),
    "love": ("heart", "smile", True, False),
    "surprised": (None, "o", False, False),
    "scared": ("squeeze", "wavy", False, True),
    "dizzy": ("cross", "wavy", False, True),
    "sleepy": ("sleepy", "flat", False, False),
    "sleep": ("closed", "sleep", True, False),
    "yawn": ("squeeze", "yawn", False, False),
}


def load(name):
    return np.asarray(Image.open(os.path.join(RAW, name + ".png")).convert("RGBA")).copy()


def stamp(img, pattern, x, y, colors, mirror=False):
    for j, row in enumerate(pattern):
        if mirror:
            row = row[::-1]
        for i, ch in enumerate(row):
            if ch in colors and 0 <= y + j < img.shape[0] and 0 <= x + i < img.shape[1]:
                img[y + j, x + i] = (*colors[ch], 255)


def skin_tone(img):
    face = img[15:24, 20:34].reshape(-1, 4)
    face = face[(face[:, 3] > 0) & (face[:, 0].astype(int) - face[:, 2] > 50)]
    return tuple(int(v) for v in np.median(face[:, :3], axis=0))


def heal(img, box, skin, tol=60):
    """Paint over a facial feature: pixels in the box that are not skin-like become skin."""
    x, y, w, h = box
    region = img[y:y + h, x:x + w]
    diff = np.abs(region[..., :3].astype(int) - np.array(skin)).sum(2)
    region[(region[..., 3] > 0) & (diff > tol)] = (*skin, 255)


class Pet:
    def __init__(self):
        self.front = load("front")
        self.side = load("side")
        self.walk = [load(f"walk{i}") for i in range(8)]
        self.skin = skin_tone(self.front)

    # ------------------------------------------------------------- faces
    def face(self, name):
        img = self.front.copy()
        eyes, mouth, blush, sweat = FACES[name]
        if eyes:
            pat = EYES[eyes]
            col = {"#": HEART if eyes == "heart" else EYE}
            for i, (cx, cy) in enumerate((EYE_L, EYE_R)):
                heal(img, (cx - 2, cy - 1, 5, 3), self.skin)
                stamp(img, pat, cx - len(pat[0]) // 2, cy - (len(pat) - 1) // 2, col,
                      mirror=(i == 1 and eyes == "squeeze"))
        if mouth:
            cx, cy = MOUTH_C
            heal(img, (cx - 3, cy - 1, 7, 3), self.skin)
            mp = MOUTHS[mouth]
            stamp(img, mp, cx - len(mp[0]) // 2, cy - 1 if len(mp) > 2 else cy, {"#": MOUTH, "m": MOUTH_IN, "t": TONGUE})
        if blush:
            for cx, cy in CHEEKS:
                for x in (cx, cx + 1):
                    if img[cy, x, 3]:
                        img[cy, x] = (*BLUSH, 255)
        if sweat:
            stamp(img, [".s.", "sws", ".s."], 37, 2, {"s": SWEAT, "w": SWEAT_L})
        return img

    # ------------------------------------------------------------- poses
    def stand(self, face="normal", bob=0, dx=0, legs=((0, 0), (0, 0)), head_dx=0):
        src = self.face(face)
        h, w = src.shape[:2]
        pad = 6
        img = canvas(w + 2 * pad, h + pad)
        oy = pad
        mid = w // 2
        for i, (ldx, lift) in enumerate(legs):
            part = np.zeros_like(src)
            cols = slice(0, mid) if i == 0 else slice(mid, None)
            part[HIP - 2:, cols] = src[HIP - 2:, cols]
            paste(img, part, pad + ldx, oy - lift)
        upper = src.copy()
        upper[HIP:] = 0
        if head_dx:
            head = upper.copy()
            head[30:] = 0
            upper[:30] = 0
            paste(img, upper, pad + dx, oy + bob)
            paste(img, head, pad + dx + head_dx, oy + bob)
        else:
            paste(img, upper, pad + dx, oy + bob)
        ax, ay = pad + mid, oy + h - 1
        return img, {"anchor": [ax, ay], "head": [ax + dx + head_dx, oy + bob], "face": [ax + dx, oy + bob + 16]}

    def walk_frame(self, i):
        src = self.walk[i]
        h, w = src.shape[:2]
        # anchor on the torso so the body does not jitter between frames
        cols = np.where(alpha(src[40:90]).any(0))[0]
        tx = int(round((cols.min() + cols.max()) / 2))
        heads = np.where(alpha(src[:25]).any(0))[0]
        hx = int(round((heads.min() + heads.max()) / 2))
        return src, {"anchor": [tx, h - 1], "head": [hx, 0], "face": [hx + 3, 16]}

    def side_still(self):
        return self.side.copy()

    def lying(self, face, breath=0):
        """Asleep on his back under a blanket, head on a pillow (seen from the side)."""
        side = self.side_still()
        if face in ("sleep", "sleepy", "blink"):
            # close the eye on the profile
            eye = (np.argwhere(alpha(side[10:20, 20:]) & (side[10:20, 20:, :3].sum(2) < 200)))
            if len(eye):
                y, x = eye[0]
                y, x = y + 10, x + 20
                skin = tuple(int(v) for v in side[y + 2, x, :3])
                side[y - 1:y + 2, x - 1:x + 2][alpha(side[y - 1:y + 2, x - 1:x + 2])] = (*skin, 255)
                side[y, x - 1:x + 2] = (*EYE, 255)
        body = rot90(side, 1)  # head left, face up
        ys, xs = np.where(alpha(body))
        body = body[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
        bh, bw = body.shape[:2]
        pad_top, pad_l = 5, 8
        out = canvas(bw + pad_l + 4, bh + pad_top + 1)
        oy = pad_top
        ground = oy + bh
        yy, xx = np.mgrid[0:out.shape[0], 0:out.shape[1]]

        pillow = canvas(out.shape[1], out.shape[0])
        pcx, pcy, prx, pry = pad_l + 14, ground - 5.5, 19, 5.5
        pm = ((xx - pcx) / prx) ** 2 + ((yy - pcy) / pry) ** 2 <= 1
        pillow[pm] = (*PILLOW, 255)
        pillow[pm & (yy >= ground - 3)] = (*PILLOW_S, 255)
        outline(pillow, OUTLINE)
        paste(out, pillow, 0, 0)
        paste(out, body, pad_l, oy)

        # blanket draped over the body from the shoulders to the ankles, rising with each breath
        head_len = 32
        x0, x1 = pad_l + head_len, pad_l + bw - 16
        placed = np.zeros(out.shape[:2], bool)
        placed[oy:oy + bh, pad_l:pad_l + bw] = alpha(body)
        tops = np.array([np.argmax(placed[:, x]) if placed[:, x].any() else ground for x in range(out.shape[1])], float)
        k = 13
        smooth = np.convolve(np.pad(tops, k // 2, mode="edge"), np.ones(k) / k, mode="valid")
        top_at = np.round(smooth - 2 - breath).astype(int)
        blanket = canvas(out.shape[1], out.shape[0])
        r = 4
        bm = (xx >= x0) & (xx <= x1) & (yy >= top_at[None, :]) & (yy <= ground)
        bm &= ~((xx < x0 + r) & (yy < top_at[x0] + r) & ((xx - x0 - r) ** 2 + (yy - top_at[x0] - r) ** 2 > r * r))
        bm &= ~((xx > x1 - r) & (yy < top_at[x1] + r) & ((xx - x1 + r) ** 2 + (yy - top_at[x1] - r) ** 2 > r * r))
        blanket[bm] = (*BLANKET, 255)
        blanket[bm & (yy >= ground - 2)] = (*BLANKET_S, 255)
        blanket[bm & (xx <= x0 + 2)] = (*SHEET, 255)
        for hx, dy in ((x0 + 12, 4), (x0 + 28, 8), (x0 + 44, 4), (x0 + 60, 8), (x0 + 76, 5), (x0 + 92, 8)):
            if hx < x1 - 4:
                hy = top_at[hx] + dy
                if hy < ground - 4:
                    stamp(blanket, ["#.#", "###", ".#."], hx, hy, {"#": BLANKET_D})
        outline(blanket, OUTLINE)
        paste(out, blanket, 0, 0)
        return out, {"anchor": [out.shape[1] // 2, out.shape[0] - 1], "head": [pad_l + 14, oy + 1], "face": [pad_l + 16, oy + 6]}


def build():
    p = Pet()
    F = {}
    for face in FACES:
        for b in (0, 1):
            F[f"stand.{face}.{b}"] = p.stand(face, bob=b)
    for i in range(8):
        F[f"walk.normal.{i}"] = p.walk_frame(i)
        F[f"walk.blink.{i}"] = p.walk_frame(i)
    for i, (dx, b) in enumerate(((-1, 0), (1, 1), (-1, 0), (1, 1))):
        F[f"laugh.{i}"] = p.stand("happy", bob=b, dx=dx, legs=((0, 1 * (i == 1)), (0, 1 * (i == 3))))
    kicks = [((0, 0), (0, 3)), ((-1, 2), (1, 0)), ((0, 3), (0, 0)), ((1, 0), (-1, 2))]
    for face in ("surprised", "scared", "happy", "dizzy"):
        for i in range(4):
            F[f"held.{face}.{i}"] = p.stand(face, legs=kicks[i])
    for i in range(4):
        F[f"fall.{i}"] = p.stand("scared", legs=((-2, 1 + i % 2), (2, 2 - i % 2)))
    for i, dx in enumerate((-1, 0, 1, 0)):
        F[f"dizzy.{i}"] = p.stand("dizzy", head_dx=dx)
    for i, (face, b) in enumerate((("sleepy", 0), ("yawn", -1), ("yawn", -1), ("sleepy", 0))):
        F[f"yawn.{i}"] = p.stand(face, bob=b)
    for i in range(2):
        F[f"rub.{i}"] = p.stand("sleepy" if i == 0 else "blink")
        F[f"wave.{i}"] = p.stand("happy" if i == 0 else "normal", bob=i)
        F[f"wave.shy.{i}"] = p.stand("shy", bob=i)
        F[f"shy.{i}"] = p.stand("shy", bob=i)
        F[f"love.{i}"] = p.stand("love", bob=i)
    for face in ("sleep", "sleepy", "normal", "blink"):
        for b in (0, 1):
            F[f"sit.{face}.{b}"] = p.lying(face, breath=b)
    return F
