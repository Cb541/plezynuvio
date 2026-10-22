#!/usr/bin/env python3
"""Generate tvOS layered Apple TV icons from the approved Nuvio artwork."""
import json
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AppIconSource.png"
ASSETS = ROOT / "Assets.xcassets"
BRAND = ASSETS / "App Icon & Top Shelf Image.brandassets"
INFO = {"author": "xcode", "version": 1}

def save_json(folder, obj):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Contents.json").write_text(json.dumps(obj, indent=2) + "\n")

def icon(w, h, layer):
    image = Image.new("RGBA", (w, h), (0, 0, 0, 0) if layer == "front" else (0, 0, 0, 255))
    if layer == "back":
        return image
    side = round(h * 0.94)
    left, top = (w - side) // 2, (h - side) // 2
    if SOURCE.exists():
        art = Image.open(SOURCE).convert("RGBA")
        # Crop only outer black margins; preserve the user's glossy icon.
        d = min(art.size)
        margin = round(d * 0.125)
        x, y = (art.width - d) // 2, (art.height - d) // 2
        art = art.crop((x + margin, y + margin, x + d - margin, y + d - margin))
        art = art.resize((side, side), Image.Resampling.LANCZOS)
        image.alpha_composite(art, (left, top))
    else:
        # Fallback icon keeps builds healthy before the approved PNG is uploaded.
        draw = ImageDraw.Draw(image)
        rect = (left + 3, top + 3, left + side - 4, top + side - 4)
        draw.rounded_rectangle(rect, radius=side // 5,
                               fill=(4, 7, 14, 255), outline=(22, 116, 245, 255),
                               width=max(2, side // 85))
        draw.polygon([(left + side * .31, top + side * .23),
                      (left + side * .75, top + side * .50),
                      (left + side * .31, top + side * .77)], fill=(25, 156, 252, 255))
    return image

def stack(name, resolutions):
    folder = BRAND / (name + ".imagestack")
    save_json(folder, {"info": INFO, "layers": [
        {"filename": "Front.imagestacklayer"},
        {"filename": "Back.imagestacklayer"}]})
    for layer in ("Front", "Back"):
        layer_folder = folder / (layer + ".imagestacklayer")
        save_json(layer_folder, {"info": INFO})
        image_folder = layer_folder / "Content.imageset"
        images = []
        for w, h, scale in resolutions:
            filename = layer.lower() + ("@" + scale if scale else "") + ".png"
            descriptor = {"filename": filename, "idiom": "tv"}
            if scale:
                descriptor["scale"] = scale
            images.append(descriptor)
            image_folder.mkdir(parents=True, exist_ok=True)
            icon(w, h, layer.lower()).save(image_folder / filename)
        save_json(image_folder, {"info": INFO, "images": images})

save_json(ASSETS, {"info": INFO})
save_json(BRAND, {"info": INFO, "assets": [
    {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
]})
stack("App Icon", [(400, 240, "1x"), (800, 480, "2x")])
stack("App Icon - App Store", [(1280, 768, "")])
for title, width in (("Top Shelf Image", 1920), ("Top Shelf Image Wide", 2320)):
    folder = BRAND / (title + ".imageset")
    folder.mkdir(parents=True, exist_ok=True)
    picture = Image.new("RGBA", (width, 720), (0, 0, 0, 255))
    picture.alpha_composite(icon(width, 720, "front"))
    picture.convert("RGB").save(folder / "shelf.png")
    save_json(folder, {"info": INFO, "images": [{"filename": "shelf.png", "idiom": "tv"}]})
print("tvOS icon generated from", SOURCE if SOURCE.exists() else "fallback")
