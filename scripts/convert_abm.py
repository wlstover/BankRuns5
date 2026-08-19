"""
convert_abm.py — Convert draft/paper_draft.md to draft/abm_chapter.tex (chapter partial).

The .md remains the canonical prose source; .tex is generated. Do not edit
abm_chapter.tex directly.

Pipeline:
    1. Run pandoc to produce raw LaTeX from the markdown.
    2. Post-process:
       - Strip manual number prefixes from \\section / \\subsection /
         \\subsubsection arguments ("1. Introduction" -> "Introduction").
       - Insert \\label{sec:abm_<name>} after each top-level non-appendix
         section per the SECTION_LABELS map.
       - Replace Unicode Greek/math characters with LaTeX equivalents.
         In body text: $\\command$ form. In verbatim blocks: ASCII spelling.
       - Strip stray \\tightlist directives that some classes don't define.
    3. Prepend the chapter header and Schuler co-author note.
    4. Write to BankRuns5/draft/abm_chapter.tex.

Run from BankRuns5/:
    python scripts/convert_abm.py
"""

import re
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
# Both live in draft/ since the 2026-08-19 reorganisation. dissertation.tex
# \input{}s the target from there, so moving one without the other silently
# breaks the dissertation build.
DRAFT_DIR = BASE / "draft"
SOURCE_MD = DRAFT_DIR / "paper_draft.md"
TARGET_TEX = DRAFT_DIR / "abm_chapter.tex"

# --- Mappings ----------------------------------------------------------------

# Body-text replacements: Unicode -> $\command$ (math mode wrapped).
UNICODE_TO_LATEX = [
    ("μ", r"$\mu$"),
    ("λ", r"$\lambda$"),
    ("σ", r"$\sigma$"),
    ("α", r"$\alpha$"),
    ("β", r"$\beta$"),
    ("γ", r"$\gamma$"),
    ("δ", r"$\delta$"),
    ("ε", r"$\epsilon$"),
    ("ζ", r"$\zeta$"),
    ("η", r"$\eta$"),
    ("θ", r"$\theta$"),
    ("ι", r"$\iota$"),
    ("κ", r"$\kappa$"),
    ("ν", r"$\nu$"),
    ("ξ", r"$\xi$"),
    ("π", r"$\pi$"),
    ("ρ", r"$\rho$"),
    ("τ", r"$\tau$"),
    ("φ", r"$\phi$"),
    ("χ", r"$\chi$"),
    ("ψ", r"$\psi$"),
    ("ω", r"$\omega$"),
    ("Φ", r"$\Phi$"),
    ("Σ", r"$\Sigma$"),
    ("Δ", r"$\Delta$"),
    ("Ω", r"$\Omega$"),
    ("Θ", r"$\Theta$"),
    ("Λ", r"$\Lambda$"),
    ("Π", r"$\Pi$"),
    ("Ψ", r"$\Psi$"),
    ("Γ", r"$\Gamma$"),
    ("Ξ", r"$\Xi$"),
    ("→", r"$\to$"),
    ("←", r"$\leftarrow$"),
    ("⇒", r"$\Rightarrow$"),
    ("⇐", r"$\Leftarrow$"),
    ("≤", r"$\le$"),
    ("≥", r"$\ge$"),
    ("≠", r"$\ne$"),
    ("≈", r"$\approx$"),
    ("±", r"$\pm$"),
    ("∓", r"$\mp$"),
    ("·", r"$\cdot$"),
    ("×", r"$\times$"),
    ("÷", r"$\div$"),
    ("∈", r"$\in$"),
    ("∉", r"$\notin$"),
    ("⊆", r"$\subseteq$"),
    ("⊂", r"$\subset$"),
    ("∞", r"$\infty$"),
    ("∂", r"$\partial$"),
    ("∇", r"$\nabla$"),
    ("∑", r"$\sum$"),
    ("∏", r"$\prod$"),
    ("∫", r"$\int$"),
    ("√", r"$\sqrt{}$"),
    ("−", r"$-$"),
    # Subscript / superscript digits — handled as literal substitutions
    # because they always appear in <letter><digit> form (e.g., r₁ → $r_1$).
    # If new patterns appear, add them here.
    ("r₁", r"$r_1$"),
    ("r₂", r"$r_2$"),
    ("t₁", r"$t_1$"),
    ("t₂", r"$t_2$"),
    ("t₃", r"$t_3$"),
]

# Verbatim-block replacements: Unicode -> plain-ASCII spelling. LaTeX math
# mode is unavailable inside verbatim, so we transliterate.
UNICODE_TO_ASCII = [
    ("μ", "mu"),
    ("λ", "lambda"),
    ("σ", "sigma"),
    ("α", "alpha"),
    ("β", "beta"),
    ("γ", "gamma"),
    ("δ", "delta"),
    ("ε", "epsilon"),
    ("ζ", "zeta"),
    ("η", "eta"),
    ("θ", "theta"),
    ("ι", "iota"),
    ("κ", "kappa"),
    ("ν", "nu"),
    ("ξ", "xi"),
    ("π", "pi"),
    ("ρ", "rho"),
    ("τ", "tau"),
    ("φ", "phi"),
    ("χ", "chi"),
    ("ψ", "psi"),
    ("ω", "omega"),
    ("Φ", "Phi"),
    ("Σ", "Sigma"),
    ("Δ", "Delta"),
    ("Ω", "Omega"),
    ("Θ", "Theta"),
    ("Λ", "Lambda"),
    ("Π", "Pi"),
    ("Ψ", "Psi"),
    ("Γ", "Gamma"),
    ("Ξ", "Xi"),
    ("→", "->"),
    ("←", "<-"),
    ("⇒", "=>"),
    ("⇐", "<="),
    ("≤", "<="),
    ("≥", ">="),
    ("≠", "!="),
    ("≈", "~="),
    ("±", "+/-"),
    ("∓", "-/+"),
    ("·", "*"),
    ("×", "x"),
    ("÷", "/"),
    ("∈", " in "),
    ("∉", " not in "),
    ("∞", "inf"),
    ("∂", "d"),
    ("−", "-"),
    ("₁", "_1"),
    ("₂", "_2"),
    ("₃", "_3"),
]

# Top-level sections that get a \label{sec:abm_<name>} inserted on the
# line below the \section{} call. Title must match exactly after number-
# prefix strip. Sections not in this map (e.g. "Appendix A: ...") get no label.
SECTION_LABELS = {
    "Introduction": "abm_intro",
    "The Diamond-Dybvig Model and Its Limitations": "abm_dd",
    "The Replacement Model": "abm_replacement",
    "Cultural Heterogeneity: Individualism and Collectivism": "abm_culture",
    "Simulation Design": "abm_design",
    "Simulation Results": "abm_results",
    "Conclusion": "abm_conclusion",
}

HEADER = r"""% ============================================================================
% CHAPTER 3 PARTIAL --- generated from BankRuns5/draft/paper_draft.md via pandoc
% then post-processed. Do not edit the .md and the .tex independently; the
% .md remains the canonical prose source. To regenerate this file:
%   python scripts/convert_abm.py
% Title and byline live in the dissertation wrapper.
% ============================================================================

\chapter{Virtualizing a Run: An Agent-Based Model of Bank Runs with Cultural Heterogeneity}
\label{ch:abm}

\noindent\textit{This chapter is co-authored with John S.\ Schuler (George Mason University, Computational and Data Sciences). The base ABM framework and Diamond-Dybvig critique are Schuler's contribution; the cultural heterogeneity extension and integration with the empirical results of Chapter~\ref{ch:celsius} are joint work.}

"""

# --- Regex patterns ----------------------------------------------------------

NUM_PREFIX = re.compile(r"^(?:[A-Z]?\d+(?:\.\d+)*)\.?\s+")

# pandoc-with-top-level-division=section produces:
#   H1 -> \section (paper title; we strip this and replace with \chapter)
#   H2 -> \subsection (becomes our \section after demotion)
#   H3 -> \subsubsection (becomes our \subsection)
#   H4 -> \paragraph (kept as \paragraph, matches existing convention)
# Numbered first content section identifies the start of real content;
# everything before it (paper title, byline, abstract) is dropped.
FIRST_CONTENT = re.compile(r"^\\subsection\{\d")

# pandoc appends \label{<slug>} to each section command, often on the same
# line. We strip these because we insert curated sec:abm_* labels instead.
PANDOC_AUTOLABEL = re.compile(
    r"(\\(?:section|subsection|subsubsection|paragraph)\{[^}]*\})"
    r"\s*\\label\{[^}]*\}"
)

# Match a section command sitting alone on a line (post auto-label strip).
SECTION_LINE = re.compile(
    r"^(\\(?:section|subsection|subsubsection|paragraph))\{([^}]*)\}\s*$"
)

VERBATIM_BEGIN = re.compile(r"\\begin\{verbatim\}")
VERBATIM_END = re.compile(r"\\end\{verbatim\}")
TIGHTLIST = re.compile(r"^\s*\\tightlist\s*$")

# Pandoc emits markdown `λ_C` as Unicode-λ followed by an escaped underscore
# (`λ\_C`). After UNICODE_TO_LATEX rewrites the lambda, we get `$\lambda$\_C` —
# the `\_` lands outside math mode, which renders as a literal underscore in
# body text but breaks the .lof file when the same string appears in a figure
# caption. Repair: pull the subscript inside the math span. Multi-character
# subscripts get braced so they don't render as `\lambda_L N`.
PANDOC_SUBSCRIPT = re.compile(r"\$\\([a-zA-Z]+)\$\\_([A-Za-z0-9]+)")


def fix_pandoc_subscripts(text):
    def _fix(m):
        greek, sub = m.group(1), m.group(2)
        if len(sub) == 1:
            return rf"$\{greek}_{sub}$"
        return rf"$\{greek}_{{{sub}}}$"
    return PANDOC_SUBSCRIPT.sub(_fix, text)


def replace_unicode(text, mapping):
    for src, dst in mapping:
        text = text.replace(src, dst)
    return text


def strip_section_number(arg):
    return NUM_PREFIX.sub("", arg).strip()


def transform(raw):
    # Collapse multi-line section commands (pandoc wraps long titles
    # across newlines) so downstream line-by-line matching works.
    raw = re.sub(
        r"(\\(?:section|subsection|subsubsection|paragraph))\{([^{}]*?)\}",
        lambda m: m.group(1) + "{" + re.sub(r"\s+", " ", m.group(2)).strip() + "}",
        raw,
        flags=re.DOTALL,
    )

    lines = raw.splitlines()

    # Skip pandoc preamble: paper title, byline, abstract — everything
    # before the first numbered subsection (first H2 with a "1. ..." prefix).
    start = 0
    for i, line in enumerate(lines):
        if FIRST_CONTENT.match(line):
            start = i
            break
    lines = lines[start:]

    out_lines = []
    in_verbatim = False

    for line in lines:
        if VERBATIM_BEGIN.search(line):
            in_verbatim = True
            out_lines.append(line)
            continue
        if VERBATIM_END.search(line):
            in_verbatim = False
            out_lines.append(line)
            continue

        if in_verbatim:
            out_lines.append(replace_unicode(line, UNICODE_TO_ASCII))
            continue

        if TIGHTLIST.match(line):
            continue

        # Strip pandoc auto-label that follows section commands inline.
        line = PANDOC_AUTOLABEL.sub(r"\1", line)

        # Demote sections by one level (H2->section, H3->subsection)
        # via a single-pass regex so we don't re-match our own output.
        # \paragraph stays as-is (matches existing convention for H4).
        def _demote(m):
            cmd = m.group(1)
            if cmd == "subsubsection":
                return r"\subsection{"
            if cmd == "subsection":
                return r"\section{"
            return m.group(0)
        line = re.sub(r"^\\(subsubsection|subsection)\{", _demote, line)

        # If the resulting line is a section command alone, strip its
        # number prefix and (for top-level \section) add a curated label.
        m = SECTION_LINE.match(line)
        if m:
            cmd, raw_title = m.group(1), m.group(2)
            title = strip_section_number(raw_title)
            new_line = f"{cmd}{{{title}}}"
            new_line = fix_pandoc_subscripts(replace_unicode(new_line, UNICODE_TO_LATEX))
            out_lines.append(new_line)
            if cmd == r"\section" and title in SECTION_LABELS:
                out_lines.append(rf"\label{{sec:{SECTION_LABELS[title]}}}")
            continue

        out_lines.append(fix_pandoc_subscripts(replace_unicode(line, UNICODE_TO_LATEX)))

    return "\n".join(out_lines) + "\n"


def main():
    if not SOURCE_MD.exists():
        sys.exit(f"ERROR: source not found: {SOURCE_MD}")

    print(f"pandoc < {SOURCE_MD.name}")
    proc = subprocess.run(
        ["pandoc", "-f", "markdown", "-t", "latex",
         "--top-level-division=section", str(SOURCE_MD)],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        sys.exit(f"pandoc failed (exit {proc.returncode})")

    transformed = transform(proc.stdout)
    final = HEADER + transformed
    TARGET_TEX.write_text(final)

    n_lines = len(final.splitlines())
    n_unicode = sum(1 for c in final if ord(c) > 127)
    print(f"wrote {TARGET_TEX.relative_to(BASE)} ({n_lines} lines, "
          f"{n_unicode} non-ASCII chars remaining)")


if __name__ == "__main__":
    main()
