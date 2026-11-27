#!/usr/bin/env python3
"""Builds the gallery, job summary and PR comment for the Android E2E run.

One script writes all three so status, counts, links and screenshot names never
drift apart. It only looks at file names and sizes; screenshot bytes are never
decoded. The inputs come from test code inside a pull request, so names are
treated as untrusted text: only a conservative character set is accepted and
everything inserted into HTML/markdown is escaped.
"""

from __future__ import annotations

import argparse
import html
import pathlib
import re

SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MAX_LISTED = 12
MAX_INLINE_SCREENSHOTS = 6

GALLERY_HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Android E2E artifacts</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 24px; background: #111; color: #eee; }
  a { color: #8ab4f8; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 16px; }
  figure { margin: 0; background: #1e1e1e; border-radius: 10px; padding: 8px; }
  img { width: 100%; border-radius: 6px; display: block; }
  figcaption { font-size: 12px; margin-top: 6px; color: #bbb; word-break: break-all; }
  video { max-width: 100%; border-radius: 10px; }
  code { background: #222; padding: 1px 4px; border-radius: 4px; }
  .muted { color: #999; }
</style>
</head>
<body>
"""


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


def human_bytes(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GB"


def human_duration(seconds: int) -> str:
    minutes, secs = divmod(max(0, int(seconds)), 60)
    return f"{minutes}m {secs}s" if minutes else f"{secs}s"


def collect(root: pathlib.Path) -> dict[str, list[pathlib.Path]]:
    logs = safe_files(root / "logs", (".txt", ".log")) + safe_files(root, (".log",))
    logs = sorted({path: path for path in logs}.values(), key=lambda p: p.name)
    return {
        "screenshots": safe_files(root / "screenshots", (".png",)),
        "failures": safe_files(root / "failure-screenshots", (".png",)),
        "video": safe_files(root / "video", (".mp4", ".webm")),
        "gif": safe_files(root / "video", (".gif",)),
        "logs": logs,
    }


def image_grid(root: pathlib.Path, files: list[pathlib.Path], title: str) -> str:
    if not files:
        return ""
    cells = []
    for path in files:
        relative = html.escape(path.relative_to(root).as_posix())
        name = html.escape(path.stem)
        cells.append(
            f'<figure><a href="{relative}"><img loading="lazy" '
            f'src="{relative}" alt="{name}"></a>'
            f"<figcaption>{name}</figcaption></figure>"
        )
    return f"<h2>{html.escape(title)}</h2>\n<div class=\"grid\">\n" + "\n".join(cells) + "\n</div>\n"


def write_gallery(
    root: pathlib.Path,
    *,
    status: str,
    duration_seconds: int,
    run_url: str,
    files: dict[str, list[pathlib.Path]],
    out: pathlib.Path,
) -> None:
    passed = status == "passed"
    icon = "\u2705" if passed else "\u274c"
    body = [
        GALLERY_HEAD,
        f"<h1>Android emulator E2E: {icon} {html.escape(status)} "
        f"({human_duration(duration_seconds)})</h1>",
    ]
    if run_url:
        body.append(
            f'<p class="muted">Workflow run: '
            f'<a href="{html.escape(run_url)}">{html.escape(run_url)}</a></p>'
        )
    body.append(
        "<p>Download the <code>cuplivo-debug-apk</code> artifact to install "
        "the branch's debug build on an arm64 phone.</p>"
    )
    body.append(image_grid(root, files["screenshots"], "Acceptance screenshots"))
    body.append(image_grid(root, files["failures"], "Failure screenshots"))
    for path in files["video"]:
        body.append(
            f"<h2>Screen recording</h2><video controls "
            f'src="{html.escape(path.relative_to(root).as_posix())}"></video>'
        )
    if files["gif"]:
        body.append(image_grid(root, files["gif"], "Key-operations preview"))
    if files["logs"]:
        items = "\n".join(
            '<li><a href="'
            + html.escape(path.relative_to(root).as_posix())
            + '">'
            + html.escape(path.name)
            + "</a></li>"
            for path in files["logs"]
        )
        body.append("<h2>Logs</h2>\n<ul>\n" + items + "\n</ul>\n")
    body.append("</body>\n</html>\n")
    out.write_text("".join(body), encoding="utf-8")


def list_names(files: list[pathlib.Path], limit: int = MAX_LISTED) -> str:
    names = [f"`{path.stem}`" for path in files[:limit]]
    if len(files) > limit:
        names.append(f"and {len(files) - limit} more")
    return ", ".join(names)


def video_names(files: dict[str, list[pathlib.Path]]) -> list[str]:
    names = []
    for path in files["video"]:
        if path.name == "highlights.mp4":
            names.append("highlights")
        elif path.name.startswith("e2e."):
            names.append("full")
    for path in files["gif"]:
        if path.name == "preview.gif":
            names.append("preview")
    return names


def build_comment(
    *,
    status: str,
    duration_seconds: int,
    run_url: str,
    sha: str,
    requested_by: str,
    files: dict[str, list[pathlib.Path]],
    image_base_url: str,
    scenario: str = "",
) -> str:
    passed = status == "passed"
    heading = "passed" if passed else "failed"
    icon = "\u2705" if passed else "\u274c"
    lines = [
        "<!-- android-e2e -->",
        f"## Android emulator E2E: {icon} {heading} "
        f"({human_duration(duration_seconds)})",
        "",
    ]
    meta = []
    if scenario:
        meta.append(f"scenario `{scenario}`")
    if sha:
        meta.append(f"commit `{sha[:12]}`")
    if requested_by:
        meta.append(f"requested by @{requested_by}")
    if meta:
        lines.append(f"_{' \u00b7 '.join(meta)}_")
        lines.append("")

    screenshots = files["screenshots"]
    if screenshots and image_base_url:
        base = image_base_url.rstrip("/")
        lines.append(
            f"<details><summary><b>Screenshots ({len(screenshots)})</b></summary>"
        )
        lines.append("")
        for path in screenshots[:MAX_INLINE_SCREENSHOTS]:
            name = html.escape(path.stem)
            url = f"{base}/{html.escape(path.name)}"
            lines.append(f"![{name}]({url})")
        if len(screenshots) > MAX_INLINE_SCREENSHOTS:
            remaining = len(screenshots) - MAX_INLINE_SCREENSHOTS
            lines.append("")
            lines.append(
                f"{remaining} more screenshot(s) are in the "
                "`e2e-screenshots` artifact."
            )
        lines.append("")
        lines.append("</details>")
        lines.append("")
    elif screenshots:
        lines.append(f"- Screenshots: {list_names(screenshots)}")
    else:
        lines.append("- Screenshots: **none captured**")

    if image_base_url:
        base = image_base_url.rstrip("/")
        for path in files["gif"]:
            if path.name == "preview.gif":
                lines.append(f"![key operations]({base}/{html.escape(path.name)})")
                lines.append("")
        links = []
        for path in files["video"]:
            label = "key-operations clip" if path.name == "highlights.mp4" else "full screen recording"
            links.append(f"[{label}]({base}/{html.escape(path.name)})")
        if links:
            lines.append("- Video: " + " \u00b7 ".join(links))
    else:
        names = video_names(files)
        if names:
            lines.append(f"- Video: {', '.join(names)} (see artifacts)")

    lines.append(
        f"- Artifacts: [workflow run]({run_url}) "
        "(\u0060e2e-screenshots\u0060, \u0060e2e-video\u0060, "
        "\u0060e2e-logs\u0060, \u0060cuplivo-debug-apk\u0060)"
    )
    if not passed:
        lines.append(
            "- The acceptance scenario failed; \u0060e2e-logs\u0060 carries the "
            "Flutter drive log and a logcat tail, \u0060failure-screenshots\u0060 "
            "the device screen when the run ended."
        )
    if files["failures"]:
        lines.append(f"- Failure captures: {list_names(files['failures'], 8)}")
    lines.append("")
    lines.append(
        "<sub>Re-run with `/e2e` \u00b7 see `docs/e2e-android.md` for the "
        "incremental scenario contract and artifact map.</sub>"
    )
    return "\n".join(lines) + "\n"


def build_summary(
    *,
    status: str,
    duration_seconds: int,
    run_url: str,
    sha: str,
    files: dict[str, list[pathlib.Path]],
    scenario: str = "",
) -> str:
    icon = "\u2705" if status == "passed" else "\u274c"
    lines = [
        f"## Android emulator E2E: {icon} {status} "
        f"({human_duration(duration_seconds)})",
        "",
    ]
    if scenario:
        lines.append(f"- Scenario: `{scenario}`")
    if sha:
        lines.append(f"- Commit: `{sha[:12]}`")
    lines.append(f"- Screenshots: **{len(files['screenshots'])}**")
    video_bytes = sum(path.stat().st_size for path in files["video"])
    lines.append(
        f"- Video: **{len(files['video'])}** file(s), {human_bytes(video_bytes)}"
    )
    if files["failures"]:
        lines.append(f"- Failure captures: {list_names(files['failures'], 8)}")
    if files["screenshots"]:
        lines.append(f"- Captured: {list_names(files['screenshots'])}")
    lines.append(f"- Artifacts: {run_url}")
    lines.append("")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default="build/e2e")
    parser.add_argument(
        "--status", default="unknown", choices=["passed", "failed", "unknown"]
    )
    parser.add_argument("--duration-seconds", type=int, default=0)
    parser.add_argument("--run-url", default="")
    parser.add_argument("--sha", default="")
    parser.add_argument("--requested-by", default="")
    parser.add_argument("--scenario", default="")
    parser.add_argument("--image-base-url", default="")
    parser.add_argument("--comment-out", default="")
    parser.add_argument("--summary-out", default="")
    parser.add_argument("--gallery-out", default="")
    args = parser.parse_args(argv)

    root = pathlib.Path(args.root)
    root.mkdir(parents=True, exist_ok=True)
    files = collect(root)

    comment = build_comment(
        status=args.status,
        duration_seconds=args.duration_seconds,
        run_url=args.run_url,
        sha=args.sha,
        requested_by=args.requested_by,
        files=files,
        image_base_url=args.image_base_url,
        scenario=args.scenario,
    )
    summary = build_summary(
        status=args.status,
        duration_seconds=args.duration_seconds,
        run_url=args.run_url,
        sha=args.sha,
        files=files,
        scenario=args.scenario,
    )
    comment_out = pathlib.Path(args.comment_out) if args.comment_out else root / "pr-comment.md"
    summary_out = pathlib.Path(args.summary_out) if args.summary_out else root / "summary.md"
    gallery_out = pathlib.Path(args.gallery_out) if args.gallery_out else root / "index.html"
    comment_out.parent.mkdir(parents=True, exist_ok=True)
    summary_out.parent.mkdir(parents=True, exist_ok=True)
    gallery_out.parent.mkdir(parents=True, exist_ok=True)
    comment_out.write_text(comment, encoding="utf-8")
    summary_out.write_text(summary, encoding="utf-8")
    write_gallery(
        root,
        status=args.status,
        duration_seconds=args.duration_seconds,
        run_url=args.run_url,
        files=files,
        out=gallery_out,
    )
    print(
        f"e2e report: {len(files['screenshots'])} screenshot(s), "
        f"{len(files['failures'])} failure capture(s), "
        f"{len(files['video'])} video(s), {len(files['gif'])} gif(s) -> {root}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
