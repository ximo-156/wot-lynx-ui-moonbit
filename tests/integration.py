#!/usr/bin/env python3
"""Dependency-free moonlint CLI integration tests.

Run: python3 tests/integration.py --binary /absolute/path/to/moonlint --phase repairs
The runner never builds moonlint. Fixtures, configs, baselines, and Git repositories
are exclusively inside independently owned tempfile.TemporaryDirectory instances.
Scope/output phase names are reserved until those features are implemented.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


BINARY: Path | None = None
RULE_ID = "test/forbidden"
TOKEN = "FORBIDDEN"


def rule(*, rule_id=RULE_ID, severity="error", extensions=None, token=TOKEN):
    return {
        "id": rule_id,
        "severity": severity,
        "message": "Forbidden fixture token",
        "extensions": [".ts"] if extensions is None else extensions,
        "match": {"contains": token},
    }


class FixtureCase(unittest.TestCase):
    """Own every filesystem mutation; isolate CLI and Git from the real checkout."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moonlint-integration-")
        self.base = Path(self.temp.name).resolve()
        self._owned_base = self.base
        self.addCleanup(self.cleanup_temp)
        self.root = self.base / "root"
        self.root.mkdir()
        # The scanner must not accidentally lint its own JSON config/baseline.
        self.config = self.base / "rules.json"
        self.baseline = self.base / "baseline.json"
        self.write_config()
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith("GIT_"):
                self.env.pop(key)
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Moonlint Integration",
            "GIT_AUTHOR_EMAIL": "integration@example.invalid",
            "GIT_COMMITTER_NAME": "Moonlint Integration",
            "GIT_COMMITTER_EMAIL": "integration@example.invalid",
            "NO_COLOR": "1",
        })

    def cleanup_temp(self):
        # Resolve and check the exact owned directory before tempfile deletes it.
        resolved = Path(self.temp.name).resolve()
        assert resolved == self._owned_base, (resolved, self._owned_base)
        assert resolved.name.startswith("moonlint-integration-"), resolved
        assert resolved.parent == Path(tempfile.gettempdir()).resolve(), resolved
        self.temp.cleanup()

    def assert_owned(self, path):
        resolved = Path(path).resolve()
        self.assertTrue(resolved.is_relative_to(self._owned_base), repr(resolved))
        self.assertNotEqual(resolved, self._owned_base)
        return resolved

    def write_file(self, name, contents=TOKEN + "\n", *, root=None):
        path = (self.root if root is None else Path(root)) / name
        self.assert_owned(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def write_config(self, rules=None, **fields):
        self.assert_owned(self.config)
        payload = {"rules": [rule()] if rules is None else rules, **fields}
        self.config.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

    def run_cli(self, arguments, *, stdin=None, timeout=15):
        self.assertIsNotNone(BINARY)
        try:
            return subprocess.run(
                [str(BINARY), *map(str, arguments)],
                cwd=self.base,
                env=self.env,
                input=stdin,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            self.fail(f"CLI timed out after {timeout}s: {exc.cmd!r}")

    def invoke(self, *arguments, root=None, stdin=None, timeout=15):
        return self.run_cli(
            ["--config", self.config, *arguments, self.root if root is None else root],
            stdin=stdin,
            timeout=timeout,
        )

    @staticmethod
    def output(result):
        return (result.stdout + result.stderr).decode("utf-8", errors="replace")

    def assert_exit(self, result, expected):
        self.assertEqual(
            result.returncode,
            expected,
            f"expected exit {expected}, got {result.returncode}\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}",
        )

    def assert_findings(self, result, count, *, rule_id=RULE_ID):
        self.assert_exit(result, 1 if count else 0)
        self.assertEqual(
            self.output(result).count(rule_id), count,
            f"expected {count} detailed findings for {rule_id!r}\n{self.output(result)}",
        )

    def git(self, *arguments):
        if shutil.which("git") is None:
            self.skipTest("Git is required for Git integration cases")
        repo = self.assert_owned(self.root)
        self.assertEqual(repo, self.root)
        # git rm is the only command here which deletes fixture paths. Validate
        # each resolved target explicitly before allowing that deletion.
        if arguments and arguments[0] == "rm":
            self.assertIn("--", arguments)
            for name in arguments[arguments.index("--") + 1:]:
                target = self.assert_owned(repo / name)
                self.assertTrue(target.is_relative_to(repo), repr(target))
        result = subprocess.run(
            ["git", "-c", f"core.hooksPath={os.devnull}",
             "-c", "commit.gpgsign=false", "-C", str(repo), *arguments],
            cwd=self.base, env=self.env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=20, check=False,
        )
        self.assertEqual(
            result.returncode, 0,
            f"Git fixture setup failed: {arguments!r}\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}",
        )
        return result.stdout.decode("utf-8").strip()

    def init_git(self):
        self.git("init", "-q", "--initial-branch=main", "--template=")

    def commit(self, message="fixture"):
        self.git("add", "--", ".")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def baseline_entries(self):
        self.assertTrue(self.baseline.is_file(), "baseline file was not written")
        payload = json.loads(self.baseline.read_text(encoding="utf-8"))
        self.assertIsInstance(payload, list)
        self.assertTrue(all(isinstance(item, str) for item in payload))
        self.assertEqual(len(payload), len(set(payload)), "duplicate baseline entries")
        return payload


class RepairsTests(FixtureCase):
    def test_root_reports_a_real_error_finding(self):
        self.write_file("bad.ts")
        self.write_file("good.ts", "SAFE\n")
        result = self.invoke()
        self.assert_findings(result, 1)
        self.assertIn("bad.ts", self.output(result))

    def test_glob_double_star_zero_or_multiple_directories_and_question(self):
        for name in ("src/bad1.ts", "src/deep/bad2.ts", "src/deep/more/bad3.ts",
                     "src/bad12.ts", "outside.ts", "src/deep/bad4.js"):
            self.write_file(name)
        result = self.invoke("--glob", "src/**/bad?.ts")
        self.assert_findings(result, 3)
        for name in ("bad1.ts", "bad2.ts", "bad3.ts"):
            self.assertIn(name, self.output(result))
        self.assertNotIn("bad12.ts", self.output(result))
        self.assertNotIn("outside.ts", self.output(result))

    def test_glob_single_star_is_one_segment_and_repeated_globs_deduplicate(self):
        self.write_file("src/direct.ts")
        self.write_file("src/deep/nested.ts")
        self.write_file("other.ts")
        result = self.invoke("--glob", "src/*.ts", "--glob", "other.ts", "--glob", "src/direct.ts")
        self.assert_findings(result, 2)
        self.assertIn("other.ts", self.output(result))
        self.assertNotIn("nested.ts", self.output(result))

    def test_unsupported_glob_brace_and_class_are_rejected(self):
        self.write_file("bad.ts")
        for pattern in ("*.{ts,js}", "[ab]*.ts"):
            with self.subTest(pattern=pattern):
                result = self.invoke("--glob", pattern)
                self.assert_exit(result, 2)
                self.assertTrue(self.output(result).strip(), "missing glob diagnostic")

    def test_stdin_preserves_leading_trailing_and_internal_spaces(self):
        self.write_config([rule(extensions=[])])
        names = [" leading and trailing.ts ", "inside space.ts"]
        for name in names:
            self.write_file(name)
        self.write_file("unselected.ts")
        result = self.invoke("--stdin", stdin="\n".join(names).encode("utf-8"))
        self.assert_findings(result, 2)
        self.assertNotIn("unselected.ts", self.output(result))

    def test_stdin0_handles_unicode_quotes_newlines_and_dash_names(self):
        names = ["with spaces.ts", 'quo"ted.ts', "雪.ts", "new\nline.ts", "-dash.ts"]
        for name in names:
            self.write_file(name)
        self.write_file("unselected.ts")
        data = ("\0".join(names) + "\0").encode("utf-8")
        result = self.invoke("--stdin0", stdin=data)
        self.assert_findings(result, len(names))
        self.assertNotIn("unselected.ts", self.output(result))

    def test_stdin_duplicate_paths_are_scanned_once(self):
        self.write_file("dir/bad.ts")
        result = self.invoke("--stdin", stdin=b"dir/bad.ts\ndir/bad.ts\ndir/bad.ts\n")
        self.assert_findings(result, 1)

    def test_ext_filter_applies_to_root_glob_stdin_stdin0_staged_and_changed(self):
        self.write_config([rule(extensions=[".ts", ".js"])])
        self.init_git()
        self.write_file("anchor.txt", "SAFE\n")
        base = self.commit("base")
        self.write_file("bad.ts")
        self.write_file("bad.js")
        self.git("add", "--", ".")
        modes = [
            ([], None), (["--glob", "**/*"], None),
            (["--stdin"], b"bad.ts\nbad.js\n"),
            (["--stdin0"], b"bad.ts\0bad.js\0"), (["--staged"], None),
        ]
        for options, data in modes:
            with self.subTest(mode=options):
                result = self.invoke("--ext", ".ts", *options, stdin=data)
                self.assert_findings(result, 1)
                self.assertNotIn("bad.js", self.output(result))
        self.commit("changed")
        self.assert_findings(self.invoke("--ext", ".ts", "--changed", base), 1)

    def test_empty_rule_extensions_scan_all_regular_files(self):
        self.write_config([rule(extensions=[])])
        for name in ("no_extension", "odd.strange", "nested/file.ts"):
            self.write_file(name)
        self.assert_findings(self.invoke(), 3)

    def test_changed_reads_complete_head_blob_not_worktree_or_diff_lines(self):
        self.init_git()
        self.write_file("bad.ts", "FORBIDDEN\nconst value = 1;\n")
        base = self.commit("base")
        self.write_file("bad.ts", "FORBIDDEN\nconst value = 2;\n")
        self.commit("change safe line only")
        self.write_file("bad.ts", "SAFE WORKTREE\n")
        result = self.invoke("--changed", base)
        self.assert_findings(result, 1)
        self.assertIn("FORBIDDEN", self.output(result))

    def test_changed_clean_head_ignores_dirty_worktree(self):
        self.init_git()
        self.write_file("bad.ts")
        base = self.commit("base")
        self.write_file("bad.ts", "SAFE\n")
        self.commit("clean HEAD")
        self.write_file("bad.ts")
        self.assert_findings(self.invoke("--changed", base), 0)

    def test_staged_reads_dirty_index_despite_clean_worktree(self):
        self.init_git()
        self.write_file("bad.ts", "SAFE\n")
        self.commit("base")
        self.write_file("bad.ts")
        self.git("add", "--", "bad.ts")
        self.write_file("bad.ts", "SAFE WORKTREE\n")
        self.assert_findings(self.invoke("--staged"), 1)

    def test_staged_clean_index_ignores_dirty_worktree(self):
        self.init_git()
        self.write_file("bad.ts")
        self.commit("base")
        self.write_file("bad.ts", "SAFE INDEX\n")
        self.git("add", "--", "bad.ts")
        self.write_file("bad.ts")
        self.assert_findings(self.invoke("--staged"), 0)

    def test_changed_uses_pr_merge_base_not_direct_ref_diff(self):
        self.init_git()
        self.write_file("unchanged-on-pr.ts")
        self.commit("common base")
        self.git("checkout", "-q", "-b", "pr")
        self.write_file("pr.ts")
        self.commit("PR change")
        self.git("checkout", "-q", "main")
        self.write_file("unchanged-on-pr.ts", "SAFE ON MAIN\n")
        self.commit("main diverges")
        self.git("checkout", "-q", "pr")
        result = self.invoke("--changed", "main")
        self.assert_findings(result, 1)
        self.assertIn("pr.ts", self.output(result))
        self.assertNotIn("unchanged-on-pr.ts", self.output(result))

    def test_git_nul_names_subdir_root_and_deletions_in_both_modes(self):
        self.init_git()
        subroot = self.root / "packages" / "kit"
        self.write_file("removed.ts", root=subroot)
        base = self.commit("base")
        self.git("rm", "--", "packages/kit/removed.ts")
        names = ["with space.ts", 'quo"ted.ts', "雪.ts", "new\nline.ts"]
        for name in names:
            self.write_file(name, root=subroot)
        self.write_file("outside.ts")
        self.git("add", "--", ".")
        with self.subTest(mode="staged"):
            self.assert_findings(self.invoke("--staged", root=subroot), len(names))
        self.commit("special names and deletion")
        with self.subTest(mode="changed"):
            self.assert_findings(self.invoke("--changed", base, root=subroot), len(names))

    def test_git_failures_are_exit_two_not_empty_success(self):
        with self.subTest(mode="staged outside repository"):
            self.assert_exit(self.invoke("--staged"), 2)
        self.init_git()
        self.write_file("anchor.txt", "SAFE\n")
        self.commit()
        with self.subTest(mode="unknown ref"):
            self.assert_exit(self.invoke("--changed", "missing-ref-does-not-exist"), 2)

    def test_unknown_missing_and_conflicting_arguments_are_usage_errors(self):
        cases = [
            ["--unknown-flag", self.root], ["--config"], ["--baseline"],
            ["--changed"], ["--glob"], ["--ext"],
            ["--staged", "--stdin", self.root],
            ["--staged", "--changed", "HEAD", self.root],
            ["--glob", "*.ts", "--stdin", self.root],
            ["--stdin", "--stdin0", self.root], [self.root, self.root],
        ]
        for options in cases:
            with self.subTest(arguments=options):
                result = self.run_cli(["--config", self.config, *options], stdin=b"")
                self.assert_exit(result, 2)
                self.assertTrue(self.output(result).strip(), "missing usage diagnostic")

    def test_incremental_and_watch_explicitly_report_unsupported(self):
        for option in ("--incremental", "--watch"):
            with self.subTest(option=option):
                result = self.invoke(option)
                self.assert_exit(result, 2)
                self.assertIn("unsupported", self.output(result).lower())

    def test_symlink_file_and_directory_loop_are_skipped(self):
        outside = self.write_file("outside.ts", root=self.base)
        try:
            (self.root / "external.ts").symlink_to(outside)
            (self.root / "loop").symlink_to(self.root, target_is_directory=True)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlinks unavailable: {exc}")
        self.write_file("good.ts", "SAFE\n")
        self.assert_findings(self.invoke(timeout=10), 0)

    def test_stdin_parent_escape_is_rejected_in_line_and_nul_modes(self):
        self.write_file("outside.ts", root=self.base)
        for mode, data in (("--stdin", b"../outside.ts\n"),
                           ("--stdin0", b"../outside.ts\0")):
            with self.subTest(mode=mode):
                self.assert_exit(self.invoke(mode, stdin=data), 2)

    def test_missing_root_and_missing_selected_file_are_io_errors(self):
        with self.subTest(case="missing root"):
            self.assert_exit(self.invoke(root=self.base / "does-not-exist"), 2)
        with self.subTest(case="missing stdin file"):
            self.assert_exit(self.invoke("--stdin", stdin=b"does-not-exist.ts\n"), 2)

    def test_unreadable_selected_file_is_an_io_error(self):
        path = self.write_file("unreadable.ts")
        self.assert_owned(path)
        path.chmod(0)
        try:
            if os.access(path, os.R_OK):
                self.skipTest("current account can read permission-denied fixtures")
            self.assert_exit(self.invoke("--stdin", stdin=b"unreadable.ts\n"), 2)
        finally:
            self.assert_owned(path)
            path.chmod(0o600)

    def test_unreadable_root_directory_is_an_io_error(self):
        self.write_file("bad.ts")
        self.assert_owned(self.root)
        self.root.chmod(0)
        try:
            if os.access(self.root, os.R_OK | os.X_OK):
                self.skipTest("current account can scan permission-denied directories")
            self.assert_exit(self.invoke(), 2)
        finally:
            self.assert_owned(self.root)
            self.root.chmod(0o700)

    def test_stdin_absolute_external_path_is_rejected(self):
        outside = self.write_file("outside.ts", root=self.base)
        self.assert_exit(self.invoke("--stdin0", stdin=str(outside).encode("utf-8") + b"\0"), 2)

    def test_baseline_update_is_idempotent_and_preserves_existing_raw_findings(self):
        self.write_file("first.ts")
        self.write_file("second.ts")
        self.assert_exit(self.invoke("--baseline", self.baseline, "--update-baseline"), 0)
        entries = self.baseline_entries()
        self.assertEqual(len(entries), 2)
        before = self.baseline.read_bytes()
        self.assert_exit(self.invoke("--baseline", self.baseline, "--update-baseline"), 0)
        self.assertEqual(self.baseline.read_bytes(), before)
        self.assertEqual(self.baseline_entries(), entries)
        self.assert_findings(self.invoke("--baseline", self.baseline), 0)

    def test_baseline_full_refresh_adds_new_entries_and_clears_stale_entries(self):
        self.write_file("first.ts")
        self.assert_exit(self.invoke("--baseline", self.baseline, "--update-baseline"), 0)
        first = set(self.baseline_entries())
        self.write_file("second.ts")
        self.assert_exit(self.invoke("--baseline", self.baseline, "--update-baseline"), 0)
        refreshed = set(self.baseline_entries())
        self.assertEqual(len(refreshed), 2)
        self.assertTrue(first.issubset(refreshed))
        self.write_file("first.ts", "SAFE\n")
        self.write_file("second.ts", "SAFE\n")
        self.assert_exit(self.invoke("--baseline", self.baseline, "--update-baseline"), 0)
        self.assertEqual(self.baseline_entries(), [])

    def test_baseline_update_uses_raw_findings_even_with_errors_only(self):
        self.write_config([
            rule(), rule(rule_id="test/warning", severity="warning", token="WARNING_TOKEN"),
        ])
        self.write_file("bad.ts", "FORBIDDEN\nWARNING_TOKEN\n")
        result = self.invoke("--baseline", self.baseline, "--update-baseline", "--errors-only")
        self.assert_exit(result, 0)
        self.assertEqual(len(self.baseline_entries()), 2)

    def test_partial_baseline_updates_are_rejected_without_rewriting(self):
        self.init_git()
        self.write_file("bad.ts")
        self.commit()
        self.baseline.write_text('["preserve-me"]\n', encoding="utf-8")
        before = self.baseline.read_bytes()
        cases = [(["--glob", "**/*.ts"], None), (["--stdin"], b"bad.ts\n"),
                 (["--stdin0"], b"bad.ts\0"), (["--staged"], None),
                 (["--changed", "HEAD"], None)]
        for options, data in cases:
            with self.subTest(mode=options):
                result = self.invoke("--baseline", self.baseline, "--update-baseline",
                                     *options, stdin=data)
                self.assert_exit(result, 2)
                self.assertEqual(self.baseline.read_bytes(), before)

    def test_baseline_write_failure_is_exit_two(self):
        self.write_file("bad.ts")
        occupied_parent = self.write_file("occupied-parent", "not a directory", root=self.base)
        impossible = occupied_parent / "baseline.json"
        self.assert_exit(self.invoke("--baseline", impossible, "--update-baseline"), 2)

    def test_invalid_config_and_malformed_baseline_are_exit_two(self):
        self.write_file("bad.ts")
        self.baseline.write_text("{not valid json", encoding="utf-8")
        with self.subTest(case="malformed baseline"):
            self.assert_exit(self.invoke("--baseline", self.baseline), 2)
        self.config.write_text("{not valid json", encoding="utf-8")
        with self.subTest(case="malformed config"):
            self.assert_exit(self.invoke(), 2)
        with self.subTest(case="missing config"):
            self.assert_exit(self.run_cli(["--config", self.base / "missing.json", self.root]), 2)

    def test_fixed_noise_directories_are_skipped_even_for_all_regular_rules(self):
        self.write_config([rule(extensions=[])])
        for name in (".git/noise.ts", "node_modules/noise.ts", "_build/noise.ts"):
            self.write_file(name)
        self.write_file("good.ts", "SAFE\n")
        self.assert_findings(self.invoke(), 0)


PHASES = {"repairs": RepairsTests}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True,
                        help="absolute path to an existing native moonlint executable")
    parser.add_argument("--phase", choices=("repairs", "scope", "output", "all"), default="all")
    parser.add_argument("-q", "--quiet", action="store_true")
    args = parser.parse_args(argv)
    binary = Path(args.binary)
    if not binary.is_absolute():
        parser.error("--binary must be an absolute path")
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("--binary must identify an existing executable file")
    global BINARY
    BINARY = binary.resolve()
    selected = list(PHASES) if args.phase == "all" else [args.phase]
    for phase in selected:
        if phase not in PHASES:
            parser.error(f"phase {phase!r} has no tests yet; use --phase repairs")
    if args.phase == "all" and len(PHASES) < 3:
        print("Note: scope/output tests pending; all currently runs repairs only.", file=sys.stderr)
    suite = unittest.TestSuite(
        unittest.defaultTestLoader.loadTestsFromTestCase(PHASES[phase])
        for phase in selected
    )
    result = unittest.TextTestRunner(verbosity=1 if args.quiet else 2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
