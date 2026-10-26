#!/usr/bin/env python3
"""Stopgap (2026-10-26): recolour individualists from orange (#eb6834, figstyle
INDIV) to red in the seminar exhibit that draws the two types, by shifting the
orange hue in the PNG. Rerun fig_deck.py --lay on the HPC with the new colour
and delete this. Usage: python3 scripts/recolour_individualists.py [RRGGBB]
"""
import sys
from pathlib import Path
import numpy as np
from PIL import Image

RED = sys.argv[1] if len(sys.argv) > 1 else "D62828"
root = Path(__file__).resolve().parent.parent / "figures" / "deck_lay"
tr, tg, tb = (int(RED[i:i + 2], 16) for i in (0, 2, 4))
for name in ["e07_herding.png"]:
    p = root / name
    im = Image.open(p).convert("RGB"); a = np.asarray(im).astype(float)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    # orange ink: red well above blue, green between them (anti-aliased blends included)
    mask = (r > b + 40) & (g > b + 5) & (g < r - 10)
    # how much ink vs white: 1 at the pure colour, 0 at white (blue channel 52 at full ink)
    ink = np.clip((255 - b) / (255 - 0x34), 0, 1)[mask]
    out = a.copy()
    out[mask, 0] = 255 - ink * (255 - tr)
    out[mask, 1] = 255 - ink * (255 - tg)
    out[mask, 2] = 255 - ink * (255 - tb)
    Image.fromarray(out.round().astype(np.uint8)).save(p)
    print(name, "recoloured pixels:", int(mask.sum()))
