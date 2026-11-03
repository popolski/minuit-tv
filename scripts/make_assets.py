import json, os, sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

root = sys.argv[1]
os.makedirs(root, exist_ok=True)
INFO = {"author": "xcode", "version": 1}
def dump(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(obj, open(path, "w"), indent=2)

NIGHT = (7, 11, 22); RAISED = (14, 26, 52); MOON = (143, 184, 255); EMBER = (255, 138, 91)

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
    # horizon discret
    d = ImageDraw.Draw(img)
    d.line([(0, int(h * 0.80)), (w, int(h * 0.80))], fill=(40, 58, 100), width=max(1, h // 240))
    return img

def front(w, h, text=False):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    s = 4  # supersampling
    big = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    r = int(h * s * 0.30); cx, cy = int(w * s * 0.5), int(h * s * 0.46)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=MOON + (255,))
    off = int(r * 0.52)
    d.ellipse([cx - r + off, cy - r - int(r * 0.18), cx + r + off, cy + r - int(r * 0.18)], fill=(0, 0, 0, 0))
    er = int(h * s * 0.045)
    ex, ey = cx + int(r * 0.95), cy + int(r * 0.78)
    d.ellipse([ex - er, ey - er, ex + er, ey + er], fill=EMBER + (255,))
    img = big.resize((w, h), Image.LANCZOS)
    return img

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
            ImageDraw.Draw(img).text((int(w * 0.08 + h * 1.12), int(h * 0.36)), "Minuit", font=font, fill=(238, 242, 250, 255))
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
