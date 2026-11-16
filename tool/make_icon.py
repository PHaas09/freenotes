"""Draws the FreeNotes app icon (assets/icon/icon.png). Run: python tool/make_icon.py"""
import math
from PIL import Image, ImageDraw

S = 1024 * 2  # draw at 2x, then downscale for smooth edges
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Background: rounded square with an indigo -> violet gradient
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = y / S
    c = tuple(int(a + (b - a) * t) for a, b in zip((79, 70, 229), (124, 58, 237)))
    gd.line([(0, y), (S, y)], fill=c + (255,))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([40, 40, S - 40, S - 40], radius=440, fill=255)
img.paste(grad, (0, 0), mask)

d = ImageDraw.Draw(img)
# Paper sheet with ruled lines
L, T, R, B = 500, 380, 1548, 1668
d.rounded_rectangle([L + 24, T + 30, R + 24, B + 30], radius=80, fill=(30, 20, 90, 90))  # shadow
d.rounded_rectangle([L, T, R, B], radius=80, fill=(255, 254, 250, 255))
for y in range(T + 260, B - 80, 150):
    d.line([(L + 90, y), (R - 90, y)], fill=(205, 216, 230, 255), width=14)

# Handwritten orange loop across the page
pts = []
for i in range(1201):
    t = i / 1200
    x = L + 170 + t * (R - L - 340)
    y = T + 620 + math.sin(t * math.pi * 3) * 170 * (1 - 0.4 * t)
    pts.append((x, y))
for p in pts:  # stamp round dots along the curve: smooth edges at any angle
    d.ellipse([p[0] - 32, p[1] - 32, p[0] + 32, p[1] + 32], fill=(255, 152, 0, 255))

img.resize((1024, 1024), Image.LANCZOS).save("assets/icon/icon.png")
print("wrote assets/icon/icon.png")
