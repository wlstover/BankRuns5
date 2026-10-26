#!/usr/bin/env python3
"""Stopgap (2026-10-26): relabel the 'Difference between types' legend in the
seminar exhibits as Large (λ 0.1, 0.9) / Medium (λ 0.2, 0.8) / Small (λ 0.3, 0.5)
by painting over the PNGs in figures/deck_lay/. fig_deck.py now writes these
labels itself (SIZE), but the run outputs are on the HPC, not here; rerun
`python3 scripts/fig_deck.py --lay` there and this script becomes unnecessary.
Fira Sans from TeX Live, as in figstyle.py. The canvas is widened on the right
where the longer labels need it.
"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

FIRA = "/usr/share/texlive/texmf-dist/fonts/opentype/public/fira/FiraSans-Regular.otf"
NEW = ["Large (λ 0.1, 0.9)", "Medium (λ 0.2, 0.8)", "Small (λ 0.3, 0.5)"]
# file -> (x0, x1, y0, y1) of the legend-label block (labels only, right of the markers)
JOBS = {
    "e08_pfail_by_signal.png": (1165, 1360, 420, 530),
    "e05_pfail_by_mu.png": (870, 1059, 70, 175),
    "e01_sorting.png": (990, 1199, 500, 605),
}
root = Path(__file__).resolve().parent.parent / "figures" / "deck_lay"
for name, (x0, x1, y0, y1) in JOBS.items():
    p = root / name
    im = Image.open(p).convert("RGB"); a = np.asarray(im)
    sub = a[y0:y1, x0:x1]; dark = sub.sum(axis=2) < 500
    lines, start = [], None
    for r in range(dark.shape[0]):
        if dark[r].any() and start is None: start = r
        if not dark[r].any() and start is not None: lines.append((start + y0, r - 1 + y0)); start = None
    assert len(lines) == 3, (name, lines)
    cols = np.where(dark.any(axis=0))[0]; left = cols.min() + x0
    # width of "Medium" (line 2) sets the font size
    r2 = dark[lines[1][0] - y0: lines[1][1] - y0 + 1]; c2 = np.where(r2.any(axis=0))[0]
    target = c2.max() - c2.min() + 1
    size = max(range(10, 40), key=lambda s: -abs(ImageFont.truetype(FIRA, s).getlength("Medium") - target))
    font = ImageFont.truetype(FIRA, size)
    color = tuple(int(v) for v in sub.reshape(-1, 3)[sub.reshape(-1, 3).sum(axis=1).argmin()])   # the darkest ink
    need = left + max(font.getlength(t) for t in NEW) + 16
    if need > im.width:
        wide = Image.new("RGB", (int(need), im.height), "white"); wide.paste(im, (0, 0)); im = wide
    d = ImageDraw.Draw(im)
    d.rectangle([left - 2, y0, im.width, y1], fill="white")
    for (top, bot), text in zip(lines, NEW):
        # baseline: the first line has no descender in 'L' -> use cap top; align by top of caps
        d.text((left, top), text, font=font, fill=color, anchor="lt")
    im.save(p)
    print(name, "font", size, "width", im.width, "lines", lines)
