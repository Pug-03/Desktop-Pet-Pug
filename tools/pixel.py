"""Tiny RGBA pixel-art raster helpers on numpy arrays (H x W x 4, uint8)."""
import math
import numpy as np


def canvas(w, h):
    return np.zeros((h, w, 4), np.uint8)


def rgba(c):
    return (*c, 255) if len(c) == 3 else tuple(c)


def put(img, x, y, c):
    x, y = int(round(x)), int(round(y))
    if 0 <= y < img.shape[0] and 0 <= x < img.shape[1]:
        img[y, x] = rgba(c)


def pts(img, coords, c):
    for x, y in coords:
        put(img, x, y, c)


def rect(img, x0, y0, x1, y1, c):
    """Inclusive rectangle."""
    h, w = img.shape[:2]
    x0, x1 = max(0, int(x0)), min(w - 1, int(x1))
    y0, y1 = max(0, int(y0)), min(h - 1, int(y1))
    if x1 >= x0 and y1 >= y0:
        img[y0:y1 + 1, x0:x1 + 1] = rgba(c)


def _grid(img):
    h, w = img.shape[:2]
    return np.mgrid[0:h, 0:w]


def ellipse_mask(img, cx, cy, rx, ry):
    yy, xx = _grid(img)
    return ((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2 <= 1.0


def ellipse(img, cx, cy, rx, ry, c):
    img[ellipse_mask(img, cx, cy, rx, ry)] = rgba(c)


def capsule_mask(img, x0, y0, x1, y1, r):
    yy, xx = _grid(img)
    dx, dy = x1 - x0, y1 - y0
    L2 = dx * dx + dy * dy or 1e-9
    t = np.clip(((xx - x0) * dx + (yy - y0) * dy) / L2, 0, 1)
    px, py = x0 + t * dx, y0 + t * dy
    return (xx - px) ** 2 + (yy - py) ** 2 <= r * r


def capsule(img, x0, y0, x1, y1, r, c):
    img[capsule_mask(img, x0, y0, x1, y1, r)] = rgba(c)


def roundrect_mask(img, x0, y0, x1, y1, r):
    yy, xx = _grid(img)
    cx = np.clip(xx, x0 + r, x1 - r)
    cy = np.clip(yy, y0 + r, y1 - r)
    return ((xx - cx) ** 2 + (yy - cy) ** 2 <= r * r + 0.5) & (xx >= x0) & (xx <= x1) & (yy >= y0) & (yy <= y1)


def alpha(img):
    return img[..., 3] > 0


def shift(mask, dx, dy):
    out = np.zeros_like(mask)
    h, w = mask.shape
    ys = slice(max(0, dy), min(h, h + dy))
    yd = slice(max(0, -dy), min(h, h - dy))
    xs = slice(max(0, dx), min(w, w + dx))
    xd = slice(max(0, -dx), min(w, w - dx))
    out[ys, xs] = mask[yd, xd]
    return out


def shade(img, mask, light=None, dark=None):
    """Rim-light top-left edges and shadow bottom-right edges of a flat-filled mask."""
    if light is not None:
        edge = mask & ~shift(mask, 1, 1)
        img[edge] = rgba(light)
    if dark is not None:
        edge = mask & ~shift(mask, -1, -1)
        img[edge] = rgba(dark)


def outline(img, c, diagonal=False):
    """Add a 1px outline around all opaque pixels."""
    a = alpha(img)
    grown = shift(a, 1, 0) | shift(a, -1, 0) | shift(a, 0, 1) | shift(a, 0, -1)
    if diagonal:
        grown |= shift(a, 1, 1) | shift(a, -1, -1) | shift(a, 1, -1) | shift(a, -1, 1)
    img[grown & ~a] = rgba(c)


def paste(dst, src, x, y):
    """Alpha-over (binary alpha) src onto dst at integer offset."""
    x, y = int(round(x)), int(round(y))
    sh, sw = src.shape[:2]
    dh, dw = dst.shape[:2]
    sx0, sy0 = max(0, -x), max(0, -y)
    dx0, dy0 = max(0, x), max(0, y)
    w = min(sw - sx0, dw - dx0)
    h = min(sh - sy0, dh - dy0)
    if w <= 0 or h <= 0:
        return
    s = src[sy0:sy0 + h, sx0:sx0 + w]
    d = dst[dy0:dy0 + h, dx0:dx0 + w]
    m = s[..., 3] > 0
    d[m] = s[m]


def layer_with_outline(layer, c):
    """Outline one layer so it separates from whatever it is pasted over."""
    out = layer.copy()
    outline(out, c)
    return out


def scale2x(img):
    """EPX / Scale2x: doubles resolution and smooths diagonal stair-steps."""
    h, w = img.shape[:2]
    key = img[..., 0].astype(np.int64) << 24 | img[..., 1].astype(np.int64) << 16 | img[..., 2].astype(np.int64) << 8 | img[..., 3]
    pad = np.pad(key, 1, mode="edge")
    P = key
    A = pad[0:h, 1:w + 1]
    B = pad[1:h + 1, 2:w + 2]
    C = pad[1:h + 1, 0:w]
    D = pad[2:h + 2, 1:w + 1]
    e = np.repeat(np.repeat(img, 2, 0), 2, 1)
    padimg = np.pad(img, ((1, 1), (1, 1), (0, 0)), mode="edge")
    Ai, Bi, Ci, Di = padimg[0:h, 1:w + 1], padimg[1:h + 1, 2:w + 2], padimg[1:h + 1, 0:w], padimg[2:h + 2, 1:w + 1]
    c1 = (C == A) & (C != D) & (A != B)
    c2 = (A == B) & (A != C) & (B != D)
    c3 = (D == C) & (D != B) & (C != A)
    c4 = (B == D) & (B != A) & (D != C)
    e[0::2, 0::2][c1] = Ai[c1]
    e[0::2, 1::2][c2] = Bi[c2]
    e[1::2, 0::2][c3] = Ci[c3]
    e[1::2, 1::2][c4] = Di[c4]
    _ = P
    return e


def quantize(imgs, k, iters=20, seed=1):
    """Shared k-means palette for a list of RGBA images. Returns quantized copies."""
    data = np.concatenate([i[alpha(i)][:, :3].astype(float) for i in imgs])
    rng = np.random.default_rng(seed)
    cent = data[rng.choice(len(data), k, replace=False)]
    for _ in range(iters):
        d = ((data[:, None, :] - cent[None]) ** 2).sum(2)
        lab = d.argmin(1)
        for j in range(k):
            if (lab == j).any():
                cent[j] = data[lab == j].mean(0)
    cent = np.round(cent).astype(np.uint8)
    out = []
    for i in imgs:
        o = i.copy()
        m = alpha(i)
        px = i[m][:, :3].astype(float)
        lab = ((px[:, None, :] - cent[None].astype(float)) ** 2).sum(2).argmin(1)
        o[m, :3] = cent[lab]
        out.append(o)
    return out


def rot90(img, k):
    return np.ascontiguousarray(np.rot90(img, k))


def flip(img):
    return np.ascontiguousarray(img[:, ::-1])


def bbox(img):
    ys, xs = np.where(alpha(img))
    return xs.min(), ys.min(), xs.max(), ys.max()


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def scale3x(img):
    """Scale3x (AdvMAME3x): triples resolution, smoothing diagonal edges."""
    h, w = img.shape[:2]
    key = (img[..., 0].astype(np.int64) << 24 | img[..., 1].astype(np.int64) << 16
           | img[..., 2].astype(np.int64) << 8 | img[..., 3])
    kp = np.pad(key, 1, mode="edge")
    ip = np.pad(img, ((1, 1), (1, 1), (0, 0)), mode="edge")

    def k(dy, dx):
        return kp[1 + dy:h + 1 + dy, 1 + dx:w + 1 + dx]

    def c(dy, dx):
        return ip[1 + dy:h + 1 + dy, 1 + dx:w + 1 + dx]

    A, B, C = k(-1, -1), k(-1, 0), k(-1, 1)
    D, E, F = k(0, -1), k(0, 0), k(0, 1)
    G, H, I = k(1, -1), k(1, 0), k(1, 1)
    cB, cD, cE, cF, cH = c(-1, 0), c(0, -1), c(0, 0), c(0, 1), c(1, 0)
    out = np.repeat(np.repeat(img, 3, 0), 3, 1)
    ok = (B != H) & (D != F)

    def setp(oy, ox, cond, src):
        sub = out[oy::3, ox::3]
        sub[cond] = src[cond]

    setp(0, 0, ok & (D == B), cD)
    setp(0, 1, ok & (((D == B) & (E != C)) | ((B == F) & (E != A))), cB)
    setp(0, 2, ok & (B == F), cF)
    setp(1, 0, ok & (((D == B) & (E != G)) | ((D == H) & (E != A))), cD)
    setp(1, 2, ok & (((B == F) & (E != I)) | ((H == F) & (E != C))), cF)
    setp(2, 0, ok & (D == H), cD)
    setp(2, 1, ok & (((D == H) & (E != I)) | ((H == F) & (E != G))), cH)
    setp(2, 2, ok & (H == F), cF)
    _ = cE
    return out
