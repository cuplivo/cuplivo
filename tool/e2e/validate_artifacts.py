#!/usr/bin/env python3
"""Validates E2E artifacts before they are published to a comment branch.

The files come from test code inside a pull request, so the publisher never
trusts them: only safe file names are considered, PNG dimensions are read from
the IHDR header, and every file has a size cap. The manifest this writes is
what the publish comment is allowed to reference.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import struct

SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _png_size(path: pathlib.Path) -> tuple[int, int] | None:
    with path.open("rb") as handle:
        header = handle.read(33)
    if len(header) < 33 or header[:8] != PNG_SIGNATURE:
        return None
    length = struct.unpack(">I", header[8:12])[0]
    if length < 13 or header[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", header[16:24])
    return width, height


def _video_kind(path: pathlib.Path) -> str | None:
    with path.open("rb") as handle:
        header = handle.read(12)
    if len(header) >= 8 and header[4:8] == b"ftyp":
        return "mp4"
    if header.startswith(b"\x1aE\xdf\xa3"):
        return "webm"
    return None


def _gif(path: pathlib.Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(6) in (b"GIF87a", b"GIF89a")


def safe_files(directory: pathlib.Path, suffixes: tuple[str, ...]) -> list[pathlib.Path]:
    if not directory.is_dir():
        return []
    return sorted(
        entry
        for entry in directory.iterdir()
        if entry.is_file()
        and entry.suffix.lower() in suffixes
        and SAFE_NAME.match(entry.name)
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default="build/e2e/artifacts")
    parser.add_argument("--out", default="")
    parser.add_argument("--max-image-bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--max-video-bytes", type=int, default=50 * 1024 * 1024)
    parser.add_argument("--max-gif-bytes", type=int, default=8 * 1024 * 1024)
    args = parser.parse_args(argv)

    root = pathlib.Path(args.root)
    manifest: dict[str, object] = {
        "screenshots": [],
        "failures": [],
        "videos": [],
        "gifs": [],
        "invalid": [],
    }

    for path in safe_files(root / "screenshots", (".png",)):
        if path.stat().st_size > args.max_image_bytes:
            manifest["invalid"].append({"name": path.name, "reason": "too large"})
            continue
        size = _png_size(path)
        if size is None or size[0] <= 0 or size[1] <= 0 or size[0] > 10000 or size[1] > 10000:
            manifest["invalid"].append({"name": path.name, "reason": "bad png"})
            continue
        manifest["screenshots"].append(
            {
                "name": path.name,
                "bytes": path.stat().st_size,
                "width": size[0],
                "height": size[1],
            }
        )

    for path in safe_files(root / "failure-screenshots", (".png",)):
        if path.stat().st_size > args.max_image_bytes or _png_size(path) is None:
            manifest["invalid"].append({"name": path.name, "reason": "bad failure png"})
            continue
        manifest["failures"].append({"name": path.name, "bytes": path.stat().st_size})

    for path in safe_files(root / "video", (".mp4", ".webm")):
        if path.stat().st_size > args.max_video_bytes:
            manifest["invalid"].append({"name": path.name, "reason": "video too large"})
            continue
        kind = _video_kind(path)
        if kind is None:
            manifest["invalid"].append({"name": path.name, "reason": "bad video"})
            continue
        manifest["videos"].append(
            {"name": path.name, "kind": kind, "bytes": path.stat().st_size}
        )

    for path in safe_files(root / "video", (".gif",)):
        if path.stat().st_size > args.max_gif_bytes or not _gif(path):
            manifest["invalid"].append({"name": path.name, "reason": "bad gif"})
            continue
        manifest["gifs"].append({"name": path.name, "bytes": path.stat().st_size})

    out = pathlib.Path(args.out) if args.out else root / "manifest.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        "e2e artifacts: "
        f"{len(manifest['screenshots'])} screenshot(s), "
        f"{len(manifest['failures'])} failure capture(s), "
        f"{len(manifest['videos'])} video(s), "
        f"{len(manifest['gifs'])} gif(s), "
        f"{len(manifest['invalid'])} rejected"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
