#!/usr/bin/python3
"""Write Lucciola's wallpaper as SVG: dusk over dark hills, a few fireflies.

The same scene as the desktop picture on the website (site/index.html,
.screen): a deep blue-violet sky warming to amber at the horizon, two ranges
of near-black hills, small beige fireflies with a soft halo. Calm on purpose:
the top stays darkest, behind Noctalia's bar, and nothing busy sits in the
middle, where the windows are.

The master is 3840x2400 (16:10) and anchored at the bottom
(preserveAspectRatio xMidYMax slice): rendered at another size, the hills and
the fireflies keep their place and only sky or the far sides are cropped.
render.sh rewrites width/height for each PNG. Everything is computed here,
nothing is random at render time: the same script writes the same file.

The login screen's version (LOGIN.svg, optional) is the same scene blurred
and a little darker, so the greeter's card and the logo stand out: a
Gaussian blur of 35 units of this canvas (28 px on the 2880x1920 reference
screen, the same share of any other size) and 85% brightness, in sRGB like
an image editor. Sky, glow and hills reach 160 units past every edge there,
so the blur meets more of the scene at the borders instead of transparency.

Usage: make-wallpaper.py OUT.svg [LOGIN.svg]
"""

import math
import random
import sys

W, H = 3840, 2400

# Palette. Sky from the website's picture, hills darker than the surface
# (#121212) so the bar's outline still reads against them.
SKY = [
    (0.00, "#0d0f1e"),
    (0.28, "#151a30"),
    (0.48, "#252240"),
    (0.58, "#3b2d49"),
    (0.65, "#664138"),
    (0.71, "#93603c"),
]
GLOW = "#e9a06c"  # the horizon's warmth, as on the website
GLOW_X, GLOW_Y, GLOW_RX, GLOW_RY = 0.58 * W, 0.71 * H, 0.95 * W, 0.30 * H
HILL_FAR = "#221a27"
HILL_MID = "#18131c"
HILL_NEAR = "#0d0b10"
FIREFLY_CORE = "#f6dfb2"
FIREFLY_HALO = "#f0c88c"
STAR = "#ece6df"


# The login version (see the docstring).
LOGIN_BLUR = 35
LOGIN_BRIGHTNESS = 0.85
LOGIN_MARGIN = 160


def ridge(points, bottom=H + 4, pad=40):
    """A closed path along (x, y) points: a Catmull-Rom curve as cubics."""
    pts = [(points[0][0] - 400, points[0][1])] + points + [(points[-1][0] + 400, points[-1][1])]
    d = [f"M {-pad} {bottom}", f"L {-pad} {points[0][1]:.1f}", f"L {points[0][0]:.1f} {points[0][1]:.1f}"]
    for i in range(1, len(pts) - 2):
        (x0, y0), (x1, y1), (x2, y2), (x3, y3) = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        c1 = (x1 + (x2 - x0) / 6, y1 + (y2 - y0) / 6)
        c2 = (x2 - (x3 - x1) / 6, y2 - (y3 - y1) / 6)
        d.append(f"C {c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} {x2:.1f} {y2:.1f}")
    d.append(f"L {W + pad} {points[-1][1]:.1f}")
    d.append(f"L {W + pad} {bottom} Z")
    return " ".join(d)


def firefly(x, y, r, strength, soft=False):
    """A core with a two-step halo, like the site's box-shadow."""
    halo = r * (13 if soft else 11)
    out = [
        f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{halo:.1f}" fill="url(#halo)" opacity="{0.70 * strength:.3f}"/>',
        f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r * 4:.1f}" fill="url(#halo)" opacity="{strength:.3f}"/>',
    ]
    if soft:
        out.append(
            f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r * 1.6:.1f}" fill="{FIREFLY_CORE}" '
            f'opacity="{0.6 * strength:.3f}" filter="url(#soft)"/>'
        )
    else:
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" fill="{FIREFLY_CORE}" opacity="{strength:.3f}"/>')
    return out


def scene(login=False):
    """The wallpaper's SVG text; login=True for the login screen's version."""
    rnd = random.Random(20261018)
    m = LOGIN_MARGIN if login else 0
    edge = {"bottom": H + m + 4, "pad": m + 40}

    # Three ranges, none parallel to the next: a broad distant mound on the
    # right, a closer hill rising on the left, a foreground slope.
    far = ridge([(0, 1700), (420, 1668), (980, 1702), (1560, 1680), (2120, 1636), (2560, 1594),
                 (2960, 1580), (3360, 1618), (3840, 1664)], **edge)
    mid = ridge([(0, 1744), (460, 1716), (1040, 1772), (1660, 1846), (2280, 1840), (2840, 1806),
                 (3340, 1838), (3840, 1890)], **edge)
    near = ridge([(0, 2050), (640, 2008), (1360, 2056), (2160, 2124), (2960, 2082), (3480, 2016),
                  (3840, 1992)], **edge)

    # Faint stars, only in the upper sky and away from the centre column.
    stars = []
    while len(stars) < 14:
        x, y = rnd.uniform(80, W - 80), rnd.uniform(60, 1000)
        if 1300 < x < 2540 and y < 520:
            continue
        if any(math.hypot(x - sx, y - sy) < 260 for sx, sy, _ in stars):
            continue
        stars.append((x, y, rnd.uniform(1.3, 2.4)))

    # Fireflies: placed by hand, most low over the hills, a few rising into
    # the warm sky; two larger, softer ones close to the viewer.
    flies = [
        (430, 1900, 5.2, 1.00, False),
        (780, 1590, 3.0, 0.75, False),
        (1130, 2230, 7.0, 0.80, True),
        (1480, 1760, 3.6, 0.80, False),
        (1990, 1960, 4.6, 0.95, False),
        (2300, 1520, 2.6, 0.60, False),
        (2660, 1700, 3.2, 0.80, False),
        (3000, 2160, 5.8, 1.00, False),
        (3360, 1660, 3.0, 0.70, False),
        (3620, 1980, 8.0, 0.65, True),
        (1760, 2300, 4.2, 0.80, False),
        (620, 2140, 3.8, 0.70, False),
    ]

    sky_stops = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in SKY)
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        'preserveAspectRatio="xMidYMax slice">',
        "<title>Lucciola: dusk, blurred for the login screen</title>" if login else "<title>Lucciola: dusk</title>",
        "<defs>",
        f'<linearGradient id="sky" x1="0" y1="0" x2="0" y2="{H}" gradientUnits="userSpaceOnUse">{sky_stops}</linearGradient>',
        # The horizon's warmth: an ellipse low and a little right of centre,
        # strongest just above the far hills. Wider and flatter than the
        # website's (70% x 38%): on a whole screen a taller one draws a dome.
        f'<radialGradient id="glow" cx="{GLOW_X:.0f}" cy="{GLOW_Y:.0f}" r="{GLOW_RX:.0f}" '
        f'gradientUnits="userSpaceOnUse" gradientTransform="translate({GLOW_X:.0f} {GLOW_Y:.0f}) '
        f'scale(1 {GLOW_RY / GLOW_RX:.4f}) translate({-GLOW_X:.0f} {-GLOW_Y:.0f})">'
        f'<stop offset="0" stop-color="{GLOW}" stop-opacity="0.46"/>'
        f'<stop offset="0.40" stop-color="{GLOW}" stop-opacity="0.14"/>'
        f'<stop offset="1" stop-color="{GLOW}" stop-opacity="0"/>'
        "</radialGradient>",
        # A thin haze resting on the far range, so it reads as distance.
        f'<linearGradient id="haze" x1="0" y1="1560" x2="0" y2="1900" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{GLOW}" stop-opacity="0"/>'
        f'<stop offset="0.5" stop-color="{GLOW}" stop-opacity="0.07"/>'
        f'<stop offset="1" stop-color="{GLOW}" stop-opacity="0"/>'
        "</linearGradient>",
        '<radialGradient id="halo">'
        f'<stop offset="0" stop-color="{FIREFLY_HALO}" stop-opacity="0.60"/>'
        f'<stop offset="0.30" stop-color="{FIREFLY_HALO}" stop-opacity="0.20"/>'
        f'<stop offset="1" stop-color="{FIREFLY_HALO}" stop-opacity="0"/>'
        "</radialGradient>",
        '<filter id="soft" x="-200%" y="-200%" width="500%" height="500%"><feGaussianBlur stdDeviation="5"/></filter>',
    ]
    if login:
        f = LOGIN_BRIGHTNESS
        parts += [
            f'<filter id="login" filterUnits="userSpaceOnUse" x="{-m}" y="{-m}" width="{W + 2 * m}" '
            f'height="{H + 2 * m}" color-interpolation-filters="sRGB">'
            f'<feGaussianBlur stdDeviation="{LOGIN_BLUR}"/>'
            f'<feComponentTransfer><feFuncR type="linear" slope="{f}"/><feFuncG type="linear" slope="{f}"/>'
            f'<feFuncB type="linear" slope="{f}"/></feComponentTransfer>'
            "</filter>",
        ]
    parts.append("</defs>")
    if login:
        parts.append('<g filter="url(#login)">')
    size = f'x="{-m}" y="{-m}" width="{W + 2 * m}" height="{H + 2 * m}"' if login else f'width="{W}" height="{H}"'
    parts.append(f'<rect {size} fill="url(#sky)"/>')
    parts.append(f'<rect {size} fill="url(#glow)"/>')
    for x, y, r in stars:
        parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.2f}" fill="{STAR}" opacity="{rnd.uniform(0.18, 0.42):.2f}"/>')
    parts.append(f'<path d="{far}" fill="{HILL_FAR}"/>')
    if login:
        parts.append(f'<rect x="{-m}" y="1560" width="{W + 2 * m}" height="340" fill="url(#haze)"/>')
    else:
        parts.append(f'<rect y="1560" width="{W}" height="340" fill="url(#haze)"/>')
    parts.append(f'<path d="{mid}" fill="{HILL_MID}"/>')
    for x, y, r, s, soft in flies:
        if y < 1950:
            parts.extend(firefly(x, y, r, s, soft))
    parts.append(f'<path d="{near}" fill="{HILL_NEAR}"/>')
    for x, y, r, s, soft in flies:
        if y >= 1950:
            parts.extend(firefly(x, y, r, s, soft))
    if login:
        parts.append("</g>")
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    outputs = [(sys.argv[1], False)] + ([(sys.argv[2], True)] if len(sys.argv) == 3 else [])
    for path, login in outputs:
        with open(path, "w", encoding="utf-8") as f:
            f.write(scene(login))


if __name__ == "__main__":
    main()
