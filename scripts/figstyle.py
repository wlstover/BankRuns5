"""Shared figure style for the Ch 3 figures (2026-10-22).

Fira Sans (the dissertation's UDTS Accessible template font), recessive axes,
and one colour scheme across the chapter: individualists orange, collectivists
blue (as in fig5_network_snapshot), everything else in ink greys, so orange and
blue always mean the two types. Palette validated with the dataviz skill's
validate_palette.js (light mode: CVD dE 24.7, normal-vision dE 33.6).
"""

from pathlib import Path

import matplotlib as mpl
import matplotlib.font_manager as fm

INDIV = "#eb6834"      # individualists (type I)
COLLECT = "#2a78d6"    # collectivists (type C)
INK = "#0b0b0b"
INK2 = "#52514e"       # secondary text
INK3 = "#8a8985"       # muted
GRID = "#e4e3df"
BAND = "#f0efec"       # shaded regions
SURFACE = "#ffffff"
# Ordinal ink ramp for the three lambda pairs: widest gap darkest.
LAMBDA_PAIRS = [(0.1, 0.9), (0.2, 0.8), (0.3, 0.5)]
LAMBDA_INK = {(0.1, 0.9): "#1f1f1d", (0.2, 0.8): "#6b6a66", (0.3, 0.5): "#a9a8a3"}
LAMBDA_MARK = {(0.1, 0.9): "o", (0.2, 0.8): "s", (0.3, 0.5): "^"}

_FIRA = Path("/usr/share/texlive/texmf-dist/fonts/opentype/public/fira")


def use():
    family = "DejaVu Sans"
    if _FIRA.exists():
        for f in ("FiraSans-Regular.otf", "FiraSans-Medium.otf", "FiraSans-Italic.otf"):
            if (_FIRA / f).exists():
                fm.fontManager.addfont(str(_FIRA / f))
        family = "Fira Sans"
    mpl.rcParams.update({
        "font.family": family, "font.size": 10,
        "axes.edgecolor": INK3, "axes.linewidth": 0.8, "axes.labelcolor": INK,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
        "xtick.color": INK2, "ytick.color": INK2, "text.color": INK,
        "legend.frameon": False, "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
        "lines.linewidth": 2.0, "lines.markersize": 5,
        "savefig.dpi": 200, "savefig.bbox": "tight",
        "mathtext.fontset": "custom", "mathtext.rm": family, "mathtext.it": f"{family}:italic",
        "mathtext.bf": f"{family}:medium", "mathtext.sf": family,
    })
