#!/usr/bin/env python3
"""Check the identity sweep from both directions.

The sweep is the set of substitutions the identity commit applies to upstream's
tree (`tool/identity/rename.json`). It has two failure modes, one per direction,
and neither is visible in `git status`:

  * an **over-rename** leaves nothing to grep — the name is gone, so no search
    can report it. This is what renamed the browser workspace's scheme to
    `cuplivo` while the registry still advertised `KelivoLink.scheme`, and it
    surfaced as two browser tests, not as a rename defect;
  * an **under-rename** is invisible too, because files upstream added never
    conflict: they keep `package:Kelivo/` until the analyzer or a test reads
    them.

So the spec carries the protected names with a minimum presence, and this
script checks:

  --forward   what is left that should be gone (`package:Kelivo/`, ARB values)
  --inverse   every protected name is still there, where it has to be
  --exact     the mechanical files equal apply(substitutions, upstream)
  --derive    regenerate the mechanical list, and print the brand tokens a
              change introduced but nobody classified yet

Run it after the identity unit and at the tip (docs/rebase-runbook.md rule 19).
Nothing here replaces the test suite: the scheme defect was caught by a test,
and a value-preserving refactor (a literal replaced by a constant) can only be
pinned to the file that must still spell it out.

    python tool/identity/verify.py
    python tool/identity/verify.py --ref 00a2b7de0
    python tool/identity/verify.py --derive --write
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SPEC_PATH = os.path.join(HERE, "rename.json")
MECH_PATH = os.path.join(HERE, "mechanical.txt")

TOKEN = re.compile(r"[A-Za-z0-9_./:@$+-]*[Kk]elivo[A-Za-z0-9_./:@$+-]*")


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def tree_grep(needle: str, roots, regex: bool = False) -> list[str]:
    """Files in the working tree whose content contains `needle`."""
    flag = "-E" if regex else "-F"
    proc = git("grep", flag, "-l", "-e", needle, "--", *roots)
    if proc.returncode not in (0, 1):
        raise SystemExit(f"git grep failed for {needle!r}: {proc.stderr.strip()}")
    return [line for line in proc.stdout.splitlines() if line]


def tree_count(needle: str, roots, regex: bool = False) -> int:
    """Lines in the working tree that contain `needle`."""
    flag = "-E" if regex else "-F"
    proc = git("grep", flag, "-c", "-e", needle, "--", *roots)
    if proc.returncode not in (0, 1):
        raise SystemExit(f"git grep -c failed for {needle!r}: {proc.stderr.strip()}")
    total = 0
    for line in proc.stdout.splitlines():
        if ":" in line:
            total += int(line.rsplit(":", 1)[1])
    return total


def tree_count_in(needle: str, path: str, regex: bool = False) -> int:
    flag = "-E" if regex else "-F"
    proc = git("grep", flag, "-c", "-e", needle, "--", path)
    if proc.returncode not in (0, 1):
        raise SystemExit(f"git grep -c failed for {needle!r} in {path}: {proc.stderr.strip()}")
    return sum(int(line.rsplit(":", 1)[1]) for line in proc.stdout.splitlines() if ":" in line)


def blob(ref: str, path: str) -> str | None:
    proc = git("show", f"{ref}:{path}")
    if proc.returncode != 0:
        return None
    return proc.stdout.replace("\r\n", "\n")


def read(path: str) -> str | None:
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as handle:
            return handle.read().replace("\r\n", "\n")
    except OSError:
        return None


def apply_substitutions(text: str, spec: dict) -> str:
    for pair in spec["substitutions"]:
        text = text.replace(pair["from"], pair["to"])
    return text


def base_path_for(path: str, spec: dict) -> str:
    for move in spec.get("path_moves", []):
        path = path.replace(move["to"], move["from"])
    return path


def load_spec() -> dict:
    with open(SPEC_PATH, encoding="utf-8") as handle:
        return json.load(handle)


def load_mechanical() -> list[str]:
    if not os.path.exists(MECH_PATH):
        return []
    out = []
    with open(MECH_PATH, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line)
    return out


def check_forward(spec: dict) -> list[str]:
    """Everything that should be gone after the identity commit."""
    problems = []
    roots = spec["roots"]
    # The spec, the derived list and this script name the needles themselves, so
    # they are the one place the forward check must not read. The exemption is
    # those files, the tool's own tests, and whatever the spec lists as naming
    # the needle on purpose -- nothing else.
    own = {
        os.path.relpath(path, ROOT).replace(os.sep, "/")
        for path in (
            SPEC_PATH,
            MECH_PATH,
            os.path.abspath(__file__),
            os.path.join(HERE, "test_verify.py"),
        )
    }
    own.update(spec.get("names_the_needle", []))
    for needle in spec["imports_must_be_gone"]:
        hits = [path for path in tree_grep(needle, roots) if path not in own]
        if hits:
            problems.append(
                f"{needle!r} survives in {len(hits)} file(s): {', '.join(hits[:5])}"
                + (" …" if len(hits) > 5 else "")
            )
    l10n = spec["l10n"]
    directory = os.path.join(ROOT, l10n["dir"])
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".arb"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as handle:
            arb = json.load(handle)
        for key, value in arb.items():
            if key.startswith("@") or not isinstance(value, str):
                continue
            if l10n["brand"] in key or l10n["brand"] in value:
                if key in l10n["allowed_keys"]:
                    continue
                problems.append(f"{l10n['dir']}/{name}: {key} still names {l10n['brand']}")
    return problems


def check_inverse(spec: dict) -> list[str]:
    """Every protected name is still present, at the floor the spec sets."""
    problems = []
    roots = spec["roots"]
    for entry in spec["protected"]:
        name = entry["name"]
        regex = entry.get("regex", False)
        floor = entry.get("min", 1)
        found = tree_count(name, roots, regex)
        if found < floor:
            problems.append(
                f"protected {name!r}: {found} line(s) in the tree, expected at least {floor} "
                f"-- renamed? ({entry['why']})"
            )
        for path, want in entry.get("files", {}).items():
            if not os.path.exists(os.path.join(ROOT, path)):
                problems.append(f"protected {name!r}: {path} is missing")
                continue
            have = tree_count_in(name, path, regex)
            if have < want:
                problems.append(
                    f"protected {name!r}: {have} line(s) in {path}, expected {want} "
                    f"-- renamed? ({entry['why']})"
                )
    return problems


def check_exact(spec: dict, ref: str) -> list[str]:
    """Every mechanical file equals apply(substitutions, upstream)."""
    problems = []
    for path in load_mechanical():
        if not os.path.exists(os.path.join(ROOT, path)):
            problems.append(f"{path}: listed as mechanical but missing from the tree")
            continue
        source = blob(ref, base_path_for(path, spec))
        if source is None:
            problems.append(f"{path}: not found at {ref} (neither as itself nor under a path move)")
            continue
        want = apply_substitutions(source, spec)
        have = read(path) or ""
        if want != have:
            problems.append(f"{path}: differs from apply(substitutions, {ref}) -- hand-resolved, or drifted")
    return problems


def derive(spec: dict, ref: str) -> tuple[list[str], list[str], list[str]]:
    """Split the changed files into mechanical and hand-resolved, and name the
    brand tokens the change introduced without classifying them."""
    roots = spec["roots"]
    proc = git("diff", "--name-only", ref, "HEAD", "--", *roots)
    if proc.returncode != 0:
        raise SystemExit(f"git diff failed: {proc.stderr.strip()}")
    changed = [line for line in proc.stdout.splitlines() if line]
    mechanical, hand, unclassified = [], [], []
    for path in changed:
        source = blob(ref, base_path_for(path, spec))
        target = read(path)
        if source is None or target is None:
            hand.append(path)
            continue
        if apply_substitutions(source, spec) == target:
            mechanical.append(path)
        else:
            hand.append(path)
        before = set(TOKEN.findall(source))
        for token in sorted(set(TOKEN.findall(target)) - before):
            unclassified.append(f"{path}: {token}")
    return sorted(mechanical), sorted(hand), unclassified


def write_mechanical(mechanical: list[str], ref: str) -> None:
    with open(MECH_PATH, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            "# Generated by tool/identity/verify.py --derive --write against "
            f"{ref}.\n"
            "# Every path here must equal apply(substitutions, <baseline>): if one\n"
            "# drifts, the identity commit changed a file it claims was mechanical.\n"
        )
        for path in mechanical:
            handle.write(path + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ref", help="the upstream baseline to compare against (default: the spec's)")
    parser.add_argument("--forward", action="store_true", help="only the under-rename checks")
    parser.add_argument("--inverse", action="store_true", help="only the over-rename checks")
    parser.add_argument("--exact", action="store_true", help="only the mechanical-file check")
    parser.add_argument("--derive", action="store_true", help="recompute the mechanical set")
    parser.add_argument("--write", action="store_true", help="with --derive: rewrite mechanical.txt")
    parser.add_argument("--json", action="store_true", help="machine-readable result")
    args = parser.parse_args()

    spec = load_spec()
    ref = args.ref or spec["baseline"]
    only = args.forward or args.inverse or args.exact
    run_all = not only and not args.derive
    result = {"ref": ref, "forward": [], "inverse": [], "exact": [], "derive": None}

    if args.derive:
        mechanical, hand, unclassified = derive(spec, ref)
        result["derive"] = {
            "mechanical": mechanical,
            "hand": hand,
            "unclassified": unclassified,
        }
        if args.write:
            write_mechanical(mechanical, ref)
    if run_all or args.forward:
        result["forward"] = check_forward(spec)
    if run_all or args.inverse:
        result["inverse"] = check_inverse(spec)
    if run_all or args.exact:
        result["exact"] = check_exact(spec, ref)

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        for section in ("forward", "inverse", "exact"):
            for problem in result[section]:
                print(f"{section}: {problem}")
        if result["derive"] is not None:
            derived = result["derive"]
            print(f"mechanical: {len(derived['mechanical'])} file(s)")
            print(f"hand-resolved: {len(derived['hand'])} file(s)")
            if derived["unclassified"]:
                print(f"unclassified brand tokens: {len(derived['unclassified'])}")
                for line in derived["unclassified"]:
                    print(f"  {line}")
            if args.write:
                print(f"wrote {os.path.relpath(MECH_PATH, ROOT)}")
        total = len(result["forward"]) + len(result["inverse"]) + len(result["exact"])
        if total == 0:
            print(f"identity: clean against {ref}")
    total = len(result["forward"]) + len(result["inverse"]) + len(result["exact"])
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
