"""Generate SplitNest launcher icons and the app logo asset in CI.

The GitHub snapshot push route handles text files only, so the binary
launcher-icon PNGs and the logo WebP cannot be pushed to the repo.
This script regenerates them from the project's own logo design
(navy #1D2D44 rounded square, white nest, three gold coins) before
`flutter build apk` runs, so the Android build never fails on missing
icons the way the mad_riphahcup run did.
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MOBILE = os.path.join(ROOT, "mobile")
NAVY = (29, 45, 68, 255)
GOLD = (232, 185, 60, 255)
WHITE = (255, 255, 255, 255)


def draw_logo(draw, size):
    """Draw the nest + three coins logo into a size x size box."""
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


def save_logo(path, size, fmt):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_logo(ImageDraw.Draw(img), size)
    img.save(path, fmt)
    print(f"wrote {path} ({size}x{size} {fmt})")


def main():
    # App logo asset referenced by pubspec.yaml (splash / login / home).
    os.makedirs(os.path.join(MOBILE, "assets"), exist_ok=True)
    save_logo(os.path.join(MOBILE, "assets", "splitnest-logo.webp"), 1024, "WEBP")

    # Legacy launcher icons (referenced by AndroidManifest @mipmap/ic_launcher).
    res = os.path.join(MOBILE, "android", "app", "src", "main", "res")
    for d, size in (("mipmap-mdpi", 48), ("mipmap-hdpi", 72),
                    ("mipmap-xhdpi", 96), ("mipmap-xxhdpi", 144),
                    ("mipmap-xxxhdpi", 192)):
        os.makedirs(os.path.join(res, d), exist_ok=True)
        save_logo(os.path.join(res, d, "ic_launcher.png"), size, "PNG")

    # Adaptive-icon foreground (referenced by mipmap-anydpi-v26 ic_launcher.xml).
    os.makedirs(os.path.join(res, "drawable"), exist_ok=True)
    save_logo(os.path.join(res, "drawable", "ic_launcher_foreground.png"),
              432, "PNG")


if __name__ == "__main__":
    main()
