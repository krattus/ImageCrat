#!/usr/bin/env python3
"""Generates Resources/ImageCratDocument.icns, the Finder icon for .imagecrat documents.

Usage: make_document_icon.py <master.png> <out.icns>
Draws a classic macOS document page (folded top-right corner, hairline outline, soft drop shadow) with the
app icon master as the emblem, at every .icns size, then packs them with `iconutil -c icns`.
scripts/build_app.sh copies the resulting .icns into the app bundle (only regenerate when the app icon changes).
Needs Python 3 + Pillow; macOS for iconutil.
"""
import math, os, shutil, subprocess, sys, tempfile
from PIL import Image, ImageChops, ImageDraw, ImageFilter

# iconset file name -> pixel size
ICONSET = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
           ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
           ("icon_512x512", 512), ("icon_512x512@2x", 1024)]


def lerp(a, b, t):
    return a + (b - a) * max(0.0, min(1.0, t))


def params(size):
    """Per-size geometry in target pixels. Small sizes get a bolder outline and a relatively larger emblem."""
    t = (math.log2(size) - 4) / 4          # 0 at 16 px, 1 at 256 px and above
    w = round(size * 0.70)                 # page width
    h = round(size * 0.885)                # page height (about US-letter proportions)
    left = (size - w) // 2
    top = max(1, round(size * 0.035))
    return dict(
        left=left, top=top, right=left + w, bottom=top + h, w=w, h=h,
        fold=max(3, round(w * lerp(0.26, 0.24, t))),
        radius=max(0.6, size * 0.012),
        outline=max(1.0, size / 512),
        outline_rgba=(int(lerp(150, 196, t)), int(lerp(150, 196, t)), int(lerp(150, 196, t)), 255),
        emblem=lerp(0.80, 0.56, t),        # fraction of page width
        emblem_cy=lerp(0.585, 0.58, t),    # emblem centre, fraction of page height from the top
        shadow=size >= 32,
    )


def page_mask(ss, p, inset=0.0):
    """Antialias-free mask (drawn supersampled) of the page outline shape, optionally inset by `inset` target px."""
    m = Image.new("L", (ss * p["size"],) * 2, 0)
    d = ImageDraw.Draw(m)
    L, T, R, B = (p["left"] + inset) * ss, (p["top"] + inset) * ss, (p["right"] - inset) * ss, (p["bottom"] - inset) * ss
    f = (p["fold"] - inset * (2 - math.sqrt(2))) * ss
    r = max(0.0, p["radius"] - inset) * ss
    d.rounded_rectangle([L, T, R - 1, B - 1], radius=r, fill=255)
    d.polygon([(R - f, T - 1), (R + 1, T - 1), (R + 1, T + f)], fill=0)    # cut the dog-ear corner off
    return m


def flap_mask(ss, p, inset=0.0):
    """The folded-over triangle sitting on the page, rounded at its lower-left corner."""
    m = Image.new("L", (ss * p["size"],) * 2, 0)
    d = ImageDraw.Draw(m)
    R, T, f = p["right"] * ss, p["top"] * ss, p["fold"] * ss
    i = inset * ss
    x0, y1 = R - f + i, T + f - i                      # vertical and horizontal edges of the flap
    k = i * math.sqrt(2)                               # pull the diagonal in so the inset is even
    r = max(0.0, p["fold"] * 0.16 - inset) * ss
    pts = [(x0, T + i + k), (x0, y1 - r)]
    for a in range(180, 89, -10):                      # rounded corner at (x0, y1)
        th = math.radians(a)
        pts.append((x0 + r + r * math.cos(th), y1 - r + r * math.sin(th)))
    pts.append((R - i - k, y1))
    d.polygon(pts, fill=255)
    return m


def solid(size, rgba):
    return Image.new("RGBA", (size, size), rgba)


def vgradient(size, top_rgb, bottom_rgb, y0, y1):
    g = Image.new("L", (1, 256))
    g.putdata(range(256))
    g = g.resize((size, max(1, int(y1 - y0))), Image.BILINEAR)
    full = Image.new("L", (size, size), 0)
    full.paste(g, (0, int(y0)))
    if y1 < size:
        full.paste(255, (0, int(y1), size, size))
    return Image.composite(solid(size, bottom_rgb + (255,)), solid(size, top_rgb + (255,)), full)


def render(master, size):
    p = params(size)
    p["size"] = size
    ss = max(2, min(8, 2048 // size))
    S = size * ss
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    outer = page_mask(ss, p)
    inner = page_mask(ss, p, inset=p["outline"])

    # soft drop shadow + tighter contact shadow under the page
    if p["shadow"]:
        for blur, dy, alpha in ((size * 0.014, size * 0.010, 0.30), (size * 0.003, size * 0.003, 0.22)):
            a = outer.filter(ImageFilter.GaussianBlur(blur * ss)).point(lambda v, k=alpha: int(v * k))
            sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
            sh.paste((0, 0, 0, 255), (0, round(dy * ss)), a)
            canvas = Image.alpha_composite(canvas, sh)
    else:  # 16 px: a single faint pixel row below the page is enough
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        sh.paste((0, 0, 0, 255), (0, ss), outer.point(lambda v: int(v * 0.18)))
        canvas = Image.alpha_composite(canvas, sh)

    # page: hairline outline, white paper with a whisper of a gradient
    page = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    page.paste(p["outline_rgba"], (0, 0), outer)
    paper = vgradient(S, (255, 255, 255), (246, 246, 248), p["top"] * ss, p["bottom"] * ss)
    page.paste(paper, (0, 0), inner)
    canvas = Image.alpha_composite(canvas, page)

    # shadow the flap casts onto the page (down-left of the fold), clipped to the paper
    if size >= 32:
        fm = flap_mask(ss, p)
        off = p["fold"] * 0.09 * ss
        fs = Image.new("L", (S, S), 0)
        fs.paste(fm, (-round(off), round(off)))
        fs = fs.filter(ImageFilter.GaussianBlur(max(1.0, p["fold"] * 0.09 * ss)))
        fs = ImageChops.multiply(fs, inner).point(lambda v: int(v * 0.38))
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        sh.paste((0, 0, 0, 255), (0, 0), fs)
        canvas = Image.alpha_composite(canvas, sh)

    # the folded flap: outline + light-grey fill, darker toward the crease
    flap = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    flap.paste(p["outline_rgba"], (0, 0), flap_mask(ss, p))
    R, T, f = p["right"] * ss, p["top"] * ss, p["fold"] * ss
    n = round(f)
    g = Image.new("L", (n, n))                          # 0 along the crease -> 255 at the flap's tip
    g.putdata([max(0, min(255, int(255 * (y - x) / n))) for y in range(n) for x in range(n)])
    fill_dark, fill_light = (212, 212, 217), (240, 240, 243)
    grad = Image.composite(solid(n, fill_light + (255,)), solid(n, fill_dark + (255,)), g)
    fill = Image.new("RGBA", (S, S), fill_light + (255,))
    fill.paste(grad, (round(R - f), round(T)))
    flap.paste(fill, (0, 0), flap_mask(ss, p, inset=p["outline"]))
    canvas = Image.alpha_composite(canvas, flap)

    # supersampled canvas -> target size (resize premultiplies RGBA, so no dark fringes)
    out = canvas.resize((size, size), Image.BOX)

    # emblem: resampled straight from the master to its final pixel size for maximum crispness
    e = max(6, round(p["w"] * p["emblem"]))
    if (p["w"] - e) % 2:
        e += 1
    ex = p["left"] + (p["w"] - e) // 2
    ey = round(p["top"] + p["h"] * p["emblem_cy"] - e / 2)
    ey = min(ey, p["bottom"] - e - max(1, round(size * 0.04)))
    em = master.resize((e, e), Image.LANCZOS)
    if size >= 64:
        a = Image.new("L", (size, size), 0)
        a.paste(em.getchannel("A"), (ex, ey + max(1, round(size * 0.006))))
        a = a.filter(ImageFilter.GaussianBlur(size * 0.008)).point(lambda v: int(v * 0.28))
        sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        sh.paste((20, 0, 40, 255), (0, 0), a)
        out = Image.alpha_composite(out, sh)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    layer.paste(em, (ex, ey))
    return Image.alpha_composite(out, layer)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: make_document_icon.py <master.png> <out.icns>")
    master = Image.open(sys.argv[1]).convert("RGBA")
    bbox = master.getchannel("A").getbbox()      # drop the transparent margin around the rounded square
    if bbox:
        master = master.crop(bbox)
    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "ImageCratDocument.iconset")
    os.makedirs(iconset)
    try:
        cache = {}
        for name, px in ICONSET:
            if px not in cache:
                cache[px] = render(master, px)
            cache[px].save(os.path.join(iconset, name + ".png"))
        out = os.path.abspath(sys.argv[2])
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
