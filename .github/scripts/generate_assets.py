"""Generate SplitNest launcher icons and the app logo asset in CI.

The GitHub snapshot push route handles text files only, so the binary
launcher-icon PNGs and the logo WebP cannot be pushed to the repo.
This script regenerates them from the project's v3 logo file before
`flutter build apk` runs, so the Android build never fails on missing
icons the way the mad_riphahcup run did.

Logo v3 (user decision 2026-11-05): deep teal nest + house roof +
three gold coins, premium fintech style, on a white background.
Source: <repo>/assets/media-generation-splitnest-logo-v3-professional-0-07c220fc-9397-41dc-99e3-6be81f631500.webp
(1600x1600). The white corner background is flood-filled to
transparent (same treatment the v2 asset got), so the mark sits
cleanly on any screen colour.

If the v3 file is missing or PIL cannot open it (e.g. no WebP
support in CI), the script falls back to the drawn navy design
below and prints a clear warning — the build still gets icons.
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MOBILE = os.path.join(ROOT, "mobile")
V3_NAME = ("media-generation-splitnest-logo-v3-professional-"
           "0-07c220fc-9397-41dc-99e3-6be81f631500.webp")
V3_PATH = os.path.join(ROOT, "assets", V3_NAME)

NAVY = (29, 45, 68, 255)
GOLD = (232, 185, 60, 255)
WHITE = (255, 255, 255, 255)
# Deep teal-green (light-theme primary) — maskable-icon background.
TEAL_GREEN = (18, 60, 56, 255)


def draw_logo(draw, size):
    """Fallback: draw the nest + three coins logo into a size x size box."""
    # Navy rounded-square background.
    draw.rounded_rectangle([0, 0, size - 1, size - 1],
                           radius=int(size * 0.22), fill=NAVY)
    # White nest: three overlapping ellipse outlines.
    w = max(2, int(size * 0.045))
    cx, cy = size / 2, size / 2
    for dx, dy, rx, ry in ((-0.06, -0.02, 0.34, 0.24),
                           (0.05, 0.03, 0.34, 0.24),
                           (0.0, 0.08, 0.36, 0.22)):
        draw.ellipse([cx + dx * size - rx * size, cy + dy * size - ry * size,
                      cx + dx * size + rx * size, cy + dy * size + ry * size],
                     outline=WHITE, width=w)
    # Three gold coins in a row.
    r = size * 0.085
    for i, fx in enumerate((-0.20, 0.0, 0.20)):
        x = cx + fx * size
        y = cy + size * 0.02
        draw.ellipse([x - r, y - r, x + r, y + r], fill=GOLD)
        draw.arc([x - r * 0.55, y - r * 0.55, x + r * 0.55, y + r * 0.55],
                 start=200, end=320, fill=NAVY, width=max(2, int(size * 0.02)))


def drawn_logo(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_logo(ImageDraw.Draw(img), size)
    return img


def load_v3():
    """Load the v3 logo with white corners flood-filled to transparent.

    Returns an RGBA image, or None if the file is missing/unreadable.
    """
    try:
        img = Image.open(V3_PATH).convert("RGBA")
    except Exception as exc:  # missing file, no WebP support, corrupt file
        print(f"WARNING: could not load v3 logo ({V3_PATH}): {exc}")
        return None
    # Flood-fill the near-white corner background to transparent.
    # The four corners are connected through the white border, so one
    # fill from (0, 0) clears them all; thresh tolerates slight noise.
    ImageDraw.floodfill(img, (0, 0), (0, 0, 0, 0), thresh=12)
    return img


def save_logo(path, size, fmt, base=None):
    if base is None:
        img = drawn_logo(size)
    else:
        img = base.resize((size, size), Image.LANCZOS)
    img.save(path, fmt)
    print(f"wrote {path} ({size}x{size} {fmt})")


def save_maskable(path, size, base):
    """Maskable web icon: the mark centred on a full-bleed teal-green
    square (maskable icons are cropped to a circle by the OS, so the
    mark sits at 80% with a safe margin)."""
    canvas = Image.new("RGBA", (size, size), TEAL_GREEN)
    mark = base.resize((int(size * 0.8), int(size * 0.8)), Image.LANCZOS)
    canvas.alpha_composite(mark, ((size - mark.width) // 2,
                                  (size - mark.height) // 2))
    canvas.save(path, "PNG")
    print(f"wrote {path} ({size}x{size} PNG, maskable)")


def main():
    base = load_v3()
    if base is None:
        print("WARNING: falling back to the drawn navy logo design; "
              "launcher icons will NOT match the v3 mark.")
    else:
        print(f"loaded v3 logo {V3_PATH} ({base.size[0]}x{base.size[1]})")

    # App logo asset referenced by pubspec.yaml (splash / login / home).
    os.makedirs(os.path.join(MOBILE, "assets"), exist_ok=True)
    save_logo(os.path.join(MOBILE, "assets", "splitnest-logo-v3.webp"),
              1024, "WEBP", base)

    # Legacy launcher icons (referenced by AndroidManifest @mipmap/ic_launcher).
    res = os.path.join(MOBILE, "android", "app", "src", "main", "res")
    for d, size in (("mipmap-mdpi", 48), ("mipmap-hdpi", 72),
                    ("mipmap-xhdpi", 96), ("mipmap-xxhdpi", 144),
                    ("mipmap-xxxhdpi", 192)):
        os.makedirs(os.path.join(res, d), exist_ok=True)
        save_logo(os.path.join(res, d, "ic_launcher.png"), size, "PNG", base)

    # Adaptive-icon foreground (referenced by mipmap-anydpi-v26 ic_launcher.xml).
    os.makedirs(os.path.join(res, "drawable"), exist_ok=True)
    save_logo(os.path.join(res, "drawable", "ic_launcher_foreground.png"),
              432, "PNG", base)

    # Web icons + favicon.
    web_icons = os.path.join(MOBILE, "web", "icons")
    os.makedirs(web_icons, exist_ok=True)
    save_logo(os.path.join(web_icons, "Icon-192.png"), 192, "PNG", base)
    save_logo(os.path.join(web_icons, "Icon-512.png"), 512, "PNG", base)
    if base is not None:
        save_maskable(os.path.join(web_icons, "Icon-maskable-192.png"),
                      192, base)
        save_maskable(os.path.join(web_icons, "Icon-maskable-512.png"),
                      512, base)
    save_logo(os.path.join(MOBILE, "web", "favicon.png"), 64, "PNG", base)


if __name__ == "__main__":
    main()
