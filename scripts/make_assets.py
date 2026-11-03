import json, os, sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

root = sys.argv[1]
os.makedirs(root, exist_ok=True)
INFO = {"author": "xcode", "version": 1}
def dump(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(obj, open(path, "w"), indent=2)

NIGHT = (7, 11, 22); RAISED = (14, 26, 52); MOON = (143, 184, 255); EMBER = (255, 107, 85)

def back(w, h):
    img = Image.new("RGB", (w, h), NIGHT)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / h
        c = tuple(int(RAISED[i] * (1 - t) + NIGHT[i] * t) for i in range(3))
        d.line([(0, y), (w, y)], fill=c)
    # halo lunaire diffus
    halo = Image.new("L", (w, h), 0)
    hd = ImageDraw.Draw(halo)
    r = int(h * 0.55); cx, cy = int(w * 0.62), int(h * 0.42)
    hd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=90)
    halo = halo.filter(ImageFilter.GaussianBlur(h * 0.18))
    glow = Image.new("RGB", (w, h), MOON)
    img = Image.composite(glow, img, halo)
    return img

def front(w, h, text=False):
    """Cadran à minuit : couronne lunaire, index, aiguilles superposées sur 12 h, aiguille braise."""
    s = 4  # suréchantillonnage
    big = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    cx, cy = w * s / 2, h * s / 2
    r = h * s * 0.36
    ring = max(2, int(r * 0.075))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(238, 242, 250, 255), width=ring)
    for k in range(12):
        ang = math.radians(k * 30)
        major = k % 3 == 0
        r1 = r * (0.70 if major else 0.78)
        r2 = r * 0.86
        if k == 0:
            continue  # le 12 est porté par les aiguilles
        d.line([cx + r1 * math.sin(ang), cy - r1 * math.cos(ang), cx + r2 * math.sin(ang), cy - r2 * math.cos(ang)],
               fill=MOON + (255,), width=int(r * (0.05 if major else 0.028)))
    # aiguille des heures (lune) puis des minutes (braise), toutes deux sur 12 h
    hw = int(r * 0.11)
    d.rounded_rectangle([cx - hw / 2, cy - r * 0.50, cx + hw / 2, cy + hw / 2], radius=hw / 2, fill=(238, 242, 250, 255))
    mw = int(r * 0.055)
    d.rounded_rectangle([cx - mw / 2, cy - r * 0.80, cx + mw / 2, cy + mw / 2], radius=mw / 2, fill=EMBER + (255,))
    pr = r * 0.085
    d.ellipse([cx - pr, cy - pr, cx + pr, cy + pr], fill=EMBER + (255,))
    return big.resize((w, h), Image.LANCZOS)

def write_stack(name, sizes):
    stack = os.path.join(root, "App Icon & Top Shelf Image.brandassets", name + ".imagestack")
    dump(os.path.join(stack, "Contents.json"), {"info": INFO, "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}]})
    for layer, maker in (("Front", front), ("Back", back)):
        ldir = os.path.join(stack, layer + ".imagestacklayer")
        dump(os.path.join(ldir, "Contents.json"), {"info": INFO})
        images = []
        for scale, (w, h) in sizes:
            fn = f"{layer.lower()}{'' if scale == '1x' else '@' + scale}.png"
            maker(w, h).save(os.path.join(ldir, "Content.imageset", fn)) if os.makedirs(os.path.join(ldir, "Content.imageset"), exist_ok=True) is None else None
            images.append({"idiom": "tv", "scale": scale, "filename": fn})
        dump(os.path.join(ldir, "Content.imageset", "Contents.json"), {"images": images, "info": INFO})

def topshelf(name, sizes):
    d = os.path.join(root, "App Icon & Top Shelf Image.brandassets", name + ".imageset")
    os.makedirs(d, exist_ok=True)
    images = []
    for scale, (w, h) in sizes:
        img = back(w, h).convert("RGBA")
        f = front(int(h * 1.6), h)
        img.alpha_composite(f, (int(w * 0.08), 0))
        try:
            font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf", int(h * 0.22))
            ImageDraw.Draw(img).text((int(w * 0.08 + h * 1.36), int(h * 0.36)), "Minuit", font=font, fill=(238, 242, 250, 255))
        except Exception:
            pass
        fn = f"topshelf{'' if scale == '1x' else '@' + scale}.png"
        img.convert("RGB").save(os.path.join(d, fn))
        images.append({"idiom": "tv", "scale": scale, "filename": fn})
    dump(os.path.join(d, "Contents.json"), {"images": images, "info": INFO})

dump(os.path.join(root, "Contents.json"), {"info": INFO})
dump(os.path.join(root, "App Icon & Top Shelf Image.brandassets", "Contents.json"), {"assets": [
    {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
], "info": INFO})
write_stack("App Icon", [("1x", (400, 240)), ("2x", (800, 480))])
write_stack("App Icon - App Store", [("1x", (1280, 768))])
topshelf("Top Shelf Image", [("1x", (1920, 720)), ("2x", (3840, 1440))])
topshelf("Top Shelf Image Wide", [("1x", (2320, 720)), ("2x", (4640, 1440))])
def color(name, rgb):
    dump(os.path.join(root, name + ".colorset", "Contents.json"), {"colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
        "red": f"{rgb[0]/255:.3f}", "green": f"{rgb[1]/255:.3f}", "blue": f"{rgb[2]/255:.3f}", "alpha": "1.000"}}}], "info": INFO})
color("AccentColor", MOON)
color("LaunchBackground", NIGHT)
print("ok")
