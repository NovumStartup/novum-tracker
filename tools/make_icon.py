#!/usr/bin/env python3
"""Generate the Novum Startup Tracker marketplace icon (128x128 PNG).

Deterministic: re-running leaves `git diff` empty. Renders the live Novum brand
mark (cyan/teal hexagon "pod" + green center dot on a dark plate) from the app's
own design tokens (src/styles/tokens.css):

    --novum-bg-0  #08090f   plate
    --novum-info  #2dd4bf   hexagon stroke
    --novum-accent #4ade80  center dot

Usage:  python3 tools/make_icon.py
"""
from PIL import Image, ImageDraw, ImageFilter

OUT = 128          # marketplace requires 128x128
SS = 8             # supersample factor for clean anti-aliasing
S = OUT * SS       # 1024 master

BG = (8, 9, 15, 255)        # #08090f
TEAL = (45, 212, 191)       # #2dd4bf  (--novum-info)
GREEN = (74, 222, 128)      # #4ade80  (--novum-accent)

# Hexagon vertices in the app logo's 40-unit space (pointy-top "pod").
VERTS40 = [(20, 4), (31.5, 10.25), (31.5, 25.75), (20, 32), (8.5, 25.75), (8.5, 10.25)]
HEX_H = 32 - 4              # 28 user units tall
CX40, CY40 = 20, 18        # hexagon center (matches the dot)

scale = (0.60 * S) / HEX_H  # hexagon spans 60% of the canvas height


def tx(p):
    x, y = p
    return ((x - CX40) * scale + S / 2, (y - CY40) * scale + S / 2)


verts = [tx(p) for p in VERTS40]
dot_c = tx((20, 18))
dot_r = 3.1 * scale
stroke = max(2, round(1.4 * scale))

# Base dark plate (rounded square; transparent corners are fine on marketplace).
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(img).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=BG)

# Bloom layer: thick hexagon outline + dot, blurred and dimmed for a neon glow.
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.line(verts + [verts[0]], fill=TEAL + (255,), width=stroke * 2, joint="curve")
gd.ellipse(
    [dot_c[0] - dot_r * 1.5, dot_c[1] - dot_r * 1.5,
     dot_c[0] + dot_r * 1.5, dot_c[1] + dot_r * 1.5],
    fill=GREEN + (255,),
)
glow = glow.filter(ImageFilter.GaussianBlur(radius=S * 0.03))
glow.putalpha(glow.split()[3].point(lambda a: int(a * 0.55)))
img = Image.alpha_composite(img, glow)

# Sharp layer: 7% teal fill + crisp teal hexagon stroke + solid green dot.
sharp = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(sharp)
sd.polygon(verts, fill=TEAL + (18,))
sd.line(verts + [verts[0]], fill=TEAL + (255,), width=stroke, joint="curve")
sd.ellipse(
    [dot_c[0] - dot_r, dot_c[1] - dot_r, dot_c[0] + dot_r, dot_c[1] + dot_r],
    fill=GREEN + (255,),
)
img = Image.alpha_composite(img, sharp)

icon = img.resize((OUT, OUT), Image.LANCZOS)
icon.save("icon.png")
print(f"wrote icon.png {icon.size}")
