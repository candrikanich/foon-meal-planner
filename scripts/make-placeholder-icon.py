# Draws the placeholder app icon (a spork on a plate in Foon's paprika and cream) for internal TestFlight.
# Replace with a designed icon before external testing. Usage: python3 scripts/make-placeholder-icon.py <appiconset dir>
import sys
from PIL import Image, ImageDraw
paprika, cream, rim = (0xB5, 0x48, 0x1F), (0xFB, 0xF5, 0xEC), (0xEE, 0xE2, 0xD0)
S, K = 1024, 4  # draw 4x and scale down for smooth edges
B = S * K
img = Image.new("RGB", (B, B), paprika)  # no alpha: App Store rejects transparent icons
d = ImageDraw.Draw(img)
c, r = B / 2, 370 * K
d.ellipse((c - r, c - r, c + r, c + r), fill=cream)                                   # the plate
d.ellipse((c - r + 44 * K, c - r + 44 * K, c + r - 44 * K, c + r - 44 * K), outline=rim, width=12 * K)

# A spork (a "foon"): a spoon bowl with three short tines, on a rounded handle. Drawn upright, then tilted.
layer = Image.new("L", (B, B), 0)
m = ImageDraw.Draw(layer)
bw, bh = 200 * K, 260 * K            # bowl
top = c - 290 * K
m.ellipse((c - bw / 2, top, c + bw / 2, top + bh), fill=255)
for x in (-1, 1):                    # two gaps make three tines
    gx = c + x * bw / 6
    m.rounded_rectangle((gx - 11 * K, top - 10 * K, gx + 11 * K, top + 82 * K), radius=11 * K, fill=0)
hw = 64 * K                          # handle
m.rounded_rectangle((c - hw / 2, top + bh - 40 * K, c + hw / 2, c + 300 * K), radius=hw / 2, fill=255)
layer = layer.rotate(-35, resample=Image.BICUBIC, center=(c, c))
img.paste(paprika, (0, 0, B, B), layer)

img = img.resize((S, S), Image.LANCZOS)
out = sys.argv[1]
img.save(f"{out}/icon-1024.png")
img.resize((512, 512), Image.LANCZOS).save(f"{out}/icon-512.png")
