#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/
"""Regenerates Ferret's in-app brand artwork (logos, wordmark, illustrations).

Requires: pip install cairosvg fonttools pillow. Run from the repository root.
"""
import base64
import io
import json
import os
import sys

import cairosvg
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONT = os.environ.get("FLAMEFERRET_FONT", "/usr/share/texmf/fonts/opentype/public/tex-gyre/texgyrepagella-bold.otf")

TAIL = "M360 640 C300 650 240 640 200 600 C150 550 140 470 168 400 C176 450 196 480 222 495 C200 440 205 370 245 300 C250 360 268 400 298 425 C290 370 305 300 350 245 C350 320 372 370 405 405 C430 440 440 500 430 560 C425 600 400 630 360 640 Z"
CORE = "M362 620 C320 625 275 610 252 575 C230 540 232 495 250 460 C262 500 285 520 310 528 C298 485 305 430 340 385 C345 430 362 465 388 485 C410 515 412 560 400 590 C392 610 380 618 362 620 Z"
REAR = "M378 655 C352 690 318 712 288 722 C268 728 262 748 280 754 C312 762 350 748 378 724 C398 706 412 690 424 672 Z"
BODY = "M352 690 C330 600 380 500 470 455 C560 410 660 420 730 470 C770 498 795 530 812 562 L790 640 C760 625 720 600 680 590 C620 576 560 585 510 615 C470 640 440 680 420 712 C398 716 368 712 352 690 Z"
FL1 = "M690 600 C705 645 720 690 742 722 C752 738 772 738 778 724 C782 700 770 665 752 625 Z"
FL2 = "M640 596 C650 645 660 692 676 728 C684 746 706 746 710 730 C714 704 704 664 692 616 Z"
HEAD = "M720 500 C750 455 815 445 860 470 C895 490 915 525 930 560 C945 592 950 618 938 632 C922 650 885 648 850 640 C805 630 760 610 735 580 C712 553 706 525 720 500 Z"
EAR = "M748 480 C735 445 748 418 775 414 C792 424 798 450 790 470 Z"
MARK_BOX = (138, 240, 820, 525)

DEFS = """<linearGradient id="fo" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#E4470B"/><stop offset="1" stop-color="#FB923C"/></linearGradient>
<linearGradient id="fc" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#FDBA74"/><stop offset="1" stop-color="#FFEDD5"/></linearGradient>
<linearGradient id="bd" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#DC2626"/><stop offset="1" stop-color="#991B1B"/></linearGradient>"""


def mark(color=None, eye="#FFFFFF"):
    """The ferret mark in its native coordinates. `color` makes a one-color silhouette."""
    def p(d, fill):
        return f'<path d="{d}" fill="{color or fill}"/>'
    shapes = (p(TAIL, "url(#fo)") + p(CORE, "url(#fc)") + p(REAR, "#8F1717") + p(BODY, "url(#bd)")
              + p(FL1, "#B91C1C") + p(FL2, "#8F1717") + p(HEAD, "url(#bd)") + p(EAR, "url(#bd)"))
    if color:
        shapes = (p(TAIL, "") + p(REAR, "") + p(BODY, "") + p(FL1, "") + p(FL2, "") + p(HEAD, "") + p(EAR, ""))
    if eye:
        shapes += f'<circle cx="844" cy="517" r="12" fill="{eye}"/>'
    return shapes


LOGO_PATH = os.path.join(ROOT, "branding/ferret-logo.png")
LOGO_DARK_PATH = os.path.join(ROOT, "branding/ferret-logo-dark.png")
LOGO_CURRENT = [LOGO_PATH]


def logo_data_uri(color=None):
    """The raster logo (branding/ferret-logo.png) as a data URI, optionally as a one-color silhouette."""
    image = Image.open(LOGO_CURRENT[0]).convert("RGBA")
    image.thumbnail((600, 600), Image.LANCZOS)
    if color:
        rgb = tuple(int(color.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
        silhouette = Image.new("RGBA", image.size, rgb + (255,))
        silhouette.putalpha(image.getchannel("A"))
        image = silhouette
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode()


def placed(x, y, w, h, color=None, eye="#FFFFFF", flip=False):
    """The logo fitted into the box (x, y, w, h); falls back to the vector ferret mark."""
    if os.path.exists(LOGO_PATH):
        side = min(w, h)
        ox = x + (w - side) / 2
        oy = y + (h - side) / 2
        return (f'<image x="{ox:.2f}" y="{oy:.2f}" width="{side:.2f}" height="{side:.2f}" '
                f'href="{logo_data_uri(color)}"/>')
    bx, by, bw, bh = MARK_BOX
    scale = min(w / bw, h / bh)
    ox = x + (w - bw * scale) / 2
    oy = y + (h - bh * scale) / 2
    flip_t = f" translate({bw * scale} 0) scale(-1 1)" if flip else ""
    return (f'<g transform="translate({ox:.2f} {oy:.2f}){flip_t} scale({scale:.5f}) translate({-bx} {-by})">'
            f"{mark(color, eye)}</g>")


def svg(w, h, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
            f"<defs>{DEFS}</defs>{body}</svg>")


def wordmark_path(text, height, tracking=0.0):
    font = TTFont(FONT)
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    units = font["head"].unitsPerEm
    ascent = font["hhea"].ascent
    x = 0
    paths = []
    for char in text:
        name = cmap[ord(char)]
        pen = SVGPathPen(glyphs)
        glyphs[name].draw(pen)
        paths.append(f'<path transform="translate({x} 0)" d="{pen.getCommands()}"/>')
        x += glyphs[name].width + tracking * units
    cap = font["OS/2"].sCapHeight or int(units * 0.7)
    descent = 0
    scale = height / cap
    if text:
        x -= tracking * units
    return paths, x * scale, scale, cap


def wordmark(text, height, color, tracking=0.0):
    paths, width, scale, cap = wordmark_path(text, height, tracking)
    width = round(width + 1, 2)
    group = f'<g fill="{color}" transform="translate(0 {height}) scale({scale:.6f} {-scale:.6f})">{"".join(paths)}</g>'
    return width, group


def sparkle(cx, cy, r, color):
    return (f'<path d="M{cx} {cy - r} C{cx + r * 0.18} {cy - r * 0.18} {cx + r * 0.18} {cy - r * 0.18} {cx + r} {cy} '
            f'C{cx + r * 0.18} {cy + r * 0.18} {cx + r * 0.18} {cy + r * 0.18} {cx} {cy + r} '
            f'C{cx - r * 0.18} {cy + r * 0.18} {cx - r * 0.18} {cy + r * 0.18} {cx - r} {cy} '
            f'C{cx - r * 0.18} {cy - r * 0.18} {cx - r * 0.18} {cy - r * 0.18} {cx} {cy - r} Z" fill="{color}"/>')


def write_pdf(svg_text, path):
    cairosvg.svg2pdf(bytestring=svg_text.encode(), write_to=path)


def write_png(svg_text, path, width, height):
    cairosvg.svg2png(bytestring=svg_text.encode(), write_to=path, output_width=width, output_height=height)


def asset(path):
    return os.path.join(ROOT, path)


def main():
    client = "firefox-ios/Client/Assets/Images.xcassets"
    kit = "BrowserKit/Sources/OnboardingKit/Media.xcassets"

    # Color mark: home header, onboarding header ball.
    ball = svg(77.42, 79.97, placed(0, 8, 77.42, 64))
    for base in (client, kit):
        write_pdf(ball, asset(f"{base}/fxHomeHeaderLogoBall.imageset/fxLogo.pdf"))

    # Template glyphs (tinted by the app).
    glyph = svg(24, 24, placed(0.5, 0.5, 23, 23, color="#000000", eye="#FFFFFF"))
    for path in (f"{client}/logoFirefoxLarge.imageset/logoFirefoxLarge.pdf",
                 "firefox-ios/Extensions/ShareTo/Images.xcassets/logoFirefoxLarge.imageset/logoFirefoxLarge.pdf",
                 "SampleComponentLibraryApp/SampleComponentLibraryApp/Assets.xcassets/logoFirefoxLarge.imageset/logoFirefoxLarge.pdf"):
        if os.path.exists(asset(path)):
            write_pdf(glyph, asset(path))

    # White silhouette on the launch screen loader.
    write_pdf(svg(121, 125, placed(4, 10, 113, 105, color="#FFFFFF", eye=None)),
              asset(f"{kit}/firefoxLoader.imageset/firefoxLoader.pdf"))

    # Wordmark next to the home header logo (template-rendered, so drawn in black).
    width, group = wordmark("FERRET", 20, "#000000", tracking=0.12)
    word_svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="26" '
                f'viewBox="0 -1 {width} 26">{group}</svg>')
    write_pdf(word_svg, asset(f"{client}/fxHomeHeaderLogoText.imageset/fxHomeHeaderLogoText.pdf"))

    # Launch screen splash and credential-provider glyph.
    for name, scale in (("splash.png", 1), ("splash@2x.png", 2), ("splash@3x.png", 3)):
        write_png(svg(134, 134, placed(10, 14, 114, 106)), asset(f"{client}/splash.imageset/{name}"),
                  134 * scale, 134 * scale)
    logo_glyph = "firefox-ios/CredentialProvider/CredentialAssets.xcassets/logo-glyph.imageset"
    for name, scale in (("splash.png", 1), ("splash@2x.png", 2), ("splash@3x.png", 3)):
        write_png(svg(134, 134, placed(10, 14, 114, 106)), asset(f"{logo_glyph}/{name}"), 134 * scale, 134 * scale)

    # Small favicon used for the built-in home page entry.
    icon = os.path.join(ROOT, "branding/ferret-icon-1024.png")
    for folder in (f"{client}/faviconFox.imageset", "firefox-ios/WidgetKit/Assets.xcassets/faviconFox.imageset"):
        for name, size in (("back-panel-home.png", 29), ("back-panel-home@2x.png", 58), ("back-panel-home@3x.png", 87)):
            if os.path.isdir(asset(folder)):
                Image.open(icon).resize((size, size), Image.LANCZOS).save(asset(f"{folder}/{name}"))

    # Illustrations.
    check = ('<circle cx="40" cy="44" r="30" fill="#22C55E"/>'
             '<path d="M26 45 L36 55 L55 35" fill="none" stroke="#FFFFFF" stroke-width="7" '
             'stroke-linecap="round" stroke-linejoin="round"/>')
    write_pdf(svg(148.16, 135.05, placed(30, 30, 118, 100) + check),
              asset(f"{client}/foxConfirmation.imageset/foxConfirmation.pdf"))

    stars = sparkle(14, 18, 9, "#9E2B2B") + sparkle(26, 34, 5, "#0E2340") + sparkle(66, 14, 6, "#9E2B2B")
    write_pdf(svg(78, 88, placed(2, 28, 74, 56) + stars), asset(f"{client}/foxWithStars.imageset/foxWithStars.pdf"))

    window = ('<rect x="14" y="10" width="212" height="243" rx="22" fill="#FFF7ED" stroke="#1C1917" stroke-width="4"/>'
              '<circle cx="168" cy="70" r="30" fill="#FDBA74"/>'
              '<path d="M14 190 C70 160 120 175 226 150 V231 C226 243 218 253 204 253 H36 C22 253 14 243 14 231 Z" '
              'fill="#FED7AA"/>')
    write_pdf(svg(240, 263, window + placed(30, 120, 180, 110)),
              asset(f"{client}/Onboarding/Headers/onboardingFoxyWindow.imageset/buildABetterWeb.pdf"))

    glow = ('<radialGradient id="halo" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#0E2340" '
            'stop-opacity="0.12"/><stop offset="1" stop-color="#0E2340" stop-opacity="0"/></radialGradient>')
    welcome = svg(171.63, 201.11, f'<defs>{glow}</defs><ellipse cx="72" cy="100" rx="80" ry="72" fill="url(#halo)"/>'
                  + placed(4, 40, 164, 120))
    write_pdf(welcome, asset(f"{kit}/onboardingWelcomeBrandRefresh.imageset/onboardingWelcomeBrandRefresh.pdf"))
    welcome_square = svg(238, 238, f'<defs>{glow}</defs><ellipse cx="100" cy="118" rx="110" ry="96" fill="url(#halo)"/>'
                         + placed(8, 50, 222, 140))
    write_pdf(welcome_square, asset(f"{kit}/onboardingWelcomeJapan.imageset/Firefox_Marco_Icons_x2.pdf"))

    devices = ('<rect x="40" y="12" width="168" height="112" rx="10" fill="#FFFFFF" stroke="#1C1917" stroke-width="4"/>'
               '<rect x="24" y="124" width="200" height="10" rx="5" fill="#1C1917"/>'
               '<rect x="236" y="34" width="56" height="108" rx="12" fill="#FFFFFF" stroke="#1C1917" stroke-width="4"/>'
               '<path d="M214 70 h14 m-6 -6 l6 6 l-6 6" fill="none" stroke="#F97316" stroke-width="4" '
               'stroke-linecap="round" stroke-linejoin="round"/>')
    write_pdf(svg(301.53, 150, devices + placed(70, 30, 108, 78) + placed(242, 66, 44, 40)),
              asset(f"{kit}/onboardingSyncWithIconsBrandRefresh.imageset/onboardingSyncWithIconsBrandRefresh.pdf"))

    phone = ('<rect x="96" y="6" width="54" height="96" rx="10" fill="#FFFFFF" stroke="#1C1917" stroke-width="3"/>'
             '<rect x="104" y="20" width="38" height="8" rx="4" fill="#FED7AA"/>'
             '<rect x="104" y="34" width="38" height="8" rx="4" fill="#DC2626"/>')
    write_png(svg(156, 106, phone + placed(0, 30, 96, 72)),
              asset(f"{client}/foxDefaultBrowser.imageset/Illu.png"), 468, 318)
    write_dark_variants(client, kit)
    print("Brand assets written")


def add_dark_appearance(imageset, light_name, dark_name, scale=None):
    """Adds a dark-mode file next to the light one in an asset catalog image set."""
    path = asset(f"{imageset}/Contents.json")
    with open(path) as handle:
        contents = json.load(handle)
    images = [entry for entry in contents["images"] if "appearances" not in entry]
    for entry in list(images):
        if entry.get("filename") == light_name:
            dark = dict(entry)
            dark["filename"] = dark_name
            dark["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
            images.append(dark)
    contents["images"] = images
    with open(path, "w") as handle:
        json.dump(contents, handle, indent=2)
        handle.write("\n")


def write_dark_variants(client, kit):
    """Dark-mode copies of the color logo artwork, drawn with the light-on-dark logo."""
    LOGO_CURRENT[0] = LOGO_DARK_PATH
    try:
        ball = svg(77.42, 79.97, placed(0, 8, 77.42, 64))
        for base in (client, kit):
            folder = f"{base}/fxHomeHeaderLogoBall.imageset"
            write_pdf(ball, asset(f"{folder}/fxLogo-dark.pdf"))
            add_dark_appearance(folder, "fxLogo.pdf", "fxLogo-dark.pdf")
        for name, scale in (("splash.png", 1), ("splash@2x.png", 2), ("splash@3x.png", 3)):
            dark_name = name.replace("splash", "splash-dark")
            write_png(svg(134, 134, placed(10, 14, 114, 106)), asset(f"{client}/splash.imageset/{dark_name}"),
                      134 * scale, 134 * scale)
            add_dark_appearance(f"{client}/splash.imageset", name, dark_name)
        welcome = svg(171.63, 201.11, placed(4, 40, 164, 120))
        folder = f"{kit}/onboardingWelcomeBrandRefresh.imageset"
        write_pdf(welcome, asset(f"{folder}/onboardingWelcomeBrandRefresh-dark.pdf"))
        add_dark_appearance(folder, "onboardingWelcomeBrandRefresh.pdf", "onboardingWelcomeBrandRefresh-dark.pdf")
        welcome_square = svg(238, 238, placed(8, 50, 222, 140))
        folder = f"{kit}/onboardingWelcomeJapan.imageset"
        write_pdf(welcome_square, asset(f"{folder}/Firefox_Marco_Icons_x2-dark.pdf"))
        add_dark_appearance(folder, "Firefox_Marco_Icons_x2.pdf", "Firefox_Marco_Icons_x2-dark.pdf")
        stars = sparkle(14, 18, 9, "#E05A4F") + sparkle(26, 34, 5, "#EDE8DA") + sparkle(66, 14, 6, "#E05A4F")
        folder = f"{client}/foxWithStars.imageset"
        write_pdf(svg(78, 88, placed(2, 28, 74, 56) + stars), asset(f"{folder}/foxWithStars-dark.pdf"))
        add_dark_appearance(folder, "foxWithStars.pdf", "foxWithStars-dark.pdf")
    finally:
        LOGO_CURRENT[0] = LOGO_PATH


if __name__ == "__main__":
    sys.exit(main())
