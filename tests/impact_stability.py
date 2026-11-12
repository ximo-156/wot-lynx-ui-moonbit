#!/usr/bin/env python3
"""MoonImpact stability audit against a real project; strictly read-only.

python3 tests/impact_stability.py --binary /absolute/path/to/impact.exe \\
    --project /path/to/a/vue-ts-project [--config path] [--samples 60]

The audited project is never modified: planning is read-only, reports are
written into an owned temporary directory outside the project, and no test
process is started. Without --project the suite skips.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import time
import unittest

BINARY: Path | None = None
PROJECT: Path | None = None
CONFIG: Path | None = None
SAMPLES = 60

STRATEGIES = {"none", "related", "full", "blocked"}


class ImpactStability(unittest.TestCase):
    def setUp(self):
        assert BINARY and PROJECT
        self.temp = tempfile.TemporaryDirectory(prefix="moonimpact-stability-")
        self.owner = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull, "GIT_TERMINAL_PROMPT": "0",
        })
        self.timings: list[float] = []

    def plan(self, *args, expected=None):
        started = time.monotonic()
        command = [str(BINARY), "plan"]
        if CONFIG is not None:
            command += ["--config", str(CONFIG)]
        command += [*map(str, args), str(PROJECT)]
        result = subprocess.run(
            command,
            cwd=self.owner, env=self.env, text=True, capture_output=True, timeout=120,
        )
        self.timings.append(time.monotonic() - started)
        if expected is not None:
            self.assertEqual(
                result.returncode, expected,
                f"args={args}\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}",
            )
        return result

    def json_plan(self, *args, expected=0):
        result = self.plan(*args, "--format", "json", expected=expected)
        return json.loads(result.stdout)

    def check_plan_invariants(self, doc, label):
        self.assertIn(doc["strategy"], STRATEGIES, label)
        inventory = doc["inventory"]
        self.assertEqual(inventory, sorted(inventory), f"{label}: inventory sorted")
        self.assertLessEqual(len(doc["tests"]), len(inventory), f"{label}: selection size")
        if doc["strategy"] == "related":
            self.assertGreater(len(doc["tests"]), 0, f"{label}: related selects something")
            selected = set(doc["tests"])
            self.assertTrue(selected <= set(inventory), f"{label}: selection within inventory")
            for trace in doc["traces"]:
                self.assertIn(trace["test"], selected, f"{label}: traced test is selected")
                for edge in trace["chain"]:
                    self.assertTrue(edge["dependency"], f"{label}: empty dependency")
        if doc["strategy"] == "full":
            self.assertEqual(doc["tests"], inventory, f"{label}: full runs the inventory")
        if doc["strategy"] == "blocked":
            self.assertTrue(
                any(issue["reason"].startswith(("io:", "unsafe:")) for issue in doc["issues"]),
                f"{label}: blocked explains itself",
            )
        self.assertTrue(doc["advisory"], f"{label}: plan stays advisory")
        self.assertEqual(doc["source_snapshot"], "live-working-tree", label)

    # -- stability dimensions -------------------------------------------------

    def test_repeated_runs_are_byte_identical(self):
        first = self.plan("--file", self.sample_source(), "--format", "json")
        for _ in range(2):
            again = self.plan("--file", self.sample_source(), "--format", "json")
            self.assertEqual(first.stdout, again.stdout)
        text = self.plan("--file", self.sample_source())
        self.assertIn("strategy:", text.stdout)

    def test_change_input_sweep_never_misbehaves(self):
        files = self.sample_files(SAMPLES)
        self.assertGreater(len(files), SAMPLES // 2)
        failures = []
        for path in files:
            try:
                doc = self.json_plan("--file", path)
                self.check_plan_invariants(doc, path)
            except Exception as error:  # noqa: BLE001 - collected, reported below
                failures.append(f"{path}: {error}")
        self.assertEqual(failures, [])

    def test_git_input_modes_agree_with_file_input(self):
        if not (PROJECT / ".git").exists():
            self.skipTest("project is not a Git repository")
        worktree = self.json_plan("--worktree")
        self.check_plan_invariants(worktree, "--worktree")
        base = self.json_plan("--base", "HEAD")
        self.check_plan_invariants(base, "--base HEAD")

    def test_degenerate_inputs_fail_loudly_or_plan_honestly(self):
        missing = self.plan("--file", "definitely/not/here.ts", expected=0)
        doc = json.loads(missing.stdout)
        self.assertEqual(doc["strategy"], "full")
        self.assertTrue(
            any(r.startswith("removed-or-missing-input") for r in doc["reasons"]),
        )
        # A directory is not a membership file: it is a missing input, planned
        # as a full regression rather than a crash.
        directory = self.json_plan("--file", "packages")
        self.assertEqual(directory["strategy"], "full")
        self.assertTrue(
            any(r.startswith("removed-or-missing-input") for r in directory["reasons"]),
        )
        mixed = self.plan("--worktree", "--file", "packages/core/package.json", expected=2)
        self.assertIn("choose exactly one change input", mixed.stderr)

    def test_report_is_create_only_and_html_has_no_scripts(self):
        target = self.owner / "plan.json"
        self.plan("--file", self.sample_source(), "--report", str(target))
        self.assertTrue(target.exists())
        before = target.read_text(encoding="utf-8")
        again = self.plan(
            "--file", self.sample_source(), "--report", str(target), expected=2,
        )
        self.assertIn("moonimpact:", again.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), before)
        html = self.plan("--file", self.sample_source(), "--format", "html")
        self.assertIn("<html", html.stdout.lower())
        self.assertNotIn("<script", html.stdout.lower())

    def test_timing_stays_bounded(self):
        for _ in range(3):
            self.plan("--file", self.sample_source())
        slowest = max(self.timings)
        self.assertLess(slowest, 60.0, f"slowest plan took {slowest:.1f}s")

    # -- helpers --------------------------------------------------------------

    def sample_source(self) -> str:
        return self.sample_files(1, suffixes={".ts", ".vue"})[0]

    def sample_files(self, count: int, suffixes: set[str] | None = None) -> list[str]:
        root = PROJECT
        pool: list[str] = []
        for base, dirs, names in os.walk(root):
            dirs[:] = [d for d in dirs if d not in {
                ".git", "node_modules", "dist", "_build", "coverage",
            }]
            for name in names:
                rel = os.path.relpath(os.path.join(base, name), root)
                if suffixes and Path(name).suffix not in suffixes:
                    continue
                pool.append(rel)
        self.assertTrue(pool)
        rng = random.Random(20261112)
        rng.shuffle(pool)
        chosen = pool[:count]
        # Always include the awkward names the real tree contains.
        for awkward in pool:
            if " " in awkward and awkward not in chosen:
                chosen.append(awkward)
                break
        return chosen


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--project", type=Path)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--samples", type=int, default=60)
    args = parser.parse_args()
    global BINARY, PROJECT, CONFIG, SAMPLES
    BINARY, PROJECT, CONFIG, SAMPLES = args.binary, args.project, args.config, args.samples
    if PROJECT is None:
        print("impact_stability: no --project given; skipping (read-only audit)")
        return 0
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ImpactStability)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
