"""Owned-tempfile integration tests for immutable Git project context.

The parent injects FixtureCase and registers the returned class. This module
never imports integration.py or builds moonlint. Git mutations, replacement
objects, and PATH shims are confined to asserted-owned temporary repositories.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import shutil
import sys


UNUSED = "git-context/no-unused-exports"
UNRESOLVED = "git-context/no-unresolved-relative-imports"
CYCLES = "git-context/no-import-cycles"
TOKEN_RULE = "git-context/snapshot-token"


# The shim buffers one real machine listing, mutates the owned repository, and
# only then forwards that original listing to moonlint. No sleeps or timing
# assumptions are used. Its saved real PATH and absolute Git prevent recursion.
_GIT_LISTING_SHIM = r'''
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

control = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
base = Path(control["owned_base"]).resolve()
checkout = Path(control["checkout"]).resolve()
assert base.name.startswith("moonlint-"), base
assert base.parent == Path(tempfile.gettempdir()).resolve(), base


def assert_owned(path):
    resolved = Path(path).resolve()
    assert resolved != base and resolved.is_relative_to(base), resolved
    assert not resolved.is_relative_to(checkout), resolved
    return resolved


repo = assert_owned(control["repo"])
assert_owned(repo / ".git")
context_path = assert_owned(repo / control["context_path"])
assert context_path.is_relative_to(repo), context_path
trace = assert_owned(control["trace"])
marker = assert_owned(control["marker"])
real_git = str(Path(control["real_git"]).resolve())
real_env = control["real_env"]
argv = sys.argv[2:]
for index, token in enumerate(argv[:-1]):
    if token == "-C":
        assert assert_owned(argv[index + 1]) == repo


def command_args(arguments):
    # Global options may precede -C or move it away from argv[1]. In particular
    # --no-replace-objects is a global option, not the subcommand.
    index = 0
    paired = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"}
    while index < len(arguments):
        token = arguments[index]
        if token in paired:
            index += 2
        elif token.startswith("-"):
            index += 1
        else:
            return token, arguments[index + 1:]
    return None, []


def record(value):
    assert_owned(trace)
    with trace.open("ab") as stream:
        stream.write((json.dumps(value, ensure_ascii=False) + "\n").encode("utf-8"))


command, arguments = command_args(argv)
completed = subprocess.run([real_git, *argv], env=real_env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           check=False)
record({"event": "git", "command": command, "arguments": arguments,
        "returncode": completed.returncode})
full_index = command == "ls-files" and "--stage" in arguments and (
    "--" not in arguments or arguments.index("--") == len(arguments) - 1)
full_tree = command == "ls-tree" and "-r" in arguments
trigger = (control["mode"] == "changed" and full_tree) or (
    control["mode"] == "staged" and full_index)
if completed.returncode == 0 and trigger:
    context_oid = None
    for item in completed.stdout.split(b"\0"):
        header, separator, name = item.partition(b"\t")
        if separator and name == control["context_path"].encode("utf-8"):
            fields = header.split(b" ")
            context_oid = fields[1 if full_index else 2].decode("ascii")
    assert context_oid == control["old_context_oid"], (context_oid, control["old_context_oid"], command, arguments)
    try:
        assert_owned(marker)
        with marker.open("xb") as stream:
            stream.write(b"owned Git listing barrier\n")
    except FileExistsError:
        pass
    else:
        if control["mode"] == "changed":
            mutation = ["update-ref", "HEAD", control["replacement_head"]]
        else:
            mutation = ["update-index", "--cacheinfo",
                        "100644," + control["replacement_oid"] + "," + control["context_path"]]
        changed = subprocess.run(
            [real_git, "-c", "core.hooksPath=" + os.devnull,
             "-C", str(repo), *mutation], env=real_env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if changed.returncode:
            sys.stderr.buffer.write(changed.stderr)
            raise SystemExit(97)
        record({"event": "mutated", "after_listing": command,
                "mode": control["mode"], "old_context_oid": context_oid})
# Nothing from the replacement listing or new mutable HEAD/index is forwarded.
sys.stdout.buffer.write(completed.stdout)
sys.stdout.buffer.flush()
sys.stderr.buffer.write(completed.stderr)
raise SystemExit(completed.returncode)
'''


def make_git_context_tests(base_case, repo_root):
    """Return eight FixtureCase tests; the parent supplies the existing binary."""
    checkout = Path(repo_root).resolve()

    class GitContextTests(base_case):
        def setUp(self):
            super().setUp()
            self.assertFalse(self.base.is_relative_to(checkout))
            self.assertNotEqual(self.assert_owned(self.root), checkout)
            found = shutil.which("git", path=self.env.get("PATH"))
            if found is None:
                self.skipTest("Git is required for project-context integration")
            self.real_git = Path(found).resolve()
            self.assertTrue(self.real_git.is_file())

        def _configure(self, checks, *, token=None, exclude=None):
            rules = [] if token is None else [{
                "id": TOKEN_RULE, "severity": "error",
                "message": "Selected source must be the captured Git blob",
                "extensions": [".ts"], "match": {"contains": token},
            }]
            fields = {"structural_rules": [
                {"id": rule_id, "severity": "error", "message": rule_id,
                 "extensions": [".ts"], "check": {check: True}}
                for rule_id, check in checks
            ]}
            if exclude is not None:
                fields["exclude"] = exclude
            self.write_config(rules=rules, **fields)

        def _bytes(self, name, value):
            path = self.assert_owned(self.root / name)
            self.assert_owned(path.parent)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)
            return path

        def _lint(self, *arguments, expected=0, context=1, failed=0, snapshot=None):
            result = self.invoke(*arguments, "--ext", ".ts", "--format", "json")
            self.assert_exit(result, expected)
            value = json.loads(result.stdout.decode("utf-8"))
            self.assertIsInstance(value, dict)
            self.assertEqual(value["tool"], "moonlint")
            self.assertEqual(value["counts"]["findings"], len(value["findings"]))
            scan = value["scan"]
            self.assertEqual(scan["files_selected"], 1)
            self.assertEqual(scan["files_scanned"], 1)
            self.assertEqual(scan["files_failed"], 0)
            self.assertEqual(scan["context_files_scanned"], context)
            self.assertEqual(scan["context_files_failed"], failed)
            if snapshot is not None:
                self.assertEqual(scan["source_snapshot"], snapshot)
            if not failed:
                self.assertEqual(value["diagnostics"], [])
            self.assertTrue(all(finding["file"] == "a.ts" for finding in value["findings"]), value)
            return value

        def _with_settings(self):
            self.write_file("a.ts", "import settings from './settings';\nexport const live = settings.enabled;\n")
            self.write_file("b.ts", "import { live } from './a';\nconst consumer = live;\nexport const contextOnly = 1;\n")
            self.write_file("settings.json", '{"enabled":true}\n')

        def _blob_oid(self, revision, name):
            self.assert_owned(self.root / name)
            return self.git("rev-parse", f"{revision}:{name}")

        def _install_listing_shim(self, mode, old_context_oid, *, replacement_head=None, replacement_oid=None):
            if os.name != "posix":
                self.skipTest("Native Git listing barriers require a POSIX PATH shim")
            driver = self.write_file("git-shim/driver.py", _GIT_LISTING_SHIM, root=self.base)
            marker = self.assert_owned(self.base / "git-shim" / "triggered")
            trace = self.assert_owned(self.base / "git-shim" / "trace.jsonl")
            self.trace = trace
            self.marker = marker
            control = {
                "owned_base": str(self.base), "checkout": str(checkout),
                "repo": str(self.assert_owned(self.root)),
                "context_path": "b.ts", "old_context_oid": old_context_oid,
                "mode": mode, "replacement_head": replacement_head,
                "replacement_oid": replacement_oid,
                "real_git": str(self.real_git), "real_env": dict(self.env),
                "marker": str(marker), "trace": str(trace),
            }
            manifest = self.write_file("git-shim/control.json", json.dumps(control), root=self.base)
            launcher = "#!/bin/sh\nexec " + " ".join(map(shlex.quote, [
                str(Path(sys.executable).resolve()), str(driver), str(manifest),
            ])) + ' "$@"\n'
            shim = self.write_file("git-shim/bin/git", launcher, root=self.base)
            self.assert_owned(shim).chmod(0o755)
            self.env["PATH"] = str(self.assert_owned(shim.parent)) + os.pathsep + self.env.get("PATH", os.defpath)

        def _assert_barrier(self, mode, old_context_oid, old_selected_oid):
            self.assertTrue(self.assert_owned(self.marker).is_file(), "listing shim never reached its mutation barrier")
            trace = [json.loads(line) for line in self.assert_owned(self.trace).read_text(encoding="utf-8").splitlines()]
            mutations = [entry for entry in trace if entry["event"] == "mutated"]
            self.assertEqual(len(mutations), 1, trace)
            self.assertEqual(mutations[0]["mode"], mode)
            self.assertEqual(mutations[0]["after_listing"], "ls-tree" if mode == "changed" else "ls-files")
            blobs = [entry["arguments"][1] for entry in trace
                     if entry["event"] == "git" and entry["command"] == "cat-file"
                     and len(entry["arguments"]) == 2 and entry["arguments"][0] == "blob"]
            self.assertIn(old_context_oid, blobs, trace)
            self.assertIn(old_selected_oid, blobs, trace)
            self.assertTrue(all(len(oid) in (40, 64) and all(c in "0123456789abcdef" for c in oid) for oid in blobs), trace)

        def test_changed_reads_selected_head_and_unselected_ts_json_context(self):
            self._configure([(UNUSED, "no_unused_exports"), (UNRESOLVED, "no_unresolved_relative_imports")], token="HEAD_FORBIDDEN")
            self.init_git()
            self._with_settings()
            self.write_file("b.ts", "import { live } from './a';\nconst consumer = live;\nexport const contextOnly = HEAD_FORBIDDEN;\n")
            base = self.commit("base context")
            self.write_file("a.ts", "import settings from './settings';\nexport const live = settings.enabled;\nexport const dead = HEAD_FORBIDDEN;\n")
            captured = self.commit("change only selected a")
            self.write_file("a.ts", "export const dirtyOnly = 1;\n")
            self.write_file("b.ts", "export const wrongWorktreeContext = 1;\n")
            self._bytes("settings.json", b"\xffdirty JSON context\n")
            value = self._lint("--changed", base, expected=1, context=2, snapshot=captured)
            self.assertEqual(len(value["findings"]), 2)
            self.assertEqual({finding["rule_id"] for finding in value["findings"]}, {UNUSED, TOKEN_RULE})
            unused = [finding for finding in value["findings"] if finding["rule_id"] == UNUSED]
            self.assertIn("dead", unused[0]["message"])
            self.assertNotIn("live", unused[0]["message"])
            self.assertTrue(all("HEAD_FORBIDDEN" in finding["snippet"] for finding in value["findings"]))

        def test_staged_reads_selected_index_and_ignores_unstaged_context_changes(self):
            self._configure([(UNUSED, "no_unused_exports"), (UNRESOLVED, "no_unresolved_relative_imports")], token="INDEX_FORBIDDEN")
            self.init_git()
            self._with_settings()
            self.commit("base index")
            self.write_file("a.ts", "import settings from './settings';\nexport const live = settings.enabled;\nexport const dead = INDEX_FORBIDDEN;\n")
            self.git("add", "--", "a.ts")
            self.write_file("a.ts", "export const dirtySelected = 1;\n")
            self.write_file("b.ts", "export const dirtyUnselected = 1;\n")
            self._bytes("settings.json", b"\xffdirty JSON context\n")
            value = self._lint("--staged", expected=1, context=2, snapshot="index")
            self.assertEqual(len(value["findings"]), 2)
            self.assertEqual({finding["rule_id"] for finding in value["findings"]}, {UNUSED, TOKEN_RULE})
            self.assertIn("dead", next(finding["message"] for finding in value["findings"] if finding["rule_id"] == UNUSED))
            self.assertTrue(all("INDEX_FORBIDDEN" in finding["snippet"] for finding in value["findings"]))

        def test_cycles_use_the_complete_git_project_but_report_only_selected_files(self):
            self._configure([(CYCLES, "no_import_cycles")])
            self.init_git()
            self.write_file("a.ts", "import { b } from './b';\nexport const a = 1;\n")
            self.write_file("b.ts", "import { a } from './a';\nexport const b = 2;\n")
            base = self.commit("complete cycle")
            self.write_file("a.ts", "import { b } from './b';\nexport const a = 3;\n")
            captured = self.commit("change only a")
            self.write_file("b.ts", "export const dirtyBreaksCycle = 1;\n")
            value = self._lint("--changed", base, expected=1, snapshot=captured)
            self.assertEqual(len(value["findings"]), 1)
            self.assertEqual(value["findings"][0]["rule_id"], CYCLES)
            self.write_file("a.ts", "import { b } from './b';\nexport const a = 4;\n")
            self.git("add", "--", "a.ts")
            value = self._lint("--staged", expected=1, snapshot="index")
            self.assertEqual(len(value["findings"]), 1)
            self.assertEqual(value["findings"][0]["rule_id"], CYCLES)

        def test_glob_and_global_exclusions_do_not_remove_dependency_context(self):
            self._configure([(UNUSED, "no_unused_exports"), (UNRESOLVED, "no_unresolved_relative_imports")], token="CONTEXT_FORBIDDEN", exclude=["b.ts"])
            self._with_settings()
            self.write_file("a.ts", "import settings from './settings';\nexport const live = settings.enabled;\nexport const dead = 2;\n")
            self.write_file("b.ts", "import { live } from './a';\nconst consumer = live;\nexport const excludedDead = CONTEXT_FORBIDDEN;\n")
            value = self._lint("--glob", "a.ts", expected=1, context=2, snapshot="working-tree")
            self.assertEqual(len(value["findings"]), 1)
            self.assertEqual(value["findings"][0]["rule_id"], UNUSED)
            self.assertIn("dead", value["findings"][0]["message"])
            self.assertNotIn("live", value["findings"][0]["message"])

        def test_invalid_utf8_git_context_is_an_operational_failure_not_a_clean_scan(self):
            self._configure([(UNUSED, "no_unused_exports")])
            self.init_git()
            self.write_file("a.ts", "export const live = 1;\n")
            self._bytes("b.ts", b"\xffinvalid UTF-8 context\n")
            base = self.commit("bad context")
            self.write_file("a.ts", "export const live = 2;\n")
            captured = self.commit("selected change")
            value = self._lint("--changed", base, expected=2, context=0, failed=1, snapshot=captured)
            self.assertEqual(value["findings"], [])
            self.assertTrue(any(diagnostic["file"] == "b.ts" and "project context" in diagnostic["message"] and "UTF-8" in diagnostic["message"] for diagnostic in value["diagnostics"]), value)
            self.write_file("a.ts", "export const live = 3;\n")
            self.git("add", "--", "a.ts")
            value = self._lint("--staged", expected=2, context=0, failed=1, snapshot="index")
            self.assertEqual(value["findings"], [])
            self.assertGreater(value["scan"]["context_files_failed"], 0)

        def test_changed_context_is_pinned_before_head_moves_after_tree_listing(self):
            self._configure([(UNUSED, "no_unused_exports")])
            self.init_git()
            self.write_file("a.ts", "export const live = 1;\n")
            self.write_file("b.ts", "import { live } from './a';\nconst consumer = live;\n")
            base = self.commit("base")
            self.write_file("a.ts", "export const live = 2;\n")
            captured = self.commit("selected a")
            old_context = self._blob_oid(captured, "b.ts")
            old_selected = self._blob_oid(captured, "a.ts")
            self.write_file("b.ts", "const replacementWithoutImport = 1;\n")
            replacement = self.commit("replacement HEAD removes the consumer")
            self.git("update-ref", "HEAD", captured)
            self._install_listing_shim("changed", old_context, replacement_head=replacement)
            value = self._lint("--changed", base, snapshot=captured)
            self.assertEqual(value["findings"], [])
            self._assert_barrier("changed", old_context, old_selected)
            self.assertEqual(self.git("rev-parse", "HEAD"), replacement)
            self.assertNotEqual(self._blob_oid("HEAD", "b.ts"), old_context)

        def test_staged_context_is_pinned_before_index_changes_after_stage_listing(self):
            self._configure([(UNUSED, "no_unused_exports")])
            self.init_git()
            self.write_file("a.ts", "export const live = 1;\n")
            self.write_file("b.ts", "import { live } from './a';\nconst consumer = live;\n")
            self.commit("base")
            self.write_file("a.ts", "export const live = 2;\n")
            self.git("add", "--", "a.ts")
            old_context = self._blob_oid("", "b.ts")
            old_selected = self._blob_oid("", "a.ts")
            replacement_file = self.write_file("replacement-context.ts", "const replacementWithoutImport = 1;\n", root=self.base)
            replacement = self.git("hash-object", "-w", "--", str(self.assert_owned(replacement_file)))
            self._install_listing_shim("staged", old_context, replacement_oid=replacement)
            value = self._lint("--staged", snapshot="index")
            self.assertEqual(value["findings"], [])
            self._assert_barrier("staged", old_context, old_selected)
            self.assertEqual(self._blob_oid("", "b.ts"), replacement)

        def test_blob_replace_refs_cannot_redirect_pinned_context_object_bytes(self):
            self._configure([(UNUSED, "no_unused_exports")])
            self.init_git()
            self.write_file("a.ts", "export const live = 1;\n")
            self.write_file("b.ts", "import { live } from './a';\nconst consumer = live;\n")
            base = self.commit("base")
            self.write_file("a.ts", "export const live = 2;\n")
            captured = self.commit("selected change")
            old_context = self._blob_oid(captured, "b.ts")
            replacement_file = self.write_file("replacement-context.ts", "const replacementWithoutImport = 1;\n", root=self.base)
            replacement = self.git("hash-object", "-w", "--", str(self.assert_owned(replacement_file)))
            self.git("replace", old_context, replacement)
            # Prove the replace ref is active, and that the global flag restores
            # the real object bytes. The CLI must apply that flag itself.
            self.assertIn("replacementWithoutImport", self.git("cat-file", "blob", old_context))
            self.assertIn("import { live }", self.git("--no-replace-objects", "cat-file", "blob", old_context))
            value = self._lint("--changed", base, snapshot=captured)
            self.assertEqual(value["findings"], [])

    return GitContextTests
