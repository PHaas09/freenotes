"""Draws the FreeNotes app icons. Run: python tool/make_icon.py, then: dart run flutter_launcher_icons

assets/icon/icon.png             rounded square (Windows)
assets/icon/icon_full.png        full square, no transparency (iPhone, older Android: the system rounds it)
assets/icon/icon_foreground.png  sheet only, smaller, transparent (Android adaptive icon on a solid background)
"""
import math
from PIL import Image, ImageDraw

S = 1024 * 2  # draw at 2x, then downscale for smooth edges


def gradient():
    g = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(g)
    for y in range(S):
        t = y / S
        c = tuple(int(a + (b - a) * t) for a, b in zip((79, 70, 229), (124, 58, 237)))
        gd.line([(0, y), (S, y)], fill=c + (255,))
    return g


def sheet(img, scale=1.0):
    """Paper with ruled lines and an orange handwritten loop, scaled around the centre."""
    d = ImageDraw.Draw(img)
    f = lambda v: S / 2 + (v - S / 2) * scale  # noqa: E731
    L, T, R, B = f(500), f(380), f(1548), f(1668)
    d.rounded_rectangle([L + 24 * scale, T + 30 * scale, R + 24 * scale, B + 30 * scale], radius=80 * scale, fill=(30, 20, 90, 90))
    d.rounded_rectangle([L, T, R, B], radius=80 * scale, fill=(255, 254, 250, 255))
    y = T + 260 * scale
    while y < B - 80 * scale:
        d.line([(L + 90 * scale, y), (R - 90 * scale, y)], fill=(205, 216, 230, 255), width=round(14 * scale))
        y += 150 * scale
    r = 32 * scale
    for i in range(1201):  # stamp round dots along the curve: smooth edges at any angle
        t = i / 1200
        x = L + 170 * scale + t * (R - L - 340 * scale)
        yy = T + 620 * scale + math.sin(t * math.pi * 3) * 170 * scale * (1 - 0.4 * t)
        d.ellipse([x - r, yy - r, x + r, yy + r], fill=(255, 152, 0, 255))


def save(img, name):
    img.resize((1024, 1024), Image.LANCZOS).save(f"assets/icon/{name}")
    print(f"wrote assets/icon/{name}")


rounded = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([40, 40, S - 40, S - 40], radius=440, fill=255)
rounded.paste(gradient(), (0, 0), mask)
sheet(rounded)
save(rounded, "icon.png")

full = gradient()
sheet(full)
save(full.convert("RGB"), "icon_full.png")

fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sheet(fg, scale=0.72)  # stays inside the circle Android may cut the icon to
save(fg, "icon_foreground.png")
