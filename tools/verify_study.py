"""Recompute every answer in study.json from the question's parameters.

Pure standard library (fractions + math). Run: python3 verify.py
"""
import json, math, os, re, itertools
from fractions import Fraction as F

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = json.load(open(os.path.join(HERE, "..", "App", "Resources", "study.json"), encoding="utf-8"))

# ---------- parsing plain-text math into Python ----------
def to_py(s):
    s = re.sub(r"(\d),(\d{3})", r"\1\2", s.strip()).replace("$", "").replace("%", "").replace("°", "")
    s = s.replace("≤", "<=").replace("≥", ">=").replace("π", "pi").replace("^", "**")
    s = re.sub(r"√(\d+)", r"sqrt(\1)", s)
    s = s.replace("√(", "sqrt(").replace("∛(", "cbrt(")
    s = re.sub(r"(\d|\))\s*(?=[A-Za-z(])", r"\1*", s)  # implicit multiplication
    return s

def cbrt(v):
    return math.copysign(abs(v) ** (1 / 3), v)

def ev(s, **vars_):
    ns = {"sqrt": math.sqrt, "cbrt": cbrt, "pi": math.pi, "__builtins__": {}}
    ns.update(vars_)
    return eval(to_py(s), ns)

def close(a, b):
    return math.isclose(float(a), float(b), rel_tol=1e-9, abs_tol=1e-9)

def rhs(s):
    return s.split("=", 1)[1] if "=" in s and "<" not in s and ">" not in s else s

SAMPLES = [0.37, 1.3, 2.9, 4.1, 7.25]

# ---------- check builders: each returns choice_str -> bool ----------
def num(v):
    return lambda c: close(ev(rhs(c)), v)

def expr(fn, var):
    """Choice (an expression in `var`, maybe 'Y = ...') equals fn at sample points."""
    return lambda c: all(close(ev(rhs(c), **{var: t}), fn(t)) for t in SAMPLES)

def point(p):
    return lambda c: all(close(a, b) for a, b in zip(ev(c), p)) and len(ev(c)) == len(p)

def text(t):
    return lambda c: c == t

def claims(table, truth):
    """For text choices: map each choice text to the facts it claims; correct iff claims == truth."""
    return lambda c: table[c] == truth

# ---------- independent recomputation per question ----------
C = {}

# poly
C["poly-01"] = expr(lambda x: (2 * x + 3) * (x - 4), "x")
C["poly-02"] = expr(lambda F_: (F_ - 32) / (F(9, 5)), "F")  # invert F = 9/5 C + 32
def _poly03():
    # x^2 - 7x + k = (x-3)(x-m): match x coefficient -(3+m) = -7
    m = 7 - 3
    return F(3 * m)
C["poly-03"] = _poly03()
def _poly04():
    p = lambda x: 6 * x * x + x - 15
    def is_factor(c):  # c = "ax + b": factor iff p(-b/a) == 0
        a, sign, b = re.match(r"(\d+)x ([+-]) (\d+)", c).group(1, 2, 3)
        a, b = int(a), int(b) * (1 if sign == "+" else -1)
        return p(F(-b, a)) == 0
    return is_factor
C["poly-04"] = _poly04()
def _quad_sum(a, b, c):
    d = b * b - 4 * a * c
    r = math.isqrt(d)
    assert r * r == d
    return F(-b + r, 2 * a) + F(-b - r, 2 * a)
C["poly-05"] = _quad_sum(36, -72, 11)
def _poly06():
    cs = set()
    for a in range(-20, 21):
        for b in range(-20, 21):
            if a * b == 15 and a + b == 8:
                cs.add(5 * a + 3 * b)
    return lambda c: int(c) in cs
C["poly-06"] = _poly06()

# radical
C["radical-01"] = expr(lambda x: x ** (2 / 3), "x")
C["radical-02"] = 5 ** 2 - 7
C["radical-03"] = math.sqrt(50) + math.sqrt(18) - math.sqrt(8)
C["radical-04"] = expr(lambda x: (16 * x ** 8) ** 0.75, "x")
def _radical05():
    sols = [x for x in range(-50, 51) if 2 * x + 7 >= 0 and x + 2 >= 0 and (x + 2) ** 2 == 2 * x + 7]
    assert len(sols) == 1
    return sols[0]
C["radical-05"] = _radical05()
C["radical-06"] = F(6, 6 - 2)  # 2^(6x) = 2^(2x+6)

# linear
C["linear-01"] = F(7 - (-1), 6 - 2)
C["linear-02"] = -1 / F(2, 3)
def _solve2(a1, b1, c1, a2, b2, c2):
    d = a1 * b2 - a2 * b1
    return F(c1 * b2 - c2 * b1, d), F(a1 * c2 - a2 * c1, d)
_x, _y = _solve2(3, 2, 16, 1, -1, 2)
C["linear-03"] = _x + _y
def _linear04(c):
    c = F(int(c))
    # same line iff (4,-6,10) and (6,-9,c) proportional
    return F(6, 4) == F(-9, -6) == c / 10
C["linear-04"] = _linear04
def _linear05():
    ok = [a for a in range(-20, 21) if a * 6 - 2 * 3 == 0 and F(7, 3) != F(5, 6)]
    assert len(ok) == 1
    return ok[0]
C["linear-05"] = _linear05()
_m = F(5, 2)
C["linear-06"] = 3 - _m * 4

# ineq
C["ineq-01"] = max(t for t in range(0, 1000) if 2500 + 10 * t <= 4000)  # in cents
C["ineq-02"] = sum(x for x in range(-100, 100) if abs(x - 4) == 9)
C["ineq-03"] = F(27, 18 + 27)
def _ineq04(c):
    return all(ev(c, b=b) == (80 + 35 * b <= 1200) for b in range(0, 100))
C["ineq-04"] = _ineq04
C["ineq-05"] = sum(1 for x in range(-100, 100) if abs(2 * x - 5) < 7)
C["ineq-06"] = F(35 + 25, 35 + 25 + 45 + 25)

# percent
C["percent-01"] = F(80) * F(115, 100)
C["percent-02"] = F(18, 72) * 100
C["percent-03"] = F(120, 100) * F(80, 100) * 100
C["percent-04"] = text("The value of the machine decreases by %d%% each year." % round((1 - 0.92) * 100))
C["percent-05"] = F(6480, 100) / (F(75, 100) * F(108, 100))
C["percent-06"] = expr(lambda h: 500 * 2 ** (h / 3), "h")

# stats
def _mean(v): return F(sum(v), len(v))
def _sd(v):
    m = _mean(v); return math.sqrt(sum((x - m) ** 2 for x in v) / len(v))
A, B = [10] * 5, [6, 8, 10, 12, 14]
_truth = (("same" if _mean(A) == _mean(B) else ("A" if _mean(A) > _mean(B) else "B")),
          ("same" if close(_sd(A), _sd(B)) else ("A" if _sd(A) > _sd(B) else "B")))
C["stats-01"] = claims({
    "The data sets have the same mean, and data set A has the greater standard deviation.": ("same", "A"),
    "The data sets have the same mean, and data set B has the greater standard deviation.": ("same", "B"),
    "Data set B has the greater mean, and the standard deviations are equal.": ("B", "same"),
    "The data sets have the same mean and the same standard deviation.": ("same", "same"),
}, _truth)
_data = [1] * 3 + [2] * 5 + [3] * 4 + [4] * 8
_data.sort(); _n = len(_data)
C["stats-02"] = F(_data[_n // 2 - 1] + _data[_n // 2], 2)
C["stats-03"] = F(20 * 75 + 30 * 85, 50)
C["stats-04"] = 31 - 18
C["stats-05"] = 6 * 14 - 5 * F(128, 10)
_lo, _hi = 62 - 4, 62 + 4
C["stats-06"] = claims({
    "Exactly 62% of all residents of the city support the new park.": ("exact", None),
    "It is plausible that between 58% and 66% of all residents of the city support the new park.": ("population", (58, 66)),
    "It is plausible that between 60% and 64% of all residents of the city support the new park.": ("population", (60, 64)),
    "Between 58% and 66% of the 400 residents surveyed support the new park.": ("sample", (58, 66)),
}, ("population", (_lo, _hi)))

# quad
C["quad-01"] = min((x / 100 - 3) ** 2 + 5 for x in range(-1000, 1000))
C["quad-02"] = max(x for x in range(-100, 100) if x * x - 5 * x - 14 == 0)
_vx = F(12, 4)
C["quad-03"] = point((_vx, 2 * _vx ** 2 - 12 * _vx + 7))
C["quad-04"] = F(6 * 6, 4)
C["quad-05"] = [c for c in range(-50, 50) if 36 - 4 * (c + 5) == 0][0]
C["quad-06"] = max(-2 * (F(x, 10) - 1) * (F(x, 10) - 7) for x in range(-100, 200))

# area
C["area-01"] = math.pi * 3 ** 2 * 10
C["area-02"] = 12 * 8 - 3 * 3
C["area-03"] = math.pi * 6 ** 2 * 8 / 3
C["area-04"] = [r for r in range(1, 50) if F(4, 3) * r ** 3 == 36][0]
_h = math.sqrt(10 ** 2 - 6 ** 2)
C["area-05"] = 12 ** 2 * _h / 3
C["area-06"] = F(3 ** 2) * F(1, 2)

# circle
C["circle-01"] = text("Center (%d, %d), radius %d" % (2, -5, math.isqrt(49)))
C["circle-02"] = math.hypot(5, 12)
def _complete(D, E, Fc):
    """x^2 + y^2 + Dx + Ey + Fc = 0 -> (h, k, r^2)"""
    h, k = F(-D, 2), F(-E, 2)
    return h, k, h * h + k * k - Fc
C["circle-03"] = math.sqrt(_complete(-6, 8, 0)[2])
def _circle04(c):
    h, k = 3, -1
    r2 = (7 - h) ** 2 + (2 - k) ** 2
    l, r = c.split("=")
    pts = [(0.3, 1.7), (2.2, -4.1), (5.5, 0.9), (-1.2, 3.3)]
    return all(close(ev(l, x=x, y=y) - ev(r), (x - h) ** 2 + (y - k) ** 2 - r2) for x, y in pts)
C["circle-04"] = _circle04
C["circle-05"] = 6 ** 2 - (5 ** 2 + 2 ** 2)  # x^2+10x+25, y^2-4y+4
C["circle-06"] = math.sqrt(_complete(F(-8, 2), F(12, 2), F(-6, 2))[2])

# trig
C["trig-01"] = (6 - 2) * 180
C["trig-02"] = [x for x in range(1, 90) if close(math.sin(math.radians(x)), math.cos(math.radians(28)))][0]
C["trig-03"] = 150 * math.pi / 180
C["trig-04"] = 5 * F(4 + 6, 4)
C["trig-05"] = sum(1 for x in range(1, 100) if x + 7 > 12 and x + 12 > 7 and 7 + 12 > x)
_x6 = F(180 + 8, 8)
C["trig-06"] = max(3 * _x6 + 10, 5 * _x6 - 18)

# func
C["func-01"] = 3 * (-2) ** 2 - 2 * (-2) + 1
C["func-02"] = F(25 + 7, 4)
def _func03(c):
    f = lambda t: t ** 3 - 2 * t ** 2 + 5 * t + 1  # any non-symmetric test function
    expected = lambda t: f(t - 3) + 2
    return all(close(ev(rhs(c), f=f, x=t), expected(t)) for t in SAMPLES)
C["func-03"] = _func03
_k = 11 - 2 * 3
C["func-04"] = 2 * 5 + _k
def _func05():
    vx = F(8, 2)
    c = 3 - (vx ** 2 - 8 * vx)
    return 1 - 8 + c
C["func-05"] = _func05()
_b = math.isqrt(54 // 6); _a = F(6, _b)
assert _b * _b * 6 == 54
C["func-06"] = _a * _b ** 4

# ratio
C["ratio-01"] = F(150) / F(25, 10) * 4
C["ratio-02"] = F(40 * 5, 3 + 5)
C["ratio-03"] = F(20 * 3600, 1000)
C["ratio-04"] = F(27, 10) * 4 ** 3
C["ratio-05"] = 6 * F(25, 10) ** 2
C["ratio-06"] = F(360) / (F(45, 9) + F(70, 10))

# word
C["word-01"] = text("The cost increases by $%d for each additional month." % (30 * 2 + 50 - (30 * 1 + 50)))
C["word-02"] = F(185 - 12 * 10, 5)
C["word-03"] = expr(lambda t: 500 - 15 * t, "t")
C["word-04"] = max(p for p in range(0, 100) for n in range(3, 20) if 2 * p + 5 * n <= 40)
_sols = [(a, s) for s in range(0, 301) for a in [300 - s] if 15 * a + 9 * s == 3720]
assert len(_sols) == 1
C["word-05"] = _sols[0][1]
C["word-06"] = F(45, 100) * 7

# ---------- run ----------
def as_check(v):
    return v if callable(v) else num(v)

def parse_answer(s):
    try:
        return F(s)
    except ValueError:
        return ev(s)

errors = []
qs = DATA["questions"]
topics = [t["id"] for t in DATA["topics"]]

if len(topics) != 13 or len(set(topics)) != 13: errors.append("need 13 unique topics")
if [t["lesson"] for t in DATA["topics"]] != list(range(1, 14)): errors.append("lessons not 1..13")
ids = [q["id"] for q in qs]
if len(ids) != len(set(ids)): errors.append("duplicate ids")
for t in topics:
    tq = [q for q in qs if q["topic"] == t]
    if len(tq) != 6: errors.append(f"{t}: {len(tq)} questions")
    lv = sorted(q["level"] for q in tq)
    if lv != [1, 1, 2, 2, 3, 3]: errors.append(f"{t}: levels {lv}")
if set(C) != set(ids): errors.append(f"check/id mismatch: {set(C) ^ set(ids)}")

BAD_TEXT = re.compile(r"\\frac|\\sqrt|\$\$|\\\(|\\\[")
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿]")
for q in qs:
    qid = q["id"]
    blob = json.dumps(q, ensure_ascii=False)
    if BAD_TEXT.search(blob): errors.append(f"{qid}: LaTeX found")
    if EMOJI.search(blob): errors.append(f"{qid}: emoji found")
    if not 3 <= len(q["steps"]) <= 6: errors.append(f"{qid}: {len(q['steps'])} steps")
    if q["desmos"] and not any("Desmos" in s for s in q["steps"]): errors.append(f"{qid}: desmos step missing")
    if not qid.startswith(q["topic"] + "-"): errors.append(f"{qid}: topic prefix")
    try:
        check = as_check(C[qid])
        if q["type"] == "mc":
            ch = q["choices"]
            if len(ch) != 4 or len(set(ch)) != 4: errors.append(f"{qid}: choices not 4 distinct")
            hits = [i for i, c in enumerate(ch) if check(c)]
            if hits != [q["answer"]]: errors.append(f"{qid}: correct choices {hits}, json says {q['answer']}")
        elif q["type"] == "spr":
            if "choices" in q or "answer" in q: errors.append(f"{qid}: spr has mc fields")
            ans = q["answers"]
            if not check(ans[0]): errors.append(f"{qid}: first answer {ans[0]} wrong (expected {C[qid]})")
            for a in ans[1:]:
                if not close(parse_answer(a), parse_answer(ans[0])): errors.append(f"{qid}: alt answer {a} differs")
        else:
            errors.append(f"{qid}: bad type")
    except Exception as e:
        errors.append(f"{qid}: exception {e!r}")

n_spr = sum(q["type"] == "spr" for q in qs)
share = n_spr / len(qs)
if not 0.22 <= share <= 0.30: errors.append(f"spr share {share:.0%}")

print(f"{len(qs)} questions, {len(qs) - n_spr} mc, {n_spr} spr ({share:.1%})")
for t in topics:
    tq = [q for q in qs if q["topic"] == t]
    print(f"  {t:8} {len(tq)}  mc {sum(q['type']=='mc' for q in tq)}  spr {sum(q['type']=='spr' for q in tq)}")
if errors:
    print("FAIL")
    for e in errors: print("  " + e)
    raise SystemExit(1)
print("PASS: every answer recomputed and matched")
