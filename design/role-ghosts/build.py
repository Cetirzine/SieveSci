#!/usr/bin/env python3
"""Builds the four role ghosts from the brand logo itself, so they share its exact artwork.

Each role = the original aurora ghost (brand-reference.svg / brand-reference-animated.svg, unchanged
paths, gradients and animation) + one prop drawn in the same style (soft gradients from the logo's
own palette, no outlines), inserted inside the animated `rig` so it floats with the ghost:

  research  aurora sparkles (insight)            — twinkle while working
  worker    hard hat + small gear                — gear turns while working
  checker   reading glasses over the eyes        — glasses scan left/right, lens glint
  verifier  aurora blindfold (eyes hidden)       — sonar pulses, blindfold tails flutter

Also writes a 24-pt monoline icon per role (currentColor) abstracted from the logo's silhouette.

    python3 design/role-ghosts/build.py
"""
import math, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = open(os.path.join(HERE, "brand-reference.svg"), encoding="utf-8").read()
ANIM = open(os.path.join(HERE, "brand-reference-animated.svg"), encoding="utf-8").read()

# Palette, taken from the logo's own gradients.
CYAN, SKY, BLUE = "#2dddde", "#1bc2fc", "#5ca7fe"
VIOLET, PURPLE, PINK = "#7b5cff", "#8459fd", "#fe64ab"
EYE = "#6a4cf5"
LAV = "#a99cff"

# Head ≈ circle centre (705, 535) r ≈ 300, tilted ~15° to the right; eyes on a line sloping ~17°.
HEAD_C = (705, 535)
EYE1, EYE2 = (729.9, 545.4), (889.0, 594.2)
EYE_MID = ((EYE1[0] + EYE2[0]) / 2, (EYE1[1] + EYE2[1]) / 2)
EYE_ANGLE = math.degrees(math.atan2(EYE2[1] - EYE1[1], EYE2[0] - EYE1[0]))
EYE_HALF = math.dist(EYE1, EYE2) / 2


def grad(gid, stops, x1, y1, x2, y2):
    s = "".join(f'<stop offset="{o}" stop-color="{c}"{"" if a == 1 else f" stop-opacity=\"{a}\""}/>' for o, c, a in stops)
    return f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>'


def star(cx, cy, s, k=0.2):
    """Four-point sparkle with concave sides (the curve of the logo's ribbon ends)."""
    q = s * k
    return (f"M{cx} {cy - s}Q{cx + q} {cy - q} {cx + s} {cy}Q{cx + q} {cy + q} {cx} {cy + s}"
            f"Q{cx - q} {cy + q} {cx - s} {cy}Q{cx - q} {cy - q} {cx} {cy - s}Z")


def gear(cx, cy, r_out, r_in, teeth=8, hole=0.42):
    pts = []
    for i in range(teeth * 2):
        a0 = math.pi * 2 * i / (teeth * 2)
        r = r_out if i % 2 == 0 else r_in
        for da in (-0.28, 0.28):
            a = a0 + da * math.pi * 2 / (teeth * 2)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    d = "M" + "L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + "Z"
    h = r_in * hole
    d += f"M{cx + h} {cy}A{h} {h} 0 1 0 {cx - h} {cy}A{h} {h} 0 1 0 {cx + h} {cy}Z"
    return d


def rounded_rect(x, y, w, h, r):
    return (f"M{x + r} {y}H{x + w - r}A{r} {r} 0 0 1 {x + w} {y + r}V{y + h - r}A{r} {r} 0 0 1 {x + w - r} {y + h}"
            f"H{x + r}A{r} {r} 0 0 1 {x} {y + h - r}V{y + r}A{r} {r} 0 0 1 {x + r} {y}Z")


# MARK: - Props (defs, layer drawn on the head, layer drawn on top, animations for the working state)

def research():
    defs = grad("rs-spark", [(0, CYAN, 1), (0.5, PURPLE, 1), (1, PINK, 1)], 1000, 180, 1170, 400)
    stars = [(1088, 300, 92, "rs-s1"), (982, 182, 46, "rs-s2"), (1170, 432, 34, "rs-s3")]
    top_static = "".join(f'<path d="{star(x, y, s)}" fill="url(#rs-spark)"/>' for x, y, s, _ in stars)
    top_anim = ""
    for i, (x, y, s, sid) in enumerate(stars):
        begin = ["0s", "0.7s", "1.4s"][i]
        top_anim += (f'<g transform="translate({x} {y})"><g><animateTransform attributeName="transform" type="scale" dur="2.1s" '
                     f'begin="{begin}" repeatCount="indefinite" values="1;0.55;1" keyTimes="0;0.5;1" calcMode="spline" '
                     f'keySplines=".45 0 .55 1;.45 0 .55 1"/><animate attributeName="opacity" dur="2.1s" begin="{begin}" '
                     f'repeatCount="indefinite" values="1;0.45;1" keyTimes="0;0.5;1"/>'
                     f'<path d="{star(0, 0, s)}" fill="url(#rs-spark)"/></g></g>')
    return dict(defs=defs, head="", top=top_static, top_anim=top_anim, head_anim="", hide_eyes=False)


def worker():
    cx, cy, R = HEAD_C[0], HEAD_C[1], 314
    chord = 404
    half = math.sqrt(R * R - (cy - chord) ** 2)
    crown = f"M{cx - half:.1f} {chord}A{R} {R} 0 0 1 {cx + half:.1f} {chord}Z"
    brim = rounded_rect(cx - half - 50, chord - 12, 2 * half + 100, 36, 18)
    ridge = f"M{cx - 34} {cy - R + 6}Q{cx} {cy - R - 2} {cx + 34} {cy - R + 6}L{cx + 30} {chord}H{cx - 30}Z"
    shine = f"M{cx - half + 60:.1f} {chord - 30}Q{cx - half + 90:.1f} {cy - R + 90} {cx - 70} {cy - R + 34}Q{cx - half + 140:.1f} {cy - R + 120} {cx - half + 104:.1f} {chord - 34}Z"
    defs = (grad("wk-crown", [(0, CYAN, 1), (0.45, SKY, 1), (1, BLUE, 1)], cx - half, chord - 200, cx + half, chord)
            + grad("wk-brim", [(0, BLUE, 1), (0.6, PURPLE, 1), (1, PINK, 1)], cx - half - 58, chord, cx + half + 58, chord)
            + grad("wk-gear", [(0, PURPLE, 1), (1, PINK, 1)], 1020, 220, 1160, 380))
    hat = (f'<g transform="rotate(15 {cx} {cy})"><path d="{crown}" fill="url(#wk-crown)"/>'
           f'<path d="{ridge}" fill="#ffffff" opacity=".28"/><path d="{shine}" fill="#ffffff" opacity=".35"/>'
           f'<path d="{brim}" fill="url(#wk-brim)"/></g>')
    g = gear(0, 0, 70, 52)
    top_static = f'<g transform="translate(1092 300)"><path d="{g}" fill="url(#wk-gear)" fill-rule="evenodd"/></g>'
    top_anim = (f'<g transform="translate(1092 300)"><g><animateTransform attributeName="transform" type="rotate" '
                f'from="0" to="45" dur="1.05s" repeatCount="indefinite" calcMode="spline" keyTimes="0;1" keySplines=".6 0 .3 1"/>'
                f'<path d="{g}" fill="url(#wk-gear)" fill-rule="evenodd"/></g></g>')
    return dict(defs=defs, head=hat, head_anim=hat, top=top_static, top_anim=top_anim, hide_eyes=False)


def checker():
    mx, my = EYE_MID
    w, h, rim = 158, 170, 13
    lenses = ""
    for sx in (-EYE_HALF, EYE_HALF):
        x, y = sx - w / 2, 4 - h / 2
        outer = rounded_rect(x, y, w, h, 72)
        inner = rounded_rect(x + rim, y + rim, w - 2 * rim, h - 2 * rim, 72 - rim)
        lenses += f'<path d="{inner}" fill="#ffffff" opacity=".22"/><path d="{outer}{inner}" fill="url(#ck-rim)" fill-rule="evenodd"/>'
        lenses += (f'<path d="M{x + rim + 12} {y + h - rim - 18}Q{x + rim + 10} {y + rim + 12} {x + rim + 40} {y + rim + 8}" '
                   f'fill="none" stroke="#ffffff" stroke-width="9" stroke-linecap="round" opacity=".7"/>')
    bridge = (f'<path d="M{-EYE_HALF + w / 2 - 10} {-4}Q0 {-26} {EYE_HALF - w / 2 + 10} {-4}" fill="none" stroke="url(#ck-rim)" '
              f'stroke-width="13" stroke-linecap="round"/>')
    temple = (f'<path d="M{EYE_HALF + w / 2 - 8} {-8}L{EYE_HALF + w / 2 + 60} {-20}" fill="none" stroke="url(#ck-rim)" '
              f'stroke-width="16" stroke-linecap="round"/>')
    defs = grad("ck-rim", [(0, EYE, 1), (0.6, PURPLE, 1), (1, PINK, 1)], -200, -60, 220, 90)
    glasses = f'{bridge}{temple}{lenses}'
    head = f'<g transform="translate({mx:.1f} {my:.1f}) rotate({EYE_ANGLE:.2f})">{glasses}</g>'
    head_anim = (f'<g transform="translate({mx:.1f} {my:.1f}) rotate({EYE_ANGLE:.2f})"><g>'
                 f'<animateTransform attributeName="transform" type="translate" dur="2.1s" repeatCount="indefinite" '
                 f'values="0 0;-12 0;12 0;0 0" keyTimes="0;0.3;0.75;1" calcMode="spline" keySplines=".45 0 .55 1;.45 0 .55 1;.45 0 .55 1"/>'
                 f'{glasses}</g></g>')
    return dict(defs=defs, head=head, head_anim=head_anim, top="", top_anim="", hide_eyes=False)


def verifier():
    mx, my = EYE_MID
    defs = (grad("vf-band", [(0, CYAN, 1), (0.35, SKY, 1), (0.65, PURPLE, 1), (1, PINK, 1)], -420, 0, 300, 0)
            + grad("vf-pulse", [(0, CYAN, 1), (1, BLUE, 1)], 400, 300, 1000, 800))
    shape = "M-470 -78Q-80 -46 330 -78L330 76Q-80 108 -470 76Z"
    gloss = "M-470 -78Q-80 -46 330 -78L330 -52Q-80 -20 -470 -52Z"

    def band(extra=""):
        return (f'<g clip-path="url(#clip-head)"><g transform="translate({mx:.1f} {my:.1f}) rotate({EYE_ANGLE:.2f})">'
                f'<path d="{shape}" fill="url(#vf-band)"/>'
                f'<path d="{gloss}" fill="#ffffff" opacity=".3">{extra}</path></g></g>')

    head = band()
    head_anim = band('<animate attributeName="opacity" values=".18;.42;.18" dur="2.1s" repeatCount="indefinite"/>')
    pulses = ""
    for begin in ("0s", "1.05s"):
        pulses += (f'<circle cx="{HEAD_C[0]}" cy="{HEAD_C[1]}" r="300" fill="none" stroke="url(#vf-pulse)" stroke-width="18" opacity="0">'
                   f'<animate attributeName="r" values="300;470" dur="2.1s" begin="{begin}" repeatCount="indefinite" calcMode="spline" keyTimes="0;1" keySplines=".2 .6 .4 1"/>'
                   f'<animate attributeName="opacity" values=".55;0" dur="2.1s" begin="{begin}" repeatCount="indefinite"/>'
                   f'<animate attributeName="stroke-width" values="18;4" dur="2.1s" begin="{begin}" repeatCount="indefinite"/></circle>')
    return dict(defs=defs, head=head, head_anim=head_anim, top="", top_anim="", behind_anim=pulses, hide_eyes=True)


# MARK: - Assembly

EYES_RE = EYES_RE_STATIC = re.compile(r'<g clip-path="url\(#clip-head\)"><g id="eye1".*?</g></g></g>(?=<path id="ribbon-front")', re.S)


def prefixed(svg, prefix):
    """Unique ids per role, so several ghosts can live in one document."""
    ids = set(re.findall(r'id="([^"]+)"', svg))
    for i in sorted(ids, key=len, reverse=True):
        if i.startswith(prefix):
            continue
        svg = svg.replace(f'id="{i}"', f'id="{prefix}{i}"').replace(f"url(#{i})", f"url(#{prefix}{i})")
    return svg


def build(role, title, prop, animated):
    src = ANIM if animated else STATIC
    s = re.sub(r' width="\d+" height="\d+"', "", src, count=1)
    s = re.sub(r"<title>[^<]*</title>", f"<title>{title}</title>", s, count=1)
    s = s.replace("</defs>", prop["defs"] + "</defs>", 1)
    if prop.get("hide_eyes"):
        s, n = (EYES_RE if animated else EYES_RE_STATIC).subn("", s, count=1)
        assert n == 1, "eyes not found"
    head = prop["head_anim"] if animated else prop["head"]
    s = s.replace('<path id="ribbon-front"', head + '<path id="ribbon-front"', 1)
    if animated:
        behind = prop.get("behind_anim", "")
        if behind:
            s = s.replace('<path id="ring-back-right"', behind + '<path id="ring-back-right"', 1)
        # Inside the rig: after the front orb, before the rig's closing tags.
        i = s.rfind("</g></g></g></g></g></svg>")
        assert i > 0
        s = s[:i] + prop["top_anim"] + s[i:]
    else:
        s = s.replace("</svg>", prop["top"] + "</svg>", 1)
    return prefixed(s, {"research": "rs-", "worker": "wk-", "checker": "ck-", "verifier": "vf-"}[role])


# MARK: - Line icons (24 grid, currentColor)

# Traced from the brand logo: dome, belt (top edge of the ribbon), left loop, skirt, orb.
ST = 'fill="none" stroke="currentColor" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"'
# Traced from the brand logo (1254 viewBox scaled to 24).
HEAD = "M5.3 10.6C6.5 6.7 9.6 4.4 13.3 4.4C16.9 4.4 19.3 7.3 19.1 10.9C19 12.9 18.4 14.5 17.5 15.7"
BELT = "M5.3 10.6C8.9 11.9 13.3 13.6 17.5 15.7"          # head bottom = top edge of the ribbon
LOOP = "M6.1 7.9C5.0 8.3 3.4 8.8 2.8 10.6C2.2 12.6 4.2 14.2 7.2 14.7C11.6 15.3 15.6 16.6 18.6 17.5C20.2 18 21.6 17.2 22.3 15.9"
SKIRT = "M7.4 14.8C7.5 16.6 6.6 17.6 5.6 18.4C4.9 19.1 6 19.9 7.6 19.6C8.3 19.4 8.9 19.2 9.4 18.9C9.9 19.6 9.3 20.4 9.6 21C10.6 21.4 12.4 20.2 13.6 19.3C15.6 17.9 17.8 17.9 19.4 17.6"
ORB = (20.74, 14.92, 1.05)
EYES = [(13.97, 10.44), (17.01, 11.37)]
def fmt(v): return f"{v:.2f}".rstrip("0").rstrip(".")
def pill(c, w=1.5, h=2.9):
    return (f'<rect x="{fmt(c[0]-w/2)}" y="{fmt(c[1]-h/2)}" width="{w}" height="{h}" rx="{fmt(w/2)}" '
            f'transform="rotate(17 {fmt(c[0])} {fmt(c[1])})" fill="currentColor"/>')
def line_svg(role, title, w=1.5):
    st = ST.format(w=w); p = []
    p.append(f'<path d="{HEAD}" {st}/>')
    p.append(f'<path d="{BELT}" {st}/>')
    p.append(f'<path d="{LOOP}" {st}/>')
    p.append(f'<path d="{SKIRT}" {st}/>')
    ox, oy, r = ORB
    p.append(f'<circle cx="{ox}" cy="{oy}" r="{r}" fill="currentColor"/>')
    if role == "checker":
        L = [(13.6, 10.2), (17.3, 11.3)]
        for c in L: p.append(f'<circle cx="{fmt(c[0])}" cy="{fmt(c[1])}" r="1.6" {st}/>')
        p.append(f'<path d="M15.25 10.25Q15.5 9.9 15.7 10.65" {st}/>')
        p.append(f'<path d="M11.9 9.7L10.4 9.1" {st}/>')
    elif role == "verifier":
        p.append(f'<path d="M8.6 8.5L17.6 11.25" fill="none" stroke="currentColor" stroke-width="2.9" stroke-linecap="round"/>')
    else:
        for c in EYES: p.append(pill(c))
    if role == "research":
        cx, cy, R, ri = 20.4, 4.0, 2.5, 0.55
        pts = [(cx + (R if i % 2 == 0 else ri) * math.cos(math.pi/4*i - math.pi/2),
                cy + (R if i % 2 == 0 else ri) * math.sin(math.pi/4*i - math.pi/2)) for i in range(8)]
        p.append('<path d="M' + " L".join(f"{fmt(x)} {fmt(y)}" for x, y in pts) + 'Z" fill="currentColor" stroke="currentColor" stroke-width=".5" stroke-linejoin="round"/>')
    if role == "worker":
        # hard hat over the dome: filled crown + brim
        p.append('<path d="M7.6 6.9C9 5.1 11.1 4.1 13.3 4.1C15.8 4.1 17.8 5.5 18.8 7.6Z" fill="currentColor" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>')
        p.append(f'<path d="M5.9 7.6L20.4 8.1" {st}/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><title>{title}</title>{"".join(p)}</svg>\n'

ROLES = [("research", "Research agent", research), ("worker", "Worker", worker),
         ("checker", "Checker", checker), ("verifier", "Blind verifier", verifier)]

# Layers for the app's native animation (WebKit SMIL cost ~9% CPU per badge): the ghost without its
# moving part, and that part alone on the same 1254 canvas, so SwiftUI can turn/fade/move it cheaply.
MOVING = {"research": "top", "worker": "top", "checker": "head", "verifier": None}


def layers(role, title, prop):
    part = MOVING[role]
    base = dict(prop)
    if part:
        base[part] = ""
    base_svg = build(role, f"{title} (still)", base, False)
    if not part:
        return base_svg, ""
    body = prop[part]
    layer = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1254 1254"><defs>{prop["defs"]}</defs>{body}</svg>\n')
    return base_svg, prefixed(layer, {"research": "rs-", "worker": "wk-", "checker": "ck-", "verifier": "vf-"}[role])


if __name__ == "__main__":
    for role, title, fn in ROLES:
        prop = fn()
        os.makedirs(os.path.join(HERE, role), exist_ok=True)
        for name, content in [("logo.svg", build(role, f"SieveSci {title}", prop, False)),
                              ("working.svg", build(role, f"SieveSci {title} (working)", prop, True)),
                              ("line.svg", line_svg(role, f"{title} icon")),
                              ("base.svg", layers(role, f"SieveSci {title}", prop)[0]),
                              ("prop.svg", layers(role, f"SieveSci {title}", prop)[1])]:
            open(os.path.join(HERE, role, name), "w", encoding="utf-8").write(content)
        print(role, "ok")
