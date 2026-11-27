#!/usr/bin/env python3
"""Tests for the identity spec and its substitution rule.

The verifier itself is greps and `git show`; what is worth pinning here is the
one place a later edit can silently widen the sweep: the substitution list. A
`Kelivo` -> `Cuplivo` regex would pass every test the tree has and rename the
protocol names, so the rule is exercised against the names that must survive.
"""

from __future__ import annotations

import json
import os
import unittest

import verify


class ApplySubstitutionsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.spec = verify.load_spec()

    def test_renames_the_package_and_the_application_id(self) -> None:
        source = "import 'package:Kelivo/core/x.dart';\nid = com.psyche.kelivo;\n"
        got = verify.apply_substitutions(source, self.spec)
        self.assertIn("package:Cuplivo/core/x.dart", got)
        self.assertIn("com.cuplivo.cuplivo", got)
        self.assertNotIn("Kelivo", got)
        self.assertNotIn("psyche.kelivo", got)

    def test_leaves_every_protected_name_alone(self) -> None:
        protected = [entry["name"] for entry in self.spec["protected"]
                     if not entry.get("regex") and not entry.get("rewritten")]
        source = "\n".join(protected)
        got = verify.apply_substitutions(source, self.spec)
        for name in protected:
            self.assertIn(name, got, f"{name} was rewritten by a substitution")

    def test_a_rewritten_protected_name_is_a_substitution_source(self) -> None:
        # One protected entry is the opposite shape: `com.psyche.kelivo` *is* a
        # substitution source, and the entry exists because one file has to keep
        # spelling the old id (kelivo_file_uri resolves the paths an install
        # wrote before the rename). The flag keeps the two claims apart: this
        # entry is a presence claim, not a "the substitution must not touch it"
        # claim. It has to stay pinned to the file that keeps it.
        rewritten = [entry for entry in self.spec["protected"] if entry.get("rewritten")]
        sources = {pair["from"] for pair in self.spec["substitutions"]}
        for entry in rewritten:
            self.assertIn(entry["name"], sources,
                          f"{entry['name']}: no substitution rewrites it, so drop the flag")
            self.assertTrue(entry.get("files"),
                            f"{entry['name']}: a rewritten name needs a file pin")

    def test_does_not_touch_a_file_name_that_contains_the_brand(self) -> None:
        # kelivo_file_uri.dart, kelivo_markdown_extensions.dart and
        # kelivo_fetch_server.dart are code identifiers, not branding.
        source = "import 'package:Kelivo/utils/kelivo_file_uri.dart';\n"
        got = verify.apply_substitutions(source, self.spec)
        self.assertIn("package:Cuplivo/utils/kelivo_file_uri.dart", got)


class PathMoveTest(unittest.TestCase):
    def setUp(self) -> None:
        self.spec = verify.load_spec()

    def test_a_moved_file_finds_its_base_path(self) -> None:
        moved = "android/app/src/main/kotlin/com/cuplivo/cuplivo/MainActivity.kt"
        self.assertEqual(
            verify.base_path_for(moved, self.spec),
            "android/app/src/main/kotlin/com/psyche/kelivo/MainActivity.kt",
        )

    def test_an_unmoved_file_is_unchanged(self) -> None:
        path = "lib/core/providers/update_provider.dart"
        self.assertEqual(verify.base_path_for(path, self.spec), path)


class SpecHygieneTest(unittest.TestCase):
    def setUp(self) -> None:
        self.spec = verify.load_spec()

    def test_every_protected_entry_carries_a_floor_and_a_reason(self) -> None:
        for entry in self.spec["protected"]:
            self.assertIn("why", entry, entry["name"])
            self.assertGreaterEqual(entry.get("min", 1), 1, entry["name"])
            self.assertTrue(entry["why"].strip(), entry["name"])

    def test_every_pinned_file_floor_is_at_least_one(self) -> None:
        for entry in self.spec["protected"]:
            for path, floor in entry.get("files", {}).items():
                self.assertGreaterEqual(floor, 1, f"{entry['name']} in {path}")

    def test_the_mechanical_list_is_derived_and_not_empty(self) -> None:
        mechanical = verify.load_mechanical()
        self.assertGreater(len(mechanical), 100)
        for path in mechanical:
            self.assertFalse(path.startswith("/"), path)
            self.assertFalse(path.startswith(".."), path)

    def test_the_spec_still_spells_the_needles_it_is_exempt_from(self) -> None:
        # `--forward` skips the files that *define* the rule, because they name
        # the needles on purpose. This is the guard on that exemption: a sweep
        # that rewrote the spec itself would otherwise pass the very check it
        # had just disabled.
        with open(verify.SPEC_PATH, encoding="utf-8") as handle:
            text = handle.read()
        for pair in self.spec["substitutions"]:
            self.assertIn(pair["from"], text, pair["from"])
        for needle in self.spec["imports_must_be_gone"]:
            self.assertIn(needle, text, needle)

    def test_every_named_needle_file_exists_and_still_names_one(self) -> None:
        # The other half of the same exemption: a file listed as naming the needle
        # must still exist and still contain it, or the exemption has outlived its
        # reason and is hiding a file the forward check would now catch.
        needles = self.spec["imports_must_be_gone"]
        for path in self.spec.get("names_the_needle", []):
            full = os.path.join(verify.ROOT, path)
            self.assertTrue(os.path.exists(full), path)
            with open(full, encoding="utf-8") as handle:
                text = handle.read()
            self.assertTrue(any(needle in text for needle in needles), path)


if __name__ == "__main__":
    unittest.main()
