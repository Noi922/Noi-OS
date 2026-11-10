#!/usr/bin/env python3
"""Erzeugt das Noi-OS-Camouflage-Hintergrundbild als SVG.

Woodland-Camouflage in Gruentoenen: mehrere Schichten organischer Flecken
(geschlossene, geglaettete Bezier-Kurven), darueber eine leichte Vignette und
ein dezenter Schriftzug. Das Muster ist deterministisch (fester Seed) und
nahtlos kachelbar (Flecken am Rand werden auf der Gegenseite wiederholt).

Aufruf:  make-camo-wallpaper.py AUSGABE.svg [--width 3840 --height 2160]
                                [--seed 42] [--no-text]
"""
import argparse
import math
import random

# Farbpalette (dunkel -> hell). Wird auch fuer das Desktop-Theme verwendet.
BASE = "#3b4a2a"          # Grundton: gedecktes Waldgruen
LAYERS = [
    ("#4b5d2e", 34, 0.20),  # Olivgruen       (Farbe, Anzahl Flecken, rel. Groesse)
    ("#6b7a3f", 30, 0.16),  # helles Oliv
    ("#8a9a5b", 22, 0.11),  # Salbei / Moos
    ("#2a3520", 30, 0.10),  # Dunkles Tannengruen
    ("#1c2416", 18, 0.06),  # Schattengruen (kleine Akzente)
]
TEXT_COLOR = "#c9d3a0"


def blob_path(cx, cy, r, rng, points=None):
    """Organischer Fleck: Radius pro Stuetzpunkt variiert, geglaettet mit
    Catmull-Rom -> kubische Bezier-Kurven."""
    n = points or rng.randint(7, 12)
    stretch = rng.uniform(0.55, 1.0)          # Flecken eher laenglich
    rot = rng.uniform(0, math.pi)
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n + rng.uniform(-0.25, 0.25)
        rr = r * rng.uniform(0.55, 1.25)
        x, y = rr * math.cos(a), rr * math.sin(a) * stretch
        # rotieren
        xr = x * math.cos(rot) - y * math.sin(rot)
        yr = x * math.sin(rot) + y * math.cos(rot)
        pts.append((cx + xr, cy + yr))

    def p(i):
        return pts[i % n]

    d = "M%.1f,%.1f" % p(0)
    for i in range(n):
        p0, p1, p2, p3 = p(i - 1), p(i), p(i + 1), p(i + 2)
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += " C%.1f,%.1f %.1f,%.1f %.1f,%.1f" % (c1 + c2 + p2)
    return d + "Z"


def make(width, height, seed, text):
    rng = random.Random(seed)
    scale = min(width, height)
    out = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d">' % (width, height, width, height),
        "<defs>",
        '<radialGradient id="vig" cx="50%" cy="45%" r="75%">'
        '<stop offset="55%" stop-color="#000" stop-opacity="0"/>'
        '<stop offset="100%" stop-color="#000" stop-opacity="0.45"/>'
        "</radialGradient>",
        '<linearGradient id="light" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#ffffff" stop-opacity="0.06"/>'
        '<stop offset="1" stop-color="#000000" stop-opacity="0.10"/>'
        "</linearGradient>",
        "</defs>",
        '<rect width="100%%" height="100%%" fill="%s"/>' % BASE,
    ]

    # Flaechenbezogen skalieren, damit auch Hochformat/Ultrawide gut aussieht
    area_factor = (width * height) / (3840 * 2160)
    for color, count, size in LAYERS:
        out.append('<g fill="%s">' % color)
        for _ in range(max(4, round(count * area_factor * 1.0))):
            r = scale * size * rng.uniform(0.6, 1.3)
            cx, cy = rng.uniform(0, width), rng.uniform(0, height)
            local = random.Random(rng.random())
            d = blob_path(cx, cy, r, local)
            out.append('<path d="%s"/>' % d)
            # Nahtlos kachelbar: Flecken am Rand auf Gegenseite spiegeln
            for dx in (-width, 0, width):
                for dy in (-height, 0, height):
                    if (dx, dy) == (0, 0):
                        continue
                    if (cx + dx + 1.3 * r > 0 and cx + dx - 1.3 * r < width
                            and cy + dy + 1.3 * r > 0 and cy + dy - 1.3 * r < height):
                        out.append('<path transform="translate(%d %d)" d="%s"/>'
                                   % (dx, dy, d))
        out.append("</g>")

    out.append('<rect width="100%" height="100%" fill="url(#light)"/>')
    out.append('<rect width="100%" height="100%" fill="url(#vig)"/>')

    if text:
        fs = scale * 0.045
        x, y = width - fs * 1.2, height - fs * 1.1
        out.append(
            '<text x="%.0f" y="%.0f" text-anchor="end" '
            'font-family="Noto Sans, DejaVu Sans, sans-serif" font-weight="700" '
            'font-size="%.0f" letter-spacing="%.0f" fill="%s" fill-opacity="0.55">'
            'noi<tspan font-weight="300">os</tspan></text>'
            % (x, y, fs, fs * 0.08, TEXT_COLOR))
    out.append("</svg>")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output")
    ap.add_argument("--width", type=int, default=3840)
    ap.add_argument("--height", type=int, default=2160)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--no-text", action="store_true")
    a = ap.parse_args()
    with open(a.output, "w") as f:
        f.write(make(a.width, a.height, a.seed, not a.no_text))


if __name__ == "__main__":
    main()
