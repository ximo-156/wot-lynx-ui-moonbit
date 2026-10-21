#!/usr/bin/env python3
"""Dependency-free moonlint CLI integration tests.

Run: python3 tests/integration.py --binary /absolute/path/to/moonlint --phase all
The runner never builds moonlint. Fixtures, configs, baselines, and Git repositories
are exclusively inside independently owned tempfile.TemporaryDirectory instances.
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
import uuid


BINARY: Path | None = None
RULE_ID = "test/forbidden"
TOKEN = "FORBIDDEN"


def rule(*, rule_id=RULE_ID, severity="error", extensions=None, token=TOKEN,
         include=None, exclude=None):
    payload = {
        "id": rule_id,
        "severity": severity,
        "message": "Forbidden fixture token",
        "extensions": [".ts"] if extensions is None else extensions,
        "match": {"contains": token},
    }
    if include is not None:
        payload["include"] = include
    if exclude is not None:
        payload["exclude"] = exclude
    return payload


def scoped_config(*, include=None, exclude=None, rules=None):
    """A config carrying a global scope and the given rules."""
    payload = {"rules": [rule()] if rules is None else rules}
    if include is not None:
        payload["include"] = include
    if exclude is not None:
        payload["exclude"] = exclude
    return payload


class FixtureCase(unittest.TestCase):
    """Own every filesystem mutation; isolate CLI and Git from the real checkout."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=f"moonlint-{uuid.uuid4().hex[:8]}-")
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
        assert resolved.name.startswith("moonlint-"), resolved
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
        # Count detail lines ("file:line: [severity] rule — message") rather than
        # raw substring hits, because a temporary directory name can itself
        # contain the rule id.
        marker = f"] {rule_id} — "
        reported = [line for line in self.output(result).splitlines() if marker in line]
        self.assertEqual(
            len(reported), count,
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

    def test_unreadable_subdirectory_is_an_io_error_not_a_silent_empty_scan(self):
        self.write_file("ok/good.ts")
        locked = self.write_file("locked/bad.ts").parent
        self.assert_owned(locked)
        locked.chmod(0)
        try:
            if os.access(locked, os.R_OK | os.X_OK):
                self.skipTest("current account can read permission-denied directories")
            self.assert_exit(self.invoke(), 2)
        finally:
            self.assert_owned(locked)
            locked.chmod(0o700)

    def test_empty_glob_and_empty_stdin_scans_report_no_selection(self):
        self.write_file("present.ts")
        cases = [
            (["--glob", "nomatch/**"], None),
            (["--stdin"], b""),
            (["--stdin"], b"\n\n"),
            (["--stdin0"], b"\0"),
        ]
        for options, data in cases:
            with self.subTest(mode=options, stdin=data):
                result = self.invoke(*options, stdin=data)
                # An empty selection is a clean result, but it is announced so a
                # mistyped mode cannot look like a passing lint.
                self.assert_exit(result, 0)
                self.assertIn("no files selected", self.output(result))

    def test_empty_glob_and_empty_stdin_in_json_report_zero_counters(self):
        self.write_file("present.ts")
        for options, data in ((["--glob", "nomatch/**"], None),
                              (["--stdin"], b""), (["--stdin0"], b"\0")):
            with self.subTest(mode=options):
                result = self.invoke("--format", "json", *options, stdin=data)
                self.assert_exit(result, 0)
                scan = json.loads(self.output(result))["scan"]
                self.assertEqual(scan["files_selected"], 0)
                self.assertEqual(scan["files_scanned"], 0)
                self.assertEqual(scan["files_skipped"], 0)
                self.assertEqual(scan["files_failed"], 0)

    def test_stdin_rejects_embedded_nul_in_line_mode(self):
        self.write_file("bad.ts")
        result = self.invoke("--stdin", stdin=b"bad.ts\0other.ts\n")
        self.assert_exit(result, 2)
        self.assertIn("stdin0", self.output(result))


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


class ScopeTests(FixtureCase):
    """Global and rule-level include/exclude scope configuration."""

    def test_scope_pattern_documents_every_supported_form(self):
        self.write_config(include=["**"], exclude=["**/*.md", "docs", "src/generated"])
        for name in ("src/bad.ts", "docs/bad.ts", "src/generated/bad.ts",
                     "notes/bad.md", "deep/nested/bad.ts"):
            self.write_file(name)
        result = self.invoke()
        self.assert_findings(result, 2)
        output = self.output(result)
        self.assertIn("src/bad.ts", output)
        self.assertIn("deep/nested/bad.ts", output)
        for excluded in ("docs/bad.ts", "src/generated/bad.ts", "notes/bad.md"):
            self.assertNotIn(excluded, output)

    def test_global_include_restricts_the_scanned_files(self):
        self.write_config(include=["src/**"])
        self.write_file("src/bad.ts")
        self.write_file("lib/bad.ts")
        result = self.invoke()
        self.assert_findings(result, 1)
        self.assertIn("src/bad.ts", self.output(result))
        self.assertNotIn("lib/bad.ts", self.output(result))

    def test_global_include_accepts_a_leading_dot_slash(self):
        self.write_config(include=["./src/**"])
        self.write_file("src/bad.ts")
        self.write_file("lib/bad.ts")
        result = self.invoke()
        self.assert_findings(result, 1)
        self.assertNotIn("lib/bad.ts", self.output(result))

    def test_global_exclude_removes_a_whole_directory(self):
        self.write_config(exclude=["vendor"])
        self.write_file("vendor/pkg/bad.ts")
        self.write_file("vendorless/bad.ts")
        self.write_file("src/bad.ts")
        result = self.invoke()
        self.assert_findings(result, 2)
        self.assertNotIn("vendor/pkg/bad.ts", self.output(result))
        self.assertIn("vendorless/bad.ts", self.output(result))
        self.assertIn("src/bad.ts", self.output(result))

    def test_global_exclude_wins_over_include(self):
        self.write_config(include=["src/**"], exclude=["src/legacy/**"])
        self.write_file("src/bad.ts")
        self.write_file("src/legacy/bad.ts")
        result = self.invoke()
        self.assert_findings(result, 1)
        self.assertIn("src/bad.ts", self.output(result))
        self.assertNotIn("src/legacy/bad.ts", self.output(result))

    def test_rule_include_limits_a_rule_to_its_subtree(self):
        self.write_config(rules=[
            rule(rule_id="test/all"),
            rule(rule_id="test/scoped", include=["src/**"]),
        ])
        self.write_file("src/bad.ts")
        self.write_file("lib/bad.ts")
        result = self.invoke()
        # The unscoped rule fires twice, the scoped rule only inside src/.
        self.assertEqual(self.output(result).count("test/all"), 2)
        self.assertEqual(self.output(result).count("test/scoped"), 1)

    def test_rule_exclude_exempts_a_subtree_from_a_rule(self):
        self.write_config(rules=[
            rule(rule_id="test/all"),
            rule(rule_id="test/except-legacy", exclude=["src/legacy/**"]),
        ])
        self.write_file("src/bad.ts")
        self.write_file("src/legacy/bad.ts")
        result = self.invoke()
        self.assertEqual(self.output(result).count("test/all"), 2)
        self.assertEqual(self.output(result).count("test/except-legacy"), 1)

    def test_scope_applies_to_every_scan_mode(self):
        self.write_config(include=["src/**"])
        self.write_file("src/bad.ts")
        self.write_file("lib/bad.ts")
        self.init_git()
        self.git("add", "--", ".")
        modes = [
            ([], None), (["--glob", "**/*"], None),
            (["--stdin"], b"src/bad.ts\nlib/bad.ts\n"),
            (["--stdin0"], b"src/bad.ts\0lib/bad.ts\0"),
            (["--staged"], None),
        ]
        for options, data in modes:
            with self.subTest(mode=options):
                result = self.invoke(*options, stdin=data)
                self.assert_findings(result, 1)
                self.assertNotIn("lib/bad.ts", self.output(result))

    def test_scope_applies_to_changed_mode(self):
        self.write_config(include=["src/**"])
        self.init_git()
        self.write_file("src/bad.ts")
        self.write_file("lib/bad.ts")
        # The base must differ, or Git records no change and the PR diff is empty.
        self.write_file("src/bad.ts", "SAFE\n")
        self.write_file("lib/bad.ts", "SAFE\n")
        base = self.commit("base")
        self.write_file("src/bad.ts", "FORBIDDEN\n")
        self.write_file("lib/bad.ts", "FORBIDDEN\n")
        self.commit("changed")
        result = self.invoke("--changed", base)
        self.assert_findings(result, 1)
        self.assertNotIn("lib/bad.ts", self.output(result))

    def test_scope_excluded_files_are_not_read(self):
        self.write_config(include=["src/**"], rules=[rule(extensions=[])])
        self.write_file("src/bad.ts")
        self.write_file("lib/bad.ts")
        result = self.invoke("--summary")
        self.assert_exit(result, 1)
        self.assertIn("files selected: 1", self.output(result))

    def test_global_scope_counters_are_reported(self):
        self.write_config(include=["src/**"])
        self.write_file("src/bad.ts")
        self.write_file("lib/bad.ts")
        self.write_file("docs/bad.ts")
        scan = json.loads(self.output(self.invoke("--format", "json")))["scan"]
        self.assertEqual(scan["files_selected"], 1)
        self.assertEqual(scan["files_out_of_scope"], 2)

    def test_global_scope_keeps_a_cleaner_target_clean(self):
        # A file excluded by scope must not turn a clean run red.
        self.write_config(include=["src/**"])
        self.write_file("src/good.ts", "SAFE\n")
        self.write_file("legacy/bad.ts", "FORBIDDEN\n")
        self.assert_exit(self.invoke(), 0)

    def test_rule_scope_override_can_exclude_every_file_for_one_rule(self):
        self.write_config([
            rule(rule_id="test/all"),
            rule(rule_id="test/never", exclude=["**"]),
        ])
        self.write_file("src/bad.ts")
        output = self.output(self.invoke())
        self.assertEqual(output.count("] test/all — "), 1)
        self.assertNotIn("test/never", output)

    def test_rule_scope_does_not_widen_the_global_scan_set(self):
        # The rule include names src/**, but global include restricts to lib/**.
        # Only lib files are scanned, so the src-only rule never runs.
        self.write_config(include=["lib/**"],
                          rules=[rule(rule_id="test/src-only", include=["src/**"])])
        self.write_file("src/bad.ts")
        self.write_file("lib/bad.ts")
        result = self.invoke()
        self.assert_exit(result, 0)
        self.assertNotIn("src/bad.ts", self.output(result))

    def test_rule_scope_excludes_a_suffix_pattern(self):
        self.write_config([
            rule(rule_id="test/all"),
            rule(rule_id="test/no-tests", exclude=["**/*.test.ts"]),
        ])
        self.write_file("src/bad.ts")
        self.write_file("src/bad.test.ts")
        output = self.output(self.invoke())
        self.assertEqual(output.count("] test/all — "), 2)
        self.assertEqual(output.count("] test/no-tests — "), 1)

    def test_rule_scope_without_a_match_counts_the_file_as_skipped(self):
        self.write_config(rules=[rule(exclude=["**"])])
        self.write_file("src/bad.ts")
        payload = json.loads(self.output(self.invoke("--format", "json")))
        scan = payload["scan"]
        self.assertEqual(scan["files_selected"], 1)
        self.assertEqual(scan["files_scanned"], 0)
        self.assertEqual(scan["files_skipped"], 1)
        self.assertEqual(scan["skipped_files"],
                         [{"file": "src/bad.ts", "reason": "no-applicable-rule"}])

    def test_invalid_scope_pattern_is_a_config_error(self):
        for pattern in ("src/{a,b}", "src/[ab].ts", "/absolute/path", "src/../escape"):
            with self.subTest(pattern=pattern):
                self.write_config(include=[pattern])
                self.write_file("bad.ts")
                result = self.invoke()
                self.assert_exit(result, 2)
                self.assertTrue(self.output(result).strip(), "missing scope diagnostic")

    def test_malformed_scope_list_is_a_config_error(self):
        for payload in ({"include": "src/**"}, {"exclude": [1, 2]}):
            with self.subTest(payload=payload):
                self.write_config(**payload)
                self.write_file("bad.ts")
                self.assert_exit(self.invoke(), 2)

    def test_invalid_rule_scope_pattern_is_a_config_error(self):
        self.write_config(rules=[rule(include=["src/{a,b}"])])
        self.write_file("bad.ts")
        self.assert_exit(self.invoke(), 2)


class OutputTests(FixtureCase):
    """JSON reports, GitHub annotations and scan metadata."""

    def json_report(self, result):
        payload = json.loads(self.output(result))
        self.assertEqual(payload["tool"], "moonlint")
        self.assertEqual(payload["version"], 1)
        return payload

    def test_json_format_emits_a_machine_readable_report(self):
        self.write_file("src/bad.ts", "FORBIDDEN\n")
        result = self.invoke("--format", "json")
        self.assert_exit(result, 1)
        payload = self.json_report(result)
        self.assertEqual(payload["scan"]["mode"], "tree")
        self.assertEqual(len(payload["findings"]), 1)
        finding = payload["findings"][0]
        self.assertEqual(finding["rule_id"], RULE_ID)
        self.assertEqual(finding["severity"], "error")
        self.assertEqual(finding["file"], "src/bad.ts")
        self.assertEqual(finding["line"], 1)
        self.assertEqual(finding["column"], 1)
        self.assertEqual(payload["counts"]["errors"], 1)

    def test_json_report_carries_read_failure_and_skip_metadata(self):
        self.write_config([rule(extensions=[])])
        self.write_file("src/bad.ts", "FORBIDDEN\n")
        self.write_file("src/notes.md", "FORBIDDEN\n")
        result = self.invoke("--format", "json")
        self.assert_exit(result, 1)
        scan = self.json_report(result)["scan"]
        self.assertEqual(scan["files_selected"], 2)
        self.assertEqual(scan["files_scanned"], 2)
        self.assertEqual(scan["files_skipped"], 0)
        self.assertEqual(scan["files_failed"], 0)
        self.assertEqual(scan["files_out_of_scope"], 0)
        self.assertEqual(scan["skipped_files"], [])

    def test_json_report_records_skipped_files_with_a_reason(self):
        # A multi-rule config widens the scan set to the union of rule
        # extensions, so the .md candidate is selected and then skipped because
        # no rule claims .md. (A lone ".ts" rule narrows the scan to .ts files,
        # which the extension-filter test above covers.)
        self.write_config([
            rule(extensions=[".ts"]),
            rule(rule_id="test/md", extensions=[".ts", ".md"]),
        ])
        self.write_file("src/bad.ts", "FORBIDDEN\n")
        self.write_file("src/notes.md", "FORBIDDEN\n")
        result = self.invoke("--format", "json")
        self.assert_exit(result, 1)
        scan = self.json_report(result)["scan"]
        self.assertEqual(scan["files_selected"], 2)
        self.assertEqual(scan["files_scanned"], 2)
        self.assertEqual(scan["files_skipped"], 0)
        self.assertEqual(scan["skipped_files"], [])

    def test_json_report_records_failed_reads_as_diagnostics(self):
        self.write_file("bad.ts")
        result = self.invoke("--format", "json", "--stdin", stdin=b"missing.ts\n")
        self.assert_exit(result, 2)
        payload = self.json_report(result)
        self.assertEqual(payload["scan"]["files_failed"], 1)
        self.assertEqual(len(payload["diagnostics"]), 1)
        self.assertEqual(payload["diagnostics"][0]["file"], "missing.ts")
        self.assertTrue(payload["diagnostics"][0]["message"])

    def test_json_report_counts_scope_excluded_files(self):
        self.write_config(include=["src/**"])
        self.write_file("src/bad.ts")
        self.write_file("lib/bad.ts")
        result = self.invoke("--format", "json")
        self.assert_exit(result, 1)
        scan = self.json_report(result)["scan"]
        self.assertEqual(scan["files_selected"], 1)
        self.assertEqual(scan["files_out_of_scope"], 1)

    def test_github_format_emits_workflow_command_annotations(self):
        self.write_file("src/bad.ts", "FORBIDDEN\n")
        result = self.invoke("--format", "github")
        self.assert_exit(result, 1)
        output = self.output(result)
        self.assertIn("::error file=src/bad.ts,line=1,col=1,title=" + RULE_ID + "::", output)
        self.assertIn("::notice title=moonlint::", output)

    def test_github_format_escapes_property_and_message_values(self):
        self.write_file("a,b.ts", "FORBIDDEN\n")
        result = self.invoke("--format", "github")
        self.assert_exit(result, 1)
        self.assertIn("file=a%2Cb.ts", self.output(result))

    def test_github_format_annotates_scan_failures(self):
        result = self.invoke("--format", "github", "--stdin", stdin=b"missing.ts\n")
        self.assert_exit(result, 2)
        self.assertIn("::error file=missing.ts,title=moonlint/scan-failed::", self.output(result))

    def test_report_option_writes_the_json_report_to_a_file(self):
        self.write_file("src/bad.ts", "FORBIDDEN\n")
        report = self.base / "report.json"
        result = self.invoke("--report", report)
        self.assert_exit(result, 1)
        self.assertTrue(report.is_file(), "report file was not written")
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(len(payload["findings"]), 1)
        self.assertEqual(payload["findings"][0]["file"], "src/bad.ts")
        # The human-readable report still goes to stdout.
        self.assertIn(RULE_ID, self.output(result))

    def test_report_option_is_written_next_to_the_json_format(self):
        self.write_file("src/bad.ts", "FORBIDDEN\n")
        report = self.base / "report.json"
        result = self.invoke("--format", "json", "--report", report)
        self.assert_exit(result, 1)
        self.assertEqual(json.loads(self.output(result))["tool"], "moonlint")
        self.assertEqual(json.loads(report.read_text(encoding="utf-8"))["tool"], "moonlint")

    def test_report_option_failure_is_exit_two(self):
        self.write_file("bad.ts")
        occupied = self.write_file("occupied", "not a directory", root=self.base)
        result = self.invoke("--report", occupied / "report.json")
        self.assert_exit(result, 2)

    def test_errors_only_filters_json_findings_and_counts(self):
        self.write_config([
            rule(), rule(rule_id="test/warning", severity="warning", token="WARNING_TOKEN"),
        ])
        self.write_file("bad.ts", "FORBIDDEN\nWARNING_TOKEN\n")
        result = self.invoke("--format", "json", "--errors-only")
        self.assert_exit(result, 1)
        payload = self.json_report(result)
        self.assertEqual(len(payload["findings"]), 1)
        self.assertEqual(payload["findings"][0]["severity"], "error")
        self.assertEqual(payload["counts"]["findings"], 1)
        self.assertEqual(payload["counts"]["warnings"], 0)

    def test_unknown_format_is_a_usage_error(self):
        self.write_file("bad.ts")
        for value in ("yaml", "TEXT", ""):
            with self.subTest(format=value):
                result = self.invoke("--format", value)
                self.assert_exit(result, 2)
                self.assertTrue(self.output(result).strip(), "missing usage diagnostic")

    def test_missing_format_value_is_a_usage_error(self):
        result = self.run_cli(["--config", self.config, "--format"])
        self.assert_exit(result, 2)
        self.assertTrue(self.output(result).strip(), "missing usage diagnostic")

    def test_json_report_declares_all_scan_counters(self):
        self.write_file("src/bad.ts", "FORBIDDEN\n")
        scan = self.json_report(self.invoke("--format", "json"))["scan"]
        for key in ("files_selected", "files_scanned", "files_skipped", "files_failed",
                    "files_out_of_scope", "baseline_suppressed"):
            with self.subTest(counter=key):
                self.assertIsInstance(scan[key], int)
        self.assertEqual(scan["extensions"], [".ts"])
        self.assertEqual(scan["mode"], "tree")
        self.assertTrue(os.path.isabs(scan["root"]))

    def test_json_report_counts_baseline_suppressed_findings(self):
        self.write_file("bad.ts")
        self.invoke("--baseline", self.baseline, "--update-baseline")
        scan = self.json_report(self.invoke("--format", "json", "--baseline", self.baseline))["scan"]
        self.assertEqual(scan["baseline_suppressed"], 1)

    def test_json_report_reflects_the_scan_mode(self):
        self.write_file("bad.ts")
        self.init_git()
        self.git("add", "--", ".")
        cases = [(["--glob", "*.ts"], None), (["--stdin"], b"bad.ts\n"),
                 (["--stdin0"], b"bad.ts\0"), (["--staged"], None)]
        for options, data in cases:
            with self.subTest(mode=options):
                result = self.invoke("--format", "json", *options, stdin=data)
                self.assert_exit(result, 1)
                scan = self.json_report(result)["scan"]
                self.assertEqual(scan["mode"], options[0].lstrip("-"))

    def test_report_file_is_written_even_when_the_scan_fails(self):
        self.write_file("bad.ts")
        report = self.base / "report.json"
        result = self.invoke("--report", report, "--stdin", stdin=b"missing.ts\n")
        self.assert_exit(result, 2)
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(payload["scan"]["files_failed"], 1)
        self.assertEqual(payload["diagnostics"][0]["file"], "missing.ts")

    def test_github_format_annotates_skipped_files(self):
        # The .md candidate joins the scan set through the second rule's
        # extensions, but that rule's scope rejects it, so no rule applies.
        self.write_config([
            rule(extensions=[".ts"]),
            rule(rule_id="test/docs", extensions=[".md"], include=["docs/**"]),
        ])
        self.write_file("note.md", "FORBIDDEN\n")
        output = self.output(self.invoke("--format", "github"))
        self.assertIn("::notice file=note.md,title=moonlint/skipped::no-applicable-rule",
                      output)
        self.assertIn("::notice title=moonlint::", output)

    def test_github_format_uses_warning_severity(self):
        self.write_config([rule(severity="warning")])
        self.write_file("bad.ts")
        result = self.invoke("--format", "github")
        self.assert_exit(result, 0)
        self.assertIn("::warning file=bad.ts,line=1,col=1,title=" + RULE_ID + "::",
                      self.output(result))

    def test_github_format_escapes_newlines_into_a_single_line(self):
        self.write_config([rule()])
        self.write_file("bad.ts", "FORBIDDEN\n")
        # A rule message containing a newline must not forge a second command.
        self.config.write_text(json.dumps({"rules": [{
            "id": RULE_ID, "severity": "error",
            "message": "line one\n::error forged::x",
            "extensions": [".ts"], "match": {"contains": TOKEN},
        }]}), encoding="utf-8")
        lines = [line for line in self.output(self.invoke("--format", "github")).splitlines()
                 if line.startswith("::")]
        self.assertEqual(len(lines), 2)  # one finding annotation, one summary
        self.assertIn("%0A", lines[0])

    def test_github_summary_counts_skipped_and_failed(self):
        self.write_config([
            rule(extensions=[".ts"]),
            rule(rule_id="test/docs", extensions=[".md"], include=["docs/**"]),
        ])
        self.write_file("note.md", "FORBIDDEN\n")
        output = self.output(self.invoke("--format", "github", "--stdin",
                                         stdin=b"note.md\nmissing.ts\n"))
        self.assertIn("skipped: 1", output)
        self.assertIn("failed: 1", output)

    def test_json_format_of_a_clean_tree_reports_no_findings(self):
        self.write_file("good.ts", "SAFE\n")
        result = self.invoke("--format", "json")
        self.assert_exit(result, 0)
        payload = self.json_report(result)
        self.assertEqual(payload["findings"], [])
        self.assertEqual(payload["counts"]["findings"], 0)


class GitSafetyTests(FixtureCase):
    """Git failures, option injection, PR baselines and true staged content."""

    def test_git_options_in_a_reference_are_not_interpreted(self):
        self.init_git()
        self.write_file("bad.ts")
        self.commit()
        for ref in ("--output=/tmp/moonlint-should-not-exist", "-x", "--help"):
            with self.subTest(ref=ref):
                self.assert_exit(self.invoke("--changed", ref), 2)
                self.assertFalse(Path("/tmp/moonlint-should-not-exist").exists())

    def test_staged_rejects_an_unmerged_index(self):
        self.init_git()
        self.write_file("conflict.ts", "SAFE\n")
        base = self.commit("base")
        self.git("checkout", "-q", "-b", "other")
        self.write_file("conflict.ts", "FORBIDDEN\n")
        self.commit("other")
        self.git("checkout", "-q", "main")
        self.write_file("conflict.ts", "SAFE AGAIN\n")
        self.commit("main")
        # Create a real conflict in the index without committing it.
        merge = subprocess.run(
            ["git", "-c", f"core.hooksPath={os.devnull}", "-C", str(self.root),
             "merge", "--no-commit", "other"],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        self.assertNotEqual(merge.returncode, 0, "fixture merge unexpectedly succeeded")
        self.assertNotEqual(base, "")
        result = self.invoke("--staged")
        self.assert_exit(result, 2)
        self.assertIn("unmerged", self.output(result).lower())

    def test_staged_reports_git_symlink_as_skipped_not_read(self):
        self.init_git()
        self.write_file("anchor.txt", "SAFE\n")
        self.commit("base")
        target = self.write_file("real.ts", "SAFE\n")
        link = self.root / "link.ts"
        try:
            link.symlink_to(target)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlinks unavailable: {exc}")
        self.git("add", "--", "link.ts")
        result = self.invoke("--staged", "--format", "json")
        self.assert_exit(result, 0)
        scan = json.loads(self.output(result))["scan"]
        self.assertIn({"file": "link.ts", "reason": "not-a-regular-file"},
                      scan["skipped_files"])

    def test_pr_baseline_reads_head_blobs_not_the_worktree(self):
        self.init_git()
        self.write_file("bad.ts", "SAFE\n")
        base = self.commit("base")
        # HEAD gains a violation, then the worktree is cleaned up again.
        self.write_file("bad.ts", "FORBIDDEN\n")
        self.commit("PR introduces a violation")
        self.write_file("bad.ts", "SAFE WORKTREE\n")
        result = self.invoke("--changed", base)
        self.assert_findings(result, 1)
        self.assertIn("FORBIDDEN", self.output(result))

    def test_renamed_file_is_scanned_as_its_new_path(self):
        self.init_git()
        self.write_file("old.ts", "SAFE\n")
        base = self.commit("base")
        self.git("mv", "--", "old.ts", "renamed.ts")
        self.write_file("renamed.ts", "FORBIDDEN\n")
        self.git("add", "--", ".")
        self.commit("rename and violate")
        result = self.invoke("--changed", base)
        self.assert_findings(result, 1)
        self.assertIn("renamed.ts", self.output(result))
        self.assertNotIn("old.ts:", self.output(result))

    def test_repository_outside_the_scan_root_has_no_git_candidates(self):
        self.init_git()
        self.write_file("bad.ts", "SAFE\n")
        self.commit("base")
        self.write_file("bad.ts", "FORBIDDEN\n")
        self.commit("changed")
        untracked = self.base / "loose"
        untracked.mkdir()
        (untracked / "bad.ts").write_text("FORBIDDEN\n", encoding="utf-8")
        self.assert_owned(untracked / "bad.ts")
        result = self.invoke("--staged", root=untracked)
        self.assert_exit(result, 2)
        self.assertTrue(self.output(result).strip(), "missing Git diagnostic")


class PresetTests(FixtureCase):
    """Built-in framework preset CLI behavior."""

    def test_list_presets_shows_all_presets(self):
        result = self.run_cli(["--list-presets"])
        self.assert_exit(result, 0)
        output = self.output(result)
        for name in ("angular", "astro", "common", "file", "next",
                     "nuxt", "react", "solid", "svelte", "vue"):
            self.assertIn(name, output)

    def test_list_presets_is_sorted(self):
        result = self.run_cli(["--list-presets"])
        self.assert_exit(result, 0)
        lines = [line for line in self.output(result).splitlines() if line.strip()]
        self.assertEqual(len(lines), 10)
        names = [line.split(" ")[0] for line in lines]
        self.assertEqual(names, sorted(names))

    def test_preset_react_finds_violations(self):
        self.write_file("App.tsx",
                        '<div className="app">\n'
                        '  <img src="/logo.png" />\n'
                        '  <span></span>\n'
                        '</div>\n')
        result = self.run_cli(["--preset", "react", self.root])
        self.assert_exit(result, 0)
        output = self.output(result)
        self.assertIn("react/self-closing-comp", output)

    def test_preset_common_finds_violations(self):
        self.write_file("utils.ts",
                        "var x = 1;\n"
                        "console.log('debug');\n"
                        "debugger;\n")
        result = self.run_cli(["--preset", "common", self.root])
        self.assert_exit(result, 1)
        output = self.output(result)
        self.assertIn("common/no-var", output)
        self.assertIn("common/no-console-log", output)
        self.assertIn("common/no-debugger", output)

    def test_preset_vue_finds_violations(self):
        self.write_file("App.vue",
                        "<template>\n"
                        '  <li v-for="item in items">{{ item.name }}</li>\n'
                        '  <div v-html="raw"></div>\n'
                        "</template>\n")
        result = self.run_cli(["--preset", "vue", self.root])
        self.assert_exit(result, 1)
        output = self.output(result)
        self.assertIn("vue/require-v-for-key", output)
        self.assertIn("vue/no-v-html", output)

    def test_preset_unknown_is_usage_error(self):
        self.write_file("App.tsx", "<div />\n")
        result = self.run_cli(["--preset", "nonexistent", self.root])
        self.assert_exit(result, 2)
        self.assertIn("unknown preset", self.output(result))

    def test_preset_and_config_are_mutually_exclusive(self):
        self.write_file("App.tsx", "<div />\n")
        result = self.run_cli(
            ["--preset", "react", "--config", self.config, self.root])
        self.assert_exit(result, 2)
        self.assertIn("mutually exclusive", self.output(result))

    def test_preset_clean_code_exits_zero(self):
        self.write_file("App.tsx",
                        '<div className="app">\n'
                        '  <img src="/logo.png" alt="logo" />\n'
                        '</div>\n')
        result = self.run_cli(["--preset", "react", self.root])
        self.assert_exit(result, 0)

    def test_preset_repeated_deduplicates(self):
        self.write_file("App.tsx", "<span></span>\n")
        result = self.run_cli(
            ["--preset", "react", "--preset", "react", self.root])
        self.assert_exit(result, 0)
        output = self.output(result)
        # Only one finding for self-closing-comp, not two
        marker = "] react/self-closing-comp — "
        reported = [line for line in output.splitlines() if marker in line]
        self.assertEqual(len(reported), 1)

    def test_preset_combined_react_and_common(self):
        self.write_file("App.tsx",
                        "console.log('debug');\n"
                        "<span></span>\n")
        result = self.run_cli(
            ["--preset", "react", "--preset", "common", self.root])
        self.assert_exit(result, 0)
        output = self.output(result)
        self.assertIn("common/no-console-log", output)
        self.assertIn("react/self-closing-comp", output)

    def test_preset_json_output(self):
        self.write_file("App.tsx", "<span></span>\n")
        result = self.run_cli(
            ["--preset", "react", "--format", "json", self.root])
        self.assert_exit(result, 0)
        import json
        payload = json.loads(self.output(result))
        findings = payload["findings"]
        self.assertTrue(len(findings) > 0)
        self.assertEqual(findings[0]["rule_id"], "react/self-closing-comp")

    def test_preset_github_output(self):
        self.write_file("App.tsx", "<span></span>\n")
        result = self.run_cli(
            ["--preset", "react", "--format", "github", self.root])
        self.assert_exit(result, 0)
        output = self.output(result)
        self.assertIn("::warning file=App.tsx", output)
        self.assertIn("title=react/self-closing-comp", output)

    def test_preset_summary_output(self):
        self.write_file("App.tsx", "<span></span>\n")
        result = self.run_cli(
            ["--preset", "react", "--summary", self.root])
        self.assert_exit(result, 0)
        output = self.output(result)
        self.assertIn("react/self-closing-comp | 1", output)

    def test_preset_errors_only(self):
        self.write_file("App.tsx", "<span></span>\n")
        result = self.run_cli(
            ["--preset", "react", "--errors-only", self.root])
        # self-closing-comp is a warning, so --errors-only should exit 0
        self.assert_exit(result, 0)

    def test_preset_angular_finds_violations(self):
        self.write_file("app.component.ts",
                        "@Input('alias') name: string;\n"
                        "@Output() click = new EventEmitter();\n")
        result = self.run_cli(["--preset", "angular", self.root])
        self.assert_exit(result, 1)
        output = self.output(result)
        self.assertIn("angular/no-input-rename", output)
        self.assertIn("angular/no-output-native", output)

    def test_preset_svelte_finds_violations(self):
        self.write_file("App.svelte",
                        "{#each items as item}\n"
                        "  <li>{item}</li>\n"
                        "{/each}\n")
        result = self.run_cli(["--preset", "svelte", self.root])
        self.assert_exit(result, 1)
        output = self.output(result)
        self.assertIn("svelte/require-each-key", output)

    def test_preset_next_finds_violations(self):
        self.write_file("index.tsx",
                        "<head>\n"
                        '  <a href="/about">About</a>\n'
                        '  <img src="/hero.png" />\n'
                        "</head>\n")
        result = self.run_cli(["--preset", "next", self.root])
        self.assert_exit(result, 0)
        output = self.output(result)
        self.assertIn("next/no-head-element", output)
        self.assertIn("next/no-html-link-for-pages", output)
        self.assertIn("next/no-img-element", output)

    def test_preset_file_finds_violations(self):
        self.write_file("test.ts",
                        "const x = 1;   \n"
                        "\tconst y = 2;\n"
                        "const x = 1;\n")
        result = self.run_cli(["--preset", "file", self.root])
        self.assert_exit(result, 0)
        output = self.output(result)
        self.assertIn("file/no-trailing-whitespace", output)
        self.assertIn("file/no-tabs", output)
        self.assertIn("file/no-duplicate-lines", output)

    def test_preset_file_clean_code_exits_zero(self):
        self.write_file("test.ts", "const x = 1;\nconst y = 2;\n")
        result = self.run_cli(["--preset", "file", self.root])
        self.assert_exit(result, 0)
        self.assertNotIn("file/", self.output(result))

    def test_preset_solid_finds_violations(self):
        self.write_file("App.tsx",
                        "import { render } from 'solid-js'\n"
                        "<div innerHTML=\"raw\" />\n")
        result = self.run_cli(["--preset", "solid", self.root])
        self.assert_exit(result, 1)
        output = self.output(result)
        self.assertIn("solid/no-innerhtml", output)

    def test_preset_astro_finds_violations(self):
        self.write_file("page.astro",
                        "<div set:html={raw} />\n")
        result = self.run_cli(["--preset", "astro", self.root])
        self.assert_exit(result, 1)
        output = self.output(result)
        self.assertIn("astro/no-set-html-directive", output)

    def test_preset_nuxt_finds_violations(self):
        self.write_file("index.vue",
                        "<div>{{ process.env.API_URL }}</div>\n")
        result = self.run_cli(["--preset", "nuxt", self.root])
        self.assert_exit(result, 1)
        output = self.output(result)
        self.assertIn("nuxt/no-env-in-runtime", output)

    def test_config_with_equals_matcher(self):
        self.write_config([{
            "id": "test/equals",
            "severity": "error",
            "message": "Line equals export default",
            "extensions": [".ts"],
            "match": {"equals": "export default"},
        }])
        self.write_file("test.ts", "export default\nconst x = 1\n")
        result = self.invoke()
        self.assert_findings(result, 1, rule_id="test/equals")

    def test_config_with_word_matcher(self):
        self.write_config([{
            "id": "test/word",
            "severity": "error",
            "message": "Contains word foo",
            "extensions": [".ts"],
            "match": {"word": "foo"},
        }])
        self.write_file("test.ts", "let foo = 1\nlet foobar = 2\n")
        result = self.invoke()
        self.assert_findings(result, 1, rule_id="test/word")

    def test_config_with_file_rules(self):
        self.write_config(rules=[], file_rules=[{
            "id": "file/no-tabs",
            "severity": "error",
            "message": "No tabs",
            "extensions": [".ts"],
            "check": {"no_tabs": True},
        }])
        self.write_file("test.ts", "const x = 1;\n\tconst y = 2;\n")
        result = self.invoke()
        self.assert_findings(result, 1, rule_id="file/no-tabs")

    def test_config_with_file_rules_max_lines(self):
        self.write_config(rules=[], file_rules=[{
            "id": "file/max-lines",
            "severity": "error",
            "message": "Too many lines",
            "extensions": [".ts"],
            "check": {"max_lines": 2},
        }])
        self.write_file("test.ts", "a\nb\nc\n")
        result = self.invoke()
        self.assert_findings(result, 1, rule_id="file/max-lines")

    def test_config_file_rules_only_no_rules_key(self):
        self.write_config(rules=[], file_rules=[{
            "id": "file/final-newline",
            "severity": "error",
            "message": "Must end with newline",
            "extensions": [".ts"],
            "check": {"final_newline": True},
        }])
        self.write_file("test.ts", "no newline")
        result = self.invoke()
        self.assert_findings(result, 1, rule_id="file/final-newline")

    def test_inline_disable_next_line(self):
        self.write_config(rules=[], file_rules=[{
            "id": "file/no-trailing-whitespace",
            "severity": "error",
            "message": "No trailing whitespace",
            "extensions": [".ts"],
            "check": {"no_trailing_whitespace": True},
        }])
        self.write_file("test.ts",
                        "// moonlint-disable-next-line\n"
                        "const x = 1;   \n"
                        "const y = 2;   \n")
        result = self.invoke()
        # Line 2 is disabled, only line 3 should be reported
        self.assert_findings(result, 1, rule_id="file/no-trailing-whitespace")

    def test_inline_disable_all(self):
        self.write_config(rules=[], file_rules=[{
            "id": "file/no-trailing-whitespace",
            "severity": "error",
            "message": "No trailing whitespace",
            "extensions": [".ts"],
            "check": {"no_trailing_whitespace": True},
        }])
        self.write_file("test.ts",
                        "// moonlint-disable\n"
                        "const x = 1;   \n"
                        "const y = 2;   \n")
        result = self.invoke()
        self.assert_findings(result, 0, rule_id="file/no-trailing-whitespace")

    def test_inline_disable_specific_rule(self):
        self.write_config(rules=[], file_rules=[{
            "id": "file/no-trailing-whitespace",
            "severity": "error",
            "message": "No trailing whitespace",
            "extensions": [".ts"],
            "check": {"no_trailing_whitespace": True},
        }])
        self.write_file("test.ts",
                        "// moonlint-disable file/no-trailing-whitespace\n"
                        "const x = 1;   \n")
        result = self.invoke()
        self.assert_findings(result, 0, rule_id="file/no-trailing-whitespace")

    def test_config_extends(self):
        # Write base config
        base_path = self.base / "base.json"
        base_path.write_text(json.dumps({
            "rules": [{
                "id": "base/no-foo",
                "severity": "error",
                "message": "No foo",
                "extensions": [".ts"],
                "match": {"contains": "foo"},
            }],
        }), encoding="utf-8")
        # Write main config that extends base
        self.config.write_text(json.dumps({
            "extends": "base.json",
            "rules": [{
                "id": "custom/no-bar",
                "severity": "error",
                "message": "No bar",
                "extensions": [".ts"],
                "match": {"contains": "bar"},
            }],
        }), encoding="utf-8")
        self.write_file("test.ts", "const foo = 1;\nconst bar = 2;\n")
        result = self.invoke()
        self.assert_findings(result, 1, rule_id="base/no-foo")
        self.assert_findings(result, 1, rule_id="custom/no-bar")

    def test_init_creates_config(self):
        import os
        init_dir = self.base / "init-test"
        init_dir.mkdir()
        result = subprocess.run(
            [str(BINARY), "--init"],
            cwd=init_dir, env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
        self.assert_exit(result, 0)
        config_path = init_dir / "moonlint.json"
        self.assertTrue(config_path.is_file(), "moonlint.json was not created")

    def test_sarif_output_format(self):
        self.write_config([{
            "id": "test/rule",
            "severity": "error",
            "message": "test",
            "extensions": [".ts"],
            "match": {"contains": "FORBIDDEN"},
        }])
        self.write_file("test.ts", "FORBIDDEN\n")
        result = self.invoke("--format", "sarif")
        self.assert_exit(result, 1)
        output = self.output(result)
        self.assertIn('"version": "2.1.0"', output)
        self.assertIn('"ruleId": "test/rule"', output)
        self.assertIn('"level": "error"', output)

    def test_fix_removes_trailing_whitespace(self):
        self.write_config(rules=[], file_rules=[{
            "id": "file/no-trailing-whitespace",
            "severity": "error",
            "message": "No trailing whitespace",
            "extensions": [".ts"],
            "check": {"no_trailing_whitespace": True},
        }])
        self.write_file("test.ts", "const x = 1;   \nconst y = 2;\n")
        result = self.invoke("--fix")
        self.assert_exit(result, 0)
        # Verify the file was fixed
        content = (self.root / "test.ts").read_text(encoding="utf-8")
        self.assertEqual(content, "const x = 1;\nconst y = 2;\n")

    def test_fix_leaves_tabs_by_default(self):
        """Tab replacement changes indentation width, so it must be opt-in."""
        self.write_config(rules=[], file_rules=[{
            "id": "file/no-tabs",
            "severity": "error",
            "message": "No tabs",
            "extensions": [".ts"],
            "check": {"no_tabs": True},
        }])
        self.write_file("test.ts", "\tconst x = 1;\n")
        result = self.invoke("--fix")
        self.assert_exit(result, 1)
        content = (self.root / "test.ts").read_text(encoding="utf-8")
        self.assertEqual(content, "\tconst x = 1;\n")

    def test_fix_replaces_tabs_when_opted_in(self):
        self.write_config(rules=[], file_rules=[{
            "id": "file/no-tabs",
            "severity": "error",
            "message": "No tabs",
            "extensions": [".ts"],
            "check": {"no_tabs": True},
        }])
        self.write_file("test.ts", "\tconst x = 1;\n")
        result = self.invoke("--fix", "--fix-tab-width", "4")
        self.assert_exit(result, 0)
        content = (self.root / "test.ts").read_text(encoding="utf-8")
        self.assertEqual(content, "    const x = 1;\n")

    def test_fix_adds_final_newline(self):
        self.write_config(rules=[], file_rules=[{
            "id": "file/final-newline",
            "severity": "error",
            "message": "Must end with newline",
            "extensions": [".ts"],
            "check": {"final_newline": True},
        }])
        self.write_file("test.ts", "const x = 1;")
        result = self.invoke("--fix")
        self.assert_exit(result, 0)
        content = (self.root / "test.ts").read_text(encoding="utf-8")
        self.assertEqual(content, "const x = 1;\n")

    # --- regression tests for audited defects ---

    def test_cyclic_extends_reports_error_not_crash(self):
        """A extends-cycle used to overflow the stack (exit 139)."""
        (self.base / "a.json").write_text(
            json.dumps({"extends": "b.json", "rules": []}), encoding="utf-8")
        (self.base / "b.json").write_text(
            json.dumps({"extends": "a.json", "rules": []}), encoding="utf-8")
        self.write_file("test.ts", "const x = 1;\n")
        result = self.invoke("--config", str(self.base / "a.json"))
        self.assert_exit(result, 2)
        self.assertIn("cyclic extends", result.stdout + result.stderr)

    def test_nested_extends_resolves_relative_to_declaring_file(self):
        """A grandchild config's relative path is relative to ITS directory."""
        nested = self.base / "lvl1" / "lvl2"
        nested.mkdir(parents=True, exist_ok=True)
        (nested / "leaf.json").write_text(json.dumps({"rules": [{
            "id": "leaf/no-foo", "severity": "error", "message": "leaf",
            "extensions": [".ts"], "match": {"contains": "foo"},
        }]}), encoding="utf-8")
        (self.base / "lvl1" / "mid.json").write_text(
            json.dumps({"extends": "lvl2/leaf.json", "rules": []}),
            encoding="utf-8")
        (self.base / "root.json").write_text(
            json.dumps({"extends": "lvl1/mid.json", "rules": []}),
            encoding="utf-8")
        self.write_file("test.ts", "const foo = 1;\n")
        result = self.invoke("--config", str(self.base / "root.json"))
        self.assert_findings(result, 1, rule_id="leaf/no-foo")

    def test_duplicate_rule_id_in_one_config_is_rejected(self):
        """The shadowed duplicate used to be dropped silently."""
        self.write_config([
            {"id": "same/id", "severity": "error", "message": "first",
             "extensions": [".ts"], "match": {"contains": "foo"}},
            {"id": "same/id", "severity": "warning", "message": "second",
             "extensions": [".ts"], "match": {"contains": "bar"}},
        ])
        self.write_file("test.ts", "foo\n")
        result = self.invoke()
        self.assert_exit(result, 2)
        self.assertIn("duplicate rule id", result.stdout + result.stderr)

    def test_fix_respects_rule_scope(self):
        """--fix used to rewrite paths excluded by the rule's scope."""
        self.write_config(rules=[], file_rules=[{
            "id": "file/tws", "severity": "error", "message": "tws",
            "extensions": [".ts"], "exclude": ["vendor/**"],
            "check": {"no_trailing_whitespace": True},
        }])
        vendor = self.root / "vendor"
        vendor.mkdir(exist_ok=True)
        (vendor / "lib.ts").write_text("const v = 1;   \n", encoding="utf-8")
        self.write_file("app.ts", "const a = 1;   \n")
        self.invoke("--fix")
        self.assertEqual((vendor / "lib.ts").read_text(encoding="utf-8"),
                         "const v = 1;   \n",
                         "excluded file must not be modified")
        self.assertEqual((self.root / "app.ts").read_text(encoding="utf-8"),
                         "const a = 1;\n")

    def test_fix_preserves_crlf_line_endings(self):
        """final_newline used to append a bare LF into a CRLF file."""
        self.write_config(rules=[], file_rules=[{
            "id": "file/final", "severity": "error", "message": "m",
            "extensions": [".ts"], "check": {"final_newline": True},
        }])
        (self.root / "test.ts").write_bytes(b"const a = 1;\r\nconst b = 2;")
        self.invoke("--fix")
        self.assertEqual((self.root / "test.ts").read_bytes(),
                         b"const a = 1;\r\nconst b = 2;\r\n")

    def test_fix_json_output_stays_parseable(self):
        """Progress messages used to corrupt --format json on stdout."""
        self.write_config(rules=[], file_rules=[{
            "id": "file/tws", "severity": "error", "message": "tws",
            "extensions": [".ts"], "check": {"no_trailing_whitespace": True},
        }])
        self.write_file("test.ts", "const a = 1;   \n")
        result = self.invoke("--fix", "--format", "json")
        json.loads(result.stdout)  # must not raise

    def test_fix_rejected_with_git_scan_modes(self):
        """Blob-backed modes read Git, so working-tree fixes would not apply."""
        self.write_config(rules=[], file_rules=[{
            "id": "file/final", "severity": "error", "message": "m",
            "extensions": [".ts"], "check": {"final_newline": True},
        }])
        self.write_file("test.ts", "const a = 1;")
        result = self.invoke("--staged", "--fix")
        self.assert_exit(result, 2)
        self.assertIn("--fix cannot be combined", result.stdout + result.stderr)

    def test_whole_file_check_not_suppressed_by_inline_disable(self):
        """A line-1 comment must not mask a whole-file property like BOM."""
        self.write_config(rules=[], file_rules=[{
            "id": "file/bom", "severity": "error", "message": "bom",
            "extensions": [".ts"], "check": {"no_bom": True},
        }])
        (self.root / "test.ts").write_bytes(
            b"\xef\xbb\xbf// moonlint-disable file/bom\nconst x = 1;\n")
        result = self.invoke()
        self.assert_findings(result, 1, rule_id="file/bom")

    def test_astro_files_are_covered_by_hygiene_presets(self):
        """.astro was missing from the file/common preset extension lists."""
        (self.root / "page.astro").write_text("<div>   \n</div>",
                                              encoding="utf-8")
        result = self.invoke("--preset", "file")
        self.assert_findings(result, 2, rule_id="file/")


PHASES = {
    "repairs": RepairsTests,
    "git": GitSafetyTests,
    "scope": ScopeTests,
    "output": OutputTests,
    "presets": PresetTests,
}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True,
                        help="absolute path to an existing native moonlint executable")
    parser.add_argument("--phase", choices=(*PHASES, "all"), default="all")
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
            parser.error(
                f"phase {phase!r} has no tests; available: {', '.join(PHASES)}"
            )
    suite = unittest.TestSuite(
        unittest.defaultTestLoader.loadTestsFromTestCase(PHASES[phase])
        for phase in selected
    )
    result = unittest.TextTestRunner(verbosity=1 if args.quiet else 2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
