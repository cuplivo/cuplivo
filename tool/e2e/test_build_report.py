#!/usr/bin/env python3
"""Unit tests for the E2E report renderer (stdlib only).

Run from the repository root:
  python3 -m unittest tool/e2e/test_build_report.py
"""

from __future__ import annotations

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import build_report  # noqa: E402


class BuildReportTest(unittest.TestCase):
    def _root(self, directory: pathlib.Path) -> pathlib.Path:
        (directory / "screenshots").mkdir()
        (directory / "screenshots" / "01_home_chat_light.png").write_bytes(b"png")
        (directory / "screenshots" / "bad name.png").write_bytes(b"png")
        (directory / "screenshots" / ".hidden.png").write_bytes(b"png")
        (directory / "video").mkdir()
        (directory / "video" / "e2e.mp4").write_bytes(b"mp4" * 10)
        (directory / "video" / "highlights.mp4").write_bytes(b"mp4" * 5)
        (directory / "video" / "preview.gif").write_bytes(b"gif")
        (directory / "logs").mkdir()
        (directory / "logs" / "logcat.txt").write_text("log")
        return directory

    def test_comment_embeds_only_safe_names(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(pathlib.Path(tmp))
            files = build_report.collect(root)
            comment = build_report.build_comment(
                status="passed",
                duration_seconds=65,
                run_url="https://example.com/run/1",
                sha="abcdef1234567890",
                requested_by="tester",
                files=files,
                image_base_url="https://example.com/raw/deadbeef",
                scenario="integration_test/e2e/example_acceptance_test.dart",
            )
            self.assertIn("<!-- android-e2e -->", comment)
            self.assertIn("01_home_chat_light", comment)
            self.assertIn("https://example.com/raw/deadbeef/01_home_chat_light.png", comment)
            self.assertNotIn("bad name", comment)
            self.assertNotIn(".hidden", comment)
            self.assertIn("highlights.mp4", comment)
            self.assertIn("preview.gif", comment)
            self.assertIn("integration_test/e2e/example_acceptance_test.dart", comment)
            self.assertIn("1m 5s", comment)

    def test_comment_caps_inline_screenshots(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(pathlib.Path(tmp))
            screenshots = root / "screenshots"
            for index in range(2, 9):
                (screenshots / f"{index:02d}_capture.png").write_bytes(b"png")
            files = build_report.collect(root)
            comment = build_report.build_comment(
                status="passed",
                duration_seconds=65,
                run_url="https://example.com/run/1",
                sha="",
                requested_by="",
                files=files,
                image_base_url="https://example.com/raw/deadbeef",
            )
            self.assertIn("2 more screenshot(s)", comment)
            self.assertNotIn("07_capture", comment)

    def test_empty_root_still_writes_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / "empty"
            root.mkdir()
            files = build_report.collect(root)
            comment = build_report.build_comment(
                status="failed",
                duration_seconds=0,
                run_url="https://example.com/run/1",
                sha="",
                requested_by="",
                files=files,
                image_base_url="",
            )
            self.assertIn("failed", comment)
            self.assertIn("none captured", comment)
            self.assertIn("acceptance scenario failed", comment)
            self.assertEqual(len(files["screenshots"]), 0)

    def test_gallery_and_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(pathlib.Path(tmp))
            files = build_report.collect(root)
            gallery = root / "index.html"
            build_report.write_gallery(
                root,
                status="passed",
                duration_seconds=65,
                run_url="https://example.com/run/1",
                files=files,
                out=gallery,
            )
            html = gallery.read_text()
            self.assertIn("01_home_chat_light", html)
            self.assertIn("screenshots/01_home_chat_light.png", html)
            summary = build_report.build_summary(
                status="passed",
                duration_seconds=65,
                run_url="https://example.com/run/1",
                sha="abcdef1234567890",
                files=files,
                scenario="integration_test/e2e/example_acceptance_test.dart",
            )
            self.assertIn("Screenshots: **1**", summary)
            self.assertIn("integration_test/e2e/example_acceptance_test.dart", summary)

    def test_human_helpers(self) -> None:
        self.assertEqual(build_report.human_duration(0), "0s")
        self.assertEqual(build_report.human_duration(65), "1m 5s")
        self.assertEqual(build_report.human_bytes(512), "512 B")
        self.assertEqual(build_report.human_bytes(1536), "1.5 KB")


if __name__ == "__main__":
    unittest.main()
