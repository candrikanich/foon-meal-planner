# Draws Foon QA's icon (the Staging build, docs/foon-qa.md): Foon's icon with a blue "QA" band across the bottom, so the
# test app never looks like the family's Foon on a home screen. Rerun when AppIcon changes. Needs Pillow (not committed):
#   python3 scripts/make-qa-icon.py Foon/Resources/Assets.xcassets
import pathlib
import sys
from PIL import Image, ImageDraw, ImageFont

assets = pathlib.Path(sys.argv[1])
source, out = assets / "AppIcon.appiconset", assets / "AppIcon-QA.appiconset"
band, ink = (0x1F, 0x5F, 0xC8), (0xFF, 0xFF, 0xFF)
font_path = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

S = 1024
img = Image.open(source / "icon-1024.png").convert("RGB")  # no alpha: App Store rejects transparent icons
d = ImageDraw.Draw(img)
top = int(S * 0.72)  # low enough to keep the plate's spork, tall enough to read at home-screen size
d.rectangle((0, top, S, S), fill=band)
font = ImageFont.truetype(font_path, 220)
d.text((S / 2, (top + S) / 2), "QA", font=font, fill=ink, anchor="mm")

out.mkdir(exist_ok=True)
img.save(out / "icon-1024.png")
img.resize((512, 512), Image.LANCZOS).save(out / "icon-512.png")
(out / "Contents.json").write_text((source / "Contents.json").read_text())
