"""YouTube X app icon: the RUTUBE X shield-and-play glyph on a solid red tile.

Run from the repo root: python3 branding/youtubex/make_icon.py
Writes light, dark and tinted 1024px PNGs into AppIcon_YouTubeX.appiconset.
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 4096
RED = (233, 52, 61)
cx = cy = S / 2
OUT = "firefox-ios/Client/Assets/AppIcons.xcassets/AppIcon_YouTubeX.appiconset"


def shield(w, h, top):
    pts, side = [], 0.48
    for i in range(51):
        t = i / 50
        pts.append((cx - w / 2 + w * t, top + h * 0.05 * (4 * (t - 0.5) ** 2)))
    yb = top + h * side
    for i in range(1, 61):
        t = i / 60
        pts.append((cx + (w / 2) * math.cos(t * math.pi / 2) ** 1.15, yb + (top + h - yb) * math.sin(t * math.pi / 2)))
    for i in range(59, -1, -1):
        t = i / 60
        pts.append((cx - (w / 2) * math.cos(t * math.pi / 2) ** 1.15, yb + (top + h - yb) * math.sin(t * math.pi / 2)))
    return pts


def centroid(pts):
    a = gx = gy = 0
    for (x0, y0), (x1, y1) in zip(pts, pts[1:] + pts[:1]):
        c = x0 * y1 - x1 * y0
        a += c
        gx += (x0 + x1) * c
        gy += (y0 + y1) * c
    a /= 2
    return gx / (6 * a), gy / (6 * a)


sc = 0.85
W, H, k = S * 0.58 * sc, S * 0.68 * sc, 0.085 * S * sc
_, iy = centroid(shield(W - 2 * k, H - 2.3 * k, k))
T = cy - iy
outer, inner = shield(W, H, T), shield(W - 2 * k, H - 2.3 * k, T + k)
r = S * 0.13 * sc
L, R = -r * 0.8, r * 0.95
ax = cx - (2 * L + R) / 3
tri = [(ax + L, cy - r), (ax + L, cy + r), (ax + R, cy)]


def vgrad(c_top, c_bot, y_from, y_to):
    g = Image.new("RGB", (1, S))
    for y in range(S):
        t = min(1, max(0, (y - y_from) / (y_to - y_from)))
        g.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(c_top, c_bot)))
    return g.resize((S, S))


def glyph_mask():
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.polygon(outer, fill=255)
    d.polygon(inner, fill=0)
    d.polygon(tri, fill=255)
    return m.filter(ImageFilter.GaussianBlur(42)).point(
        lambda v: 0 if v < 118 else (255 if v > 138 else int((v - 118) * 12.75)))


def solid(color):
    return Image.new("RGB", (S, S), color)


def render(background, glyph_top, glyph_bottom, shadow_color, glow_color, bevel_low):
    img = solid(background)
    mask = glyph_mask()
    glow = mask.filter(ImageFilter.MaxFilter(31)).filter(ImageFilter.GaussianBlur(110)).point(lambda v: int(v * 0.30))
    img.paste(solid(glow_color), (0, 0), glow)
    shadow = ImageChops.offset(mask, 0, 80).filter(ImageFilter.GaussianBlur(95)).point(lambda v: int(v * 0.38))
    img.paste(solid(shadow_color), (0, 0), shadow)
    img.paste(vgrad(glyph_top, glyph_bottom, T, T + H), (0, 0), mask)
    edge = 30
    lower = ImageChops.subtract(mask, ImageChops.offset(mask, 0, -edge)).filter(ImageFilter.GaussianBlur(18))
    img.paste(solid(bevel_low), (0, 0), ImageChops.multiply(lower, mask).point(lambda v: int(v * 0.28)))
    upper = ImageChops.subtract(mask, ImageChops.offset(mask, 0, edge)).filter(ImageFilter.GaussianBlur(18))
    img.paste(solid((255, 255, 255)), (0, 0), ImageChops.multiply(upper, mask).point(lambda v: int(v * 0.9)))
    return img.resize((1024, 1024), Image.LANCZOS)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    # Light: white glyph on the solid red tile.
    render(RED, (255, 255, 255), (232, 226, 228), (90, 6, 14), (255, 236, 238), (150, 90, 96)).save(f"{OUT}/youtubex-light.png")
    # Dark: red glyph on near-black, as iOS dark icons do.
    render((22, 18, 20), (244, 70, 78), (214, 40, 50), (0, 0, 0), (120, 20, 26), (120, 20, 28)).save(f"{OUT}/youtubex-dark.png")
    # Tinted: a grayscale glyph on black that iOS colors with the user's tint.
    render((0, 0, 0), (255, 255, 255), (205, 205, 205), (0, 0, 0), (40, 40, 40), (110, 110, 110)).convert("L").convert("RGB").save(f"{OUT}/youtubex-tinted.png")
    print("Wrote", OUT)
