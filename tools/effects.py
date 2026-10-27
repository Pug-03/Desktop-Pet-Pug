"""Small particle sprites drawn around the pet (hearts, stars, Zzz...)."""
import numpy as np


def canvas(w, h):
    return np.zeros((h, w, 4), np.uint8)


def outline(img, c):
    """1px outline around every opaque pixel."""
    a = img[..., 3] > 0
    grown = np.zeros_like(a)
    grown[1:] |= a[:-1]
    grown[:-1] |= a[1:]
    grown[:, 1:] |= a[:, :-1]
    grown[:, :-1] |= a[:, 1:]
    img[grown & ~a] = (*c, 255)

PATTERNS = {
    "heart": ([".##.##.",
               "#oo####",
               "#o#####",
               "#######",
               ".#####.",
               "..###..",
               "...#..."], {"#": (236, 64, 92), "o": (255, 190, 200)}),
    "heart_s": (["##.##",
                 "#####",
                 ".###.",
                 "..#.."], {"#": (246, 104, 136)}),
    "star": (["...#...",
              "..###..",
              "#######",
              ".#####.",
              "..###..",
              ".##.##.",
              "##...##"], {"#": (255, 214, 64)}),
    "sparkle": (["..#..",
                 "..#..",
                 "##o##",
                 "..#..",
                 "..#.."], {"#": (255, 246, 190), "o": (255, 255, 255)}),
    "z_s": (["#####",
             "...#.",
             "..#..",
             ".#...",
             "#####"], {"#": (130, 150, 240)}),
    "z_l": (["#######",
             ".....#.",
             "....#..",
             "...#...",
             "..#....",
             ".#.....",
             "#######"], {"#": (130, 150, 240)}),
    "sweat": ([".#.",
               "#o#",
               "###",
               ".#."], {"#": (130, 190, 250), "o": (230, 245, 255)}),
    "note": (["..##",
              "..#.",
              "..#.",
              "###.",
              "##.."], {"#": (255, 255, 255)}),
    "bang": (["#", "#", "#", ".", "#"], {"#": (255, 90, 80)}),
    "puff": ([".##.",
              "#oo#",
              "#oo#",
              ".##."], {"#": (230, 230, 236), "o": (255, 255, 255)}),
}


def build():
    out = {}
    for name, (pat, colors) in PATTERNS.items():
        h, w = len(pat), len(pat[0])
        img = canvas(w + 2, h + 2)
        for y, row in enumerate(pat):
            for x, ch in enumerate(row):
                if ch in colors:
                    img[y + 1, x + 1] = (*colors[ch], 255)
        if not name.startswith("z_"):  # an outline would fill the gaps inside the letter
            outline(img, (40, 28, 40))
        out[name] = (img, {"anchor": [(w + 2) // 2, (h + 2) // 2]})
    return out

