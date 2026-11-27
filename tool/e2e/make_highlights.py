#!/usr/bin/env python3
"""Cuts the key-operations clip and GIF preview out of the full recording.

The driver records a host timestamp for every screenshot; the shell records
when screenrecord started. The window between the first and last screenshot is
the part a reviewer wants in the PR comment; the full MP4 stays in the
artifact. Everything here is best-effort: a missing video, ffmpeg or timestamps
must not fail the run.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import pathlib
import shutil
import subprocess

MAX_GIF_BYTES = 8 * 1024 * 1024
# The driver's screenshot callbacks can all arrive after the test body has
# finished, so their span is not a usable clip window. When that happens, cut
# from the test start to the last callback instead.
CLUSTERED_SPAN_SECONDS = 5.0


def _iso_ms(value: object) -> int:
    if not isinstance(value, str):
        return 0
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return 0


def run_ffmpeg(args: list[str]) -> bool:
    try:
        result = subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        print(f"e2e highlights: ffmpeg unavailable: {error}")
        return False
    if result.returncode != 0:
        print(f"e2e highlights: ffmpeg failed: {result.stderr.strip()[:400]}")
        return False
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default="build/e2e")
    parser.add_argument("--screenshots", default="")
    parser.add_argument("--record", default="")
    parser.add_argument("--max-preview-seconds", type=float, default=25.0)
    args = parser.parse_args(argv)

    root = pathlib.Path(args.root)
    video_dir = root / "video"
    if not shutil.which("ffmpeg"):
        print("e2e highlights: no ffmpeg; skipping")
        return 0

    videos = sorted(
        path
        for path in video_dir.glob("*")
        if path.suffix.lower() in (".mp4", ".webm")
        and path.name not in ("highlights.mp4",)
        and path.is_file()
    )
    if not videos:
        print("e2e highlights: no recording; skipping")
        return 0
    source = videos[0]

    screenshots_path = (
        pathlib.Path(args.screenshots)
        if args.screenshots
        else root / "screenshots" / "screenshots.json"
    )
    record_path = (
        pathlib.Path(args.record) if args.record else video_dir / "record.json"
    )
    start_epoch = 0
    if record_path.is_file():
        try:
            start_epoch = int(json.loads(record_path.read_text()).get("recordStartEpoch", 0))
        except (ValueError, TypeError, json.JSONDecodeError):
            start_epoch = 0
    first_ms = last_ms = started_ms = 0
    if screenshots_path.is_file():
        try:
            payload = json.loads(screenshots_path.read_text())
            stamps = [
                int(item["epochMs"])
                for item in payload.get("screenshots", [])
                if isinstance(item, dict) and "epochMs" in item
            ]
            if stamps:
                first_ms, last_ms = min(stamps), max(stamps)
            started_ms = _iso_ms(payload.get("startedAt"))
        except (ValueError, TypeError, KeyError, json.JSONDecodeError):
            first_ms = last_ms = started_ms = 0

    start = 0.0
    duration = 0.0
    if start_epoch > 0 and last_ms > 0:
        span = (last_ms - first_ms) / 1000.0
        if started_ms > 0 and span < CLUSTERED_SPAN_SECONDS:
            # Screenshots were queued and delivered together at the end of the
            # run; the UI work happened between test start and that delivery.
            start = max(0.0, started_ms / 1000.0 - start_epoch - 2.0)
            end = last_ms / 1000.0 - start_epoch + 2.0
        elif first_ms > 0 and last_ms >= first_ms:
            start = max(0.0, first_ms / 1000.0 - start_epoch - 2.0)
            end = last_ms / 1000.0 - start_epoch + 2.0
        if end > start + 1.0:
            duration = min(end - start, 180.0)
    if duration <= 0:
        start = 0.0
        duration = 0.0

    highlight = video_dir / "highlights.mp4"
    args_highlight = [
        "-ss",
        f"{start:.2f}",
        "-i",
        str(source),
    ]
    if duration > 0:
        args_highlight += ["-t", f"{duration:.2f}"]
    args_highlight += [
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        "-an",
        str(highlight),
    ]
    if run_ffmpeg(args_highlight):
        print(f"e2e highlights: {highlight}")
    else:
        highlight.unlink(missing_ok=True)
        return 0

    preview = video_dir / "preview.gif"
    preview_seconds = duration if duration > 0 else args.max_preview_seconds
    # Sample across the whole clip rather than only its first seconds. The
    # screenshot callbacks can cluster late; keep the preview bounded.
    # 20 frames and cap the frame rate at 6 fps.
    preview_fps = min(6.0, 20.0 / preview_seconds) if preview_seconds > 0 else 6.0
    for width, fps in ((540, preview_fps), (360, preview_fps)):
        if run_ffmpeg(
            [
                "-ss",
                f"{start:.2f}",
                "-i",
                str(source),
                "-t",
                f"{preview_seconds:.2f}",
                "-vf",
                f"fps={fps},scale={width}:-1:flags=lanczos",
                "-loop",
                "0",
                str(preview),
            ]
        ):
            if preview.is_file() and preview.stat().st_size <= MAX_GIF_BYTES:
                print(f"e2e highlights: {preview} ({preview.stat().st_size} bytes)")
                return 0
            preview.unlink(missing_ok=True)
    print("e2e highlights: GIF preview skipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
