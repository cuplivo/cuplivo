#!/usr/bin/env python3
"""Build assets/fonts/CuplivoSymbolFallback-Regular.ttf

Last-resort subset covering cold glyphs that system UI fonts often miss:
  - Superscripts and Subscripts (U+2070-209F), e.g. U+208C ₌
  - Vedic Extensions (U+1CD0-1CFF), e.g. U+1CD0 ᳐

Sources (SIL OFL 1.1): Noto Sans, Noto Sans Devanagari.

Usage:
  python3 -m venv .venv-font && .venv-font/bin/pip install fonttools
  # Place full source TTFs under /tmp/cuplivo-font-src/ (or pass --src-dir):
  #   NotoSans-Regular.ttf
  #   NotoSansDevanagari-Regular.ttf
  .venv-font/bin/python tool/build_symbol_fallback_font.py
"""

from __future__ import annotations

import argparse
from pathlib import Path

from fontTools import subset
from fontTools.merge import Merger
from fontTools.ttLib import TTFont

FAMILY = "CuplivoSymbolFallback"
REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = REPO_ROOT / "assets" / "fonts" / "CuplivoSymbolFallback-Regular.ttf"

SUPER_SUB = list(range(0x2070, 0x209F + 1))
VEDIC = list(range(0x1CD0, 0x1CFF + 1))
REQUIRED = (0x208C, 0x1CD0)


def subset_font(src: Path, unicodes: list[int], dest: Path) -> None:
    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.recalc_bounds = True
    options.recalc_timestamp = False
    options.ignore_missing_unicodes = True
    font = subset.load_font(str(src), options)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=unicodes)
    subsetter.subset(font)
    subset.save_font(font, str(dest), options)


def rename_family(font: TTFont) -> None:
    name_table = font["name"]
    keep_ids = {0, 5, 7, 8, 9, 11, 13, 14}
    name_table.names = [rec for rec in name_table.names if rec.nameID in keep_ids]
    name_map = {
        1: FAMILY,
        2: "Regular",
        4: f"{FAMILY} Regular",
        6: "CuplivoSymbolFallback-Regular",
        16: FAMILY,
        17: "Regular",
    }
    for nid, val in name_map.items():
        name_table.setName(val, nid, 3, 1, 0x409)
        name_table.setName(val, nid, 1, 0, 0)
    name_table.setName(
        "Derived from Noto Sans and Noto Sans Devanagari (SIL Open Font License 1.1). "
        "Subset for Cuplivo symbol fallback only.",
        0,
        3,
        1,
        0x409,
    )
    name_table.setName(
        "This Font Software is licensed under the SIL Open Font License, Version 1.1.",
        13,
        3,
        1,
        0x409,
    )
    name_table.setName("https://scripts.sil.org/OFL", 14, 3, 1, 0x409)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--src-dir",
        type=Path,
        default=Path("/tmp/cuplivo-font-src"),
        help="Directory containing full Noto source TTFs",
    )
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    noto_sans = args.src_dir / "NotoSans-Regular.ttf"
    noto_deva = args.src_dir / "NotoSansDevanagari-Regular.ttf"
    if not noto_sans.is_file() or not noto_deva.is_file():
        raise SystemExit(
            f"Missing sources in {args.src_dir}. Need "
            "NotoSans-Regular.ttf and NotoSansDevanagari-Regular.ttf"
        )

    work = args.src_dir / "_cuplivo_subset_work"
    work.mkdir(parents=True, exist_ok=True)
    s1 = work / "super_sub.ttf"
    s2 = work / "vedic.ttf"
    subset_font(noto_sans, SUPER_SUB, s1)
    subset_font(noto_deva, VEDIC, s2)

    for path, cp in ((s1, 0x208C), (s2, 0x1CD0)):
        cmap = TTFont(str(path)).getBestCmap() or {}
        if cp not in cmap:
            raise SystemExit(f"{path.name} missing U+{cp:04X}")

    merged_path = work / "merged.ttf"
    Merger().merge([str(s1), str(s2)]).save(str(merged_path))

    font = TTFont(str(merged_path))
    rename_family(font)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    font.save(str(args.out))
    font.close()

    final = TTFont(str(args.out))
    cmap = final.getBestCmap() or {}
    missing = [f"U+{cp:04X}" for cp in REQUIRED if cp not in cmap]
    if missing:
        raise SystemExit(f"output missing {missing}")
    print(f"wrote {args.out} ({args.out.stat().st_size} bytes, {len(cmap)} codepoints)")


if __name__ == "__main__":
    main()
