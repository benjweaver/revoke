#!/usr/bin/env python3
"""Measure the panel's text contrast in a screenshot.

For each rectangle, the commonest color is taken as the background and the pixel
that contrasts most with it as the text (the middle of a stroke, where antialiasing
hasn't mixed it with the background). Prints both and their WCAG 2 contrast ratio,
lowest first. A rectangle marked "ground" or "shape" reports only its commonest
color, and each "shape" is then compared with the ground named after its colon: that
is how the off switch's track is checked against the panel around it.

    Scripts/contrast.py shot.png [more.png ...]
    Scripts/contrast.py shot.png title=391,117,483,145 ground:=410,464,765,587

With no rectangles it uses RECTANGLES below, which fit a screenshot of the whole
screen at 2x from the 1024x640-point VM with the panel open and two timed grants in
the strip (Scripts/screenshots.sh). If the layout changes, look at the screenshot and
change the table: a rectangle has to hold one line of text and nothing else on one
background, so no icons, switches, or borders.

Needs only Python's standard library and macOS's sips, which turns the PNG into an
uncompressed BMP. It reads the pixel values as they are, without color management.
"""

import collections
import os
import struct
import subprocess
import sys
import tempfile

# name: (left, top, right, bottom) in pixels of the full-size screenshot.
# "ground:name" samples a background; "shape:name:ground" samples a control's fill
# and compares it with that ground.
RECTANGLES = {
    "title (Revoke)": (391, 117, 483, 145),
    "status": (500, 120, 827, 145),
    "ON FOR NOW": (391, 177, 524, 198),
    "strip title": (462, 229, 693, 259),
    "strip detail": (492, 262, 1256, 285),
    "End Now label": (1853, 244, 1954, 272),
    "group title": (918, 429, 1067, 452),
    "group note": (1078, 429, 1340, 452),
    "column title": (814, 539, 894, 561),
    "All watched apps": (447, 617, 647, 642),
    "Switches act on all 2": (447, 651, 648, 672),
    "1 of 2": (1427, 653, 1480, 672),
    "app name": (447, 709, 554, 734),
    "app caption": (447, 741, 596, 762),
    "timed pill (36m)": (1540, 741, 1610, 760),
    "OTHER APPS WITH ACCESS": (391, 904, 670, 924),
    "key text": (491, 1011, 596, 1031),
    "Revoke All Watched label": (418, 1106, 662, 1133),
    "Stop All Apps label": (727, 1106, 879, 1133),
    "Revoke capsule label": (1898, 955, 1968, 975),
    "ground:panel": (410, 464, 765, 587),
    "ground:panel low": (1000, 1075, 1900, 1150),
    "ground:watched row": (880, 660, 1380, 680),
    "ground:strip": (1300, 215, 1800, 295),
    "shape:off switch:panel": (861, 743, 876, 759),
    "shape:off switch, watched row:watched row": (861, 620, 876, 636),
    "shape:plain button:panel low": (712, 1098, 722, 1140),
    "shape:Revoke All Watched:panel low": (396, 1098, 410, 1140),
}


def luminance(rgb):
    def linear(channel):
        channel /= 255
        return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4
    return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2])


def contrast(a, b):
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def load(path):
    """The screenshot as (width, height, pixel(x, y) -> (r, g, b))."""
    with tempfile.TemporaryDirectory() as folder:
        bmp = os.path.join(folder, "shot.bmp")
        subprocess.run(["sips", "-s", "format", "bmp", path, "--out", bmp],
                       check=True, stdout=subprocess.DEVNULL)
        with open(bmp, "rb") as file:
            data = file.read()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height, _, bits = struct.unpack_from("<iiHH", data, 18)
    if bits not in (24, 32):
        sys.exit(f"{path}: {bits}-bit BMP, expected 24 or 32")
    step = bits // 8
    stride = (width * step + 3) & ~3
    bottom_up = height > 0
    height = abs(height)

    def pixel(x, y):
        row = height - 1 - y if bottom_up else y
        at = offset + row * stride + x * step
        return data[at + 2], data[at + 1], data[at]

    return width, height, pixel


def measure(pixel, box):
    """The background of the box, and the color contrasting most with it.

    Over a wallpaper the glass is never one flat color, so the background is the
    commonest of a coarse grid of colors (8 levels to a cell), averaged, rather than
    the single commonest value, which on an uneven ground can be the text.
    """
    left, top, right, bottom = box
    counts = collections.Counter(pixel(x, y) for y in range(top, bottom) for x in range(left, right))
    cells = collections.Counter()
    for color, count in counts.items():
        cells[tuple(channel >> 3 for channel in color)] += count
    cell = cells.most_common(1)[0][0]
    inside = [(color, count) for color, count in counts.items()
              if tuple(channel >> 3 for channel in color) == cell]
    total = sum(count for _, count in inside)
    background = tuple(round(sum(color[i] * count for color, count in inside) / total) for i in range(3))
    text = max(counts, key=lambda color: contrast(color, background))
    return background, text


def name_of(rgb):
    return "#%02x%02x%02x" % rgb


def report(path, rectangles):
    width, height, pixel = load(path)
    print(f"{path} ({width}x{height})")
    grounds, shapes, texts = {}, [], []
    for name, box in rectangles.items():
        if box[2] > width or box[3] > height:
            sys.exit(f"{name}: {box} is outside the screenshot")
        background, text = measure(pixel, box)
        kind, _, rest = name.partition(":")
        if kind == "ground":
            grounds[rest] = background
        elif kind == "shape":
            shapes.append((rest, background))
        else:
            texts.append((contrast(text, background), name, text, background))
    for ratio, name, text, background in sorted(texts):
        flag = "  UNDER 4.5" if ratio < 4.5 else ""
        print(f"  {ratio:5.2f}  {name:26} {name_of(text)} on {name_of(background)}{flag}")
    for name, color in grounds.items():
        print(f"         ground: {name:18} {name_of(color)}  luminance {luminance(color):.3f}")
    for name, color in shapes:
        label, _, against = name.rpartition(":")
        if against in grounds:
            ratio = contrast(color, grounds[against])
            flag = "  under 3" if ratio < 3 else ""
            print(f"  {ratio:5.2f}  {label:26} {name_of(color)} on {name_of(grounds[against])}{flag}")
        else:
            print(f"         shape: {name:19} {name_of(color)}")


def main(arguments):
    paths = [argument for argument in arguments if "=" not in argument]
    rectangles = {}
    for argument in arguments:
        if "=" in argument:
            name, _, numbers = argument.rpartition("=")
            rectangles[name] = tuple(int(number) for number in numbers.split(","))
    if not paths:
        sys.exit(__doc__)
    for path in paths:
        report(path, rectangles or RECTANGLES)


if __name__ == "__main__":
    main(sys.argv[1:])
