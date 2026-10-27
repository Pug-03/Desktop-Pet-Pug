"""Make App/Resources/AppIcon.icns from the chibi idle frame."""
import json
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SP = os.path.join(ROOT, "App", "Resources", "sprites")

meta = json.load(open(os.path.join(SP, "pet.json")))["stand.shy.0"]
x, y, w, h = meta["rect"]
pet = Image.open(os.path.join(SP, "pet.png")).crop((x, y, x + w, y + h))
pet = pet.crop(pet.getbbox())
pet = pet.crop((0, 0, pet.width, 120))  # head and shoulders read best at icon size

base = 1024
icon = Image.new("RGBA", (base, base), (0, 0, 0, 0))
bg = Image.new("RGBA", (base, base), (0, 0, 0, 0))
d = ImageDraw.Draw(bg)
d.rounded_rectangle((100, 100, 924, 924), radius=185, fill=(255, 226, 234, 255))
icon.alpha_composite(bg)
k = 700 // max(pet.width, pet.height)
big = pet.resize((pet.width * k, pet.height * k), Image.LANCZOS)
icon.alpha_composite(big, ((base - big.width) // 2, 924 - big.height))

with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for s in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = s * scale
            icon.resize((px, px), Image.LANCZOS).save(
                os.path.join(iconset, f"icon_{s}x{s}{'@2x' if scale == 2 else ''}.png"))
    subprocess.check_call(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ROOT, "App", "Resources", "AppIcon.icns")])
icon.save(os.path.join(ROOT, "art", "icon_preview.png"))
