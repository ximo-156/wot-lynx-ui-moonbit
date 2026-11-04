"""Owned-tempfile integration cases for project policies and MoonBit safety.

The parent runner injects its FixtureCase, so its existing run_cli method keeps
using the same BINARY globals even when integration.py is executed as __main__.
This module neither imports that runner nor builds moonlint. Only the real
compiler cases require moon; all compiler commands run in asserted-owned,
dependency-free temporary modules and never automatically format their source.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
import re
import shutil
import subprocess


MODULE = "fixture/architecture"
RULE_ID = "policy/forbidden"
TOKEN = "FORBIDDEN"


def make_policy_tests(base_case, repo_root):
    """Return the unittest class for the parent's policies PHASES entry."""
    checkout = Path(repo_root).resolve()

    class PolicyTests(base_case):
        def _json_file(self, name, value):
            return self.write_file(
                name, json.dumps(value, ensure_ascii=False, indent=2) + "\n",
                root=self.base,
            )

        def _decode_json(self, result, expected):
            self.assert_exit(result, expected)
            # json.loads rejects progress messages, second documents and other
            # non-whitespace stdout contamination, not just malformed objects.
            text = result.stdout.decode("utf-8")
            self.assertTrue(text.strip(), "expected a JSON document on stdout")
            try:
                value = json.loads(text)
            except (ValueError, UnicodeError) as exc:
                self.fail(f"stdout is not pure JSON: {exc}\n{text!r}")
            self.assertIsInstance(value, dict)
            return value

        def _policy_json(self, result, expected, mode):
            value = self._decode_json(result, expected)
            self.assertEqual(value["tool"], "moonlint")
            self.assertEqual(value["mode"], mode)
            self.assertIsInstance(value["metadata"], dict)
            self.assertIsInstance(value["counts"], dict)
            findings = value["findings"]
            self.assertIsInstance(findings, list)
            self.assertEqual(value["counts"]["findings"], len(findings))
            self.assertEqual(value["counts"]["errors"],
                             sum(f["severity"] == "error" for f in findings))
            self.assertEqual(value["counts"]["warnings"],
                             sum(f["severity"] == "warning" for f in findings))
            for finding in findings:
                self.assertIsInstance(finding["details"], dict)
                self.assertNotIn("file", finding)
                self.assertNotIn("line", finding)
                self.assertNotIn("column", finding)
            return value

        def _lint_json(self, result, expected):
            value = self._decode_json(result, expected)
            self.assertEqual(value["tool"], "moonlint")
            self.assertIn("scan", value)
            self.assertEqual(value["counts"]["findings"], len(value["findings"]))
            self.assertEqual(value["diagnostics"], [])
            self.assertEqual(value["scan"]["files_failed"], 0)
            return value

        def _sarif(self, result, expected, rule_ids, mode):
            value = self._decode_json(result, expected)
            self.assertEqual(value["version"], "2.1.0")
            self.assertEqual(len(value["runs"]), 1)
            run = value["runs"][0]
            self.assertEqual(run["properties"]["mode"], mode)
            self.assertEqual({r["ruleId"] for r in run["results"]}, set(rule_ids))
            for finding in run["results"]:
                self.assertNotIn("locations", finding)
                self.assertNotIn("relatedLocations", finding)
                self.assertIsInstance(finding["properties"], dict)
            return run

        def _compiler(self, root, *arguments):
            compiler = shutil.which("moon", path=self.env.get("PATH"))
            if compiler is None:
                self.skipTest("moon is required for owned real-compiler fixtures")
            owned = self.assert_owned(root)
            self.assertEqual(owned, Path(root).resolve())
            self.assertNotEqual(owned, checkout)
            self.assertFalse(owned.is_relative_to(checkout))
            self.assertFalse(checkout.is_relative_to(owned))
            command = [compiler, *map(str, arguments)]
            if arguments and arguments[0] in {"check", "test", "info"}:
                target = self.assert_owned(owned / "_build")
                command.extend(["--target-dir", str(target)])
            try:
                result = subprocess.run(
                    command, cwd=owned, env=self.env, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, timeout=120, check=False,
                )
            except subprocess.TimeoutExpired:
                self.fail(f"owned compiler fixture timed out: {command!r}")
            self.assertEqual(
                result.returncode, 0,
                f"compiler fixture failed in {owned}: {command!r}\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}",
            )
            return result

        def _compiler_check_test(self, root):
            self._compiler(root, "check", "--target", "native")
            result = self._compiler(root, "test", "--target", "native")
            summary = re.search(
                r"Total tests:\s*(\d+),\s*passed:\s*(\d+),\s*failed:\s*0",
                result.stdout.decode("utf-8", "replace"),
            )
            self.assertIsNotNone(summary, result.stdout)
            self.assertGreater(int(summary.group(1)), 0, "fixture has no runtime tests")
            self.assertEqual(summary.group(1), summary.group(2))

        def _module(self, directory, name, files, version="0.2.0"):
            root = self.assert_owned(self.base / directory)
            root.mkdir()
            self.write_file(
                "moon.mod", f'name = "{name}"\nversion = "{version}"\n'
                'preferred_target = "native"\n', root=root,
            )
            self.write_file("moon.pkg", "\n", root=root)
            for path, contents in files.items():
                self.write_file(path, contents, root=root)
            return root

        def _architecture_rules(self):
            return {"version": 1, "package_rules": [
                {"id": "arch/domain-ui", "severity": "error",
                 "from": [MODULE + "/domain"], "deny": [MODULE + "/ui"],
                 "reason": "Domain must not import UI"},
                {"id": "arch/ui-domain", "severity": "error",
                 "from": [MODULE + "/ui"], "allow": [MODULE + "/domain"],
                 "reason": "UI may depend on domain"},
            ]}

        def _synthetic_graph(self, *, kinds=None, target="native"):
            return {"version": 3, "status": "success", "error": None,
                    "target": target, "root": [0, 1], "logs": [],
                    "nodes": [
                        {"module": MODULE, "version": "0.2.0", "rel": rel,
                         "source": {"kind": "local", "path": str(self.root)}}
                        for rel in ("domain", "ui")
                    ],
                    "edges": [{"from": 0, "to": 1, "alias": "ui",
                               "kinds": ["source"] if kinds is None else kinds}]}

        def _graph_cli(self, graph, policy, *options):
            return self.run_cli(["--package-graph", graph, "--config", policy,
                                 *options])

        def _architecture_module(self, directory, reverse=False):
            origin, destination = ("ui", "domain") if reverse else ("domain", "ui")
            files = {
                destination + "/moon.pkg": "\n",
                destination + "/lib.mbt":
                    '///|\n/// Fixture answer.\npub fn answer() -> Int { 7 }\n',
                destination + "/lib_wbtest.mbt":
                    '///|\ntest "answer" { assert_eq(answer(), 7) }\n',
                origin + "/moon.pkg": f'import {{ "{MODULE}/{destination}", }}\n',
                origin + "/lib.mbt":
                    '///|\n/// A compiler-legal direct dependency.\n'
                    f'pub fn dependent() -> Int {{ @{destination}.answer() }}\n',
                origin + "/lib_wbtest.mbt":
                    '///|\ntest "dependent" { assert_eq(dependent(), 7) }\n',
            }
            root = self._module(directory, MODULE, files)
            self._compiler_check_test(root)
            result = self._compiler(root, "tree", "--package", "--json",
                                    "--target", "native")
            graph = self._decode_json(result, 0)
            self.assertEqual(graph["version"], 3)
            self.assertEqual(graph["status"], "success")
            self.assertEqual(graph["target"], "native")
            identities = {
                i: n["module"] + ("/" + n["rel"] if n["rel"] else "")
                for i, n in enumerate(graph["nodes"])
            }
            self.assertTrue(any(
                identities[e["from"]] == MODULE + "/" + origin and
                identities[e["to"]] == MODULE + "/" + destination and
                "source" in e["kinds"] for e in graph["edges"]
            ), graph)
            return self._json_file(directory + "-graph.json", graph)

        def _snapshot(self, interface, version="0.2.0", name="snapshot.json"):
            result = self.run_cli([
                "--api-snapshot", interface, "--api-toolchain", "moon-native-fixture",
                "--api-backend", "native", "--api-module-version", version,
            ])
            value = self._decode_json(result, 0)
            self.assertEqual(set(value), {"version", "package", "toolchain", "backend",
                                          "module_version", "interface"})
            self.assertEqual(value["version"], 1)
            self.assertEqual(value["toolchain"], "moon-native-fixture")
            self.assertEqual(value["backend"], "native")
            self.assertEqual(value["module_version"], version)
            self.assertEqual(value["interface"], Path(interface).read_text(encoding="utf-8"))
            return self.write_file(name, result.stdout.decode("utf-8"), root=self.base)

        def _interface(self, name, declarations):
            return self.write_file(
                name, 'package "fixture/api"\n\n' + declarations, root=self.base,
            )

        def _api_cli(self, before, after, *options):
            return self.run_cli(["--api-check", before, after, *options])

        def _baseline_rule(self, *, warning=False):
            rules = [{"id": RULE_ID, "severity": "error", "message": "Reviewed fixture debt",
                      "extensions": [".ts"], "match": {"contains": TOKEN}}]
            if warning:
                rules.append({"id": "policy/warning", "severity": "warning",
                              "message": "Warning fixture debt", "extensions": [".ts"],
                              "match": {"contains": "WARNING"}})
            self.write_config(rules=rules)

        def _capture_v2(self, *, expires=None, errors_only=False):
            arguments = ["--update-baseline", "--baseline-format", "v2",
                         "--baseline-reason", 'Reviewed "existing debt" — 批准',
                         "--baseline-owner", "fixture-maintainer", "--baseline", self.baseline]
            if expires is not None:
                arguments.extend(["--baseline-expires", expires])
            if errors_only:
                arguments.append("--errors-only")
            # Baseline creation is a write operation, not a CI approval verdict.
            self.assert_exit(self.invoke(*arguments), 0)
            value = json.loads(self.baseline.read_text(encoding="utf-8"))
            self.assertEqual(value["version"], 2)
            self.assertEqual(value["fingerprint"], "moonlint-content-v2")
            self.assertIsInstance(value["entries"], list)
            for entry in value["entries"]:
                self.assertEqual(entry["reason"], 'Reviewed "existing debt" — 批准')
                self.assertEqual(entry["owner"], "fixture-maintainer")
                self.assertEqual(entry["expires"], expires)
                self.assertRegex(entry["key"], r"^[0-9a-f]{16}$")
                self.assertGreater(entry["count"], 0)
            return value

        def _audit(self, today, *options):
            return self.invoke("--audit-baseline", "--baseline", self.baseline,
                               "--baseline-today", today, *options)

        def _lex_config(self, *, docs=False, whitespace=False):
            structural = []
            if docs:
                structural.append({"id": "lex/docs", "severity": "error",
                                   "message": "Public documentation required",
                                   "extensions": [".mbt"],
                                   "check": {"moonbit_require_public_doc": True}})
            elif not whitespace:
                for name in ("unwrap", "panic", "println"):
                    structural.append({"id": "lex/" + name, "severity": "error",
                                       "message": "Code call requires review",
                                       "extensions": [".mbt"],
                                       "check": {"moonbit_no_" + name: True}})
            file_rules = []
            if whitespace:
                for name, check in (("trailing", "no_trailing_whitespace"),
                                    ("tabs", "no_tabs"), ("newline", "final_newline")):
                    file_rules.append({"id": "fix/" + name, "severity": "error",
                                       "message": "Whitespace policy", "extensions": [".mbt"],
                                       "include": ["lib.mbt"], "check": {check: True}})
            self.write_config(rules=[], structural_rules=structural, file_rules=file_rules)

        def test_real_compiler_graph_allows_acyclic_dependency_but_policy_blocks_it(self):
            graph = self._architecture_module("architecture-denied")
            policy = self._json_file("package-policy.json", self._architecture_rules())
            value = self._policy_json(
                self._graph_cli(graph, policy, "--format", "json"), 1, "package-policy")
            self.assertEqual(value["counts"]["edges_checked"], 1)
            self.assertGreaterEqual(value["counts"]["packages"], 2)
            self.assertEqual(len(value["findings"]), 1)
            finding = value["findings"][0]
            self.assertEqual(finding["rule_id"], "arch/domain-ui")
            self.assertEqual(finding["details"], {
                "from": MODULE + "/domain", "to": MODULE + "/ui", "kind": "source",
                "target": "native", "alias": "ui", "reason": "Domain must not import UI",
            })
            self.assertIn("stdlib", value["metadata"]["coverage"])

        def test_real_compiler_reverse_ui_to_domain_is_checked_and_allowed(self):
            graph = self._architecture_module("architecture-allowed", reverse=True)
            policy = self._json_file("package-policy.json", self._architecture_rules())
            value = self._policy_json(
                self._graph_cli(graph, policy, "--format", "json"), 0, "package-policy")
            self.assertEqual(value["findings"], [])
            self.assertEqual(value["counts"]["edges_checked"], 1)
            self.assertEqual(value["metadata"]["applicability"], "checked")

        def test_graph_edge_kinds_targets_and_no_applicability_are_explicit(self):
            graph = self._json_file("graph.json", self._synthetic_graph(
                kinds=["blackbox-test", "whitebox-test"]))
            rules = self._architecture_rules()
            policy = self._json_file("package-policy.json", rules)
            value = self._policy_json(
                self._graph_cli(graph, policy, "--format", "json"), 0, "package-policy")
            self.assertEqual(value["counts"]["edges_checked"], 0)
            self.assertEqual(value["metadata"]["applicability"], "no-applicable-edges")
            rules["package_rules"][0]["kinds"] = ["test", "wbtest"]
            policy = self._json_file("package-policy.json", rules)
            value = self._policy_json(
                self._graph_cli(graph, policy, "--format", "json"), 1, "package-policy")
            self.assertEqual(value["counts"]["edges_checked"], 2)
            self.assertEqual({f["details"]["kind"] for f in value["findings"]}, {"test", "wbtest"})
            rules["package_rules"][0]["severity"] = "warning"
            policy = self._json_file("package-policy.json", rules)
            value = self._policy_json(
                self._graph_cli(graph, policy, "--format", "json"), 0, "package-policy")
            self.assertEqual(value["counts"]["warnings"], 2)
            self.assertEqual(value["counts"]["errors"], 0)
            filtered = self._policy_json(self._graph_cli(
                graph, policy, "--errors-only", "--format", "json"), 0, "package-policy")
            self.assertEqual(filtered["findings"], [])
            self.assertEqual(filtered["counts"]["edges_checked"], 2)
            for rule in rules["package_rules"]:
                rule["targets"] = ["js"]
            policy = self._json_file("package-policy.json", rules)
            value = self._policy_json(
                self._graph_cli(graph, policy, "--format", "json"), 0, "package-policy")
            self.assertEqual(value["counts"]["edges_checked"], 0)
            self.assertEqual(value["metadata"]["applicability"], "no-rules-for-target")

        def test_graph_text_json_github_and_sarif_do_not_invent_source_locations(self):
            graph = self._json_file("graph.json", self._synthetic_graph())
            policy = self._json_file("package-policy.json", self._architecture_rules())
            value = self._policy_json(
                self._graph_cli(graph, policy, "--format", "json"), 1, "package-policy")
            self.assertEqual(value["counts"]["errors"], 1)
            text = self._graph_cli(graph, policy, "--format", "text")
            self.assert_exit(text, 1)
            self.assertIn("package-policy", self.output(text))
            self.assertIn("arch/domain-ui", self.output(text))
            github = self._graph_cli(graph, policy, "--format", "github")
            self.assert_exit(github, 1)
            annotations = [s for s in self.output(github).splitlines() if s.startswith("::error")]
            self.assertEqual(len(annotations), 1)
            self.assertIn("title=arch/domain-ui", annotations[0])
            self.assertNotIn("file=", annotations[0])
            self.assertNotIn("line=", annotations[0])
            run = self._sarif(self._graph_cli(graph, policy, "--format", "sarif"),
                              1, {"arch/domain-ui"}, "package-policy")
            self.assertEqual(run["results"][0]["properties"]["from"], MODULE + "/domain")

        def test_graph_schema_rule_schema_and_conflicting_cli_modes_fail_closed(self):
            graph_value = self._synthetic_graph()
            rules = self._architecture_rules()
            graph = self._json_file("graph.json", graph_value)
            policy = self._json_file("package-policy.json", rules)
            for field, invalid in (("version", 4), ("version", 3.0),
                                   ("target", "future"), ("status", "failed"),
                                   ("unknown", True)):
                with self.subTest(graph_field=field, invalid=invalid):
                    bad = copy.deepcopy(graph_value)
                    bad[field] = invalid
                    path = self._json_file("bad-graph.json", bad)
                    self.assert_exit(self._graph_cli(path, policy), 2)
            bad = copy.deepcopy(graph_value)
            bad["edges"][0]["to"] = 99
            self.assert_exit(self._graph_cli(self._json_file("bad-graph.json", bad), policy), 2)
            for invalid in ({"version": 2, "package_rules": rules["package_rules"]},
                            {"version": 1, "package_rules": []},
                            {"version": 1, "package_rules": [
                                {**rules["package_rules"][0], "allow": []}]},
                            {"version": 1, "package_rules": [
                                {**rules["package_rules"][0], "unknown": True}]}):
                with self.subTest(policy=invalid):
                    self.assert_exit(self._graph_cli(
                        graph, self._json_file("bad-policy.json", invalid)), 2)
            for arguments in (["--package-graph", graph],
                              ["--package-graph", graph, "--config", policy, "--fix"],
                              ["--package-graph", graph, "--config", policy, "--stdin"],
                              ["--package-graph", graph, "--config", policy,
                               "--api-snapshot", graph],
                              ["--package-graph", self.base / "missing.json", "--config", policy]):
                with self.subTest(arguments=arguments):
                    self.assert_exit(self.run_cli(arguments), 2)

        def test_real_compiler_api_removal_blocks_default_and_zero_minor_semver_warns(self):
            before_source = ('///|\n/// Stable entry.\npub fn live() -> String { "雪" }\n'
                             '///|\n/// Removed entry.\npub fn gone(x : Int) -> Int { x + 1 }\n')
            after_source = ('///|\n/// Stable entry with an implementation-only refactor.\n'
                            'pub fn live() -> String { let value = "雪"; value }\n')
            runtime = '///|\ntest "live runtime" { assert_eq(live(), "雪") }\n'
            before_root = self._module("api-before", "fixture/api", {
                "lib.mbt": before_source, "lib_wbtest.mbt": runtime})
            after_root = self._module("api-after", "fixture/api", {
                "lib.mbt": after_source, "lib_wbtest.mbt": runtime}, version="0.3.0")
            for root in (before_root, after_root):
                self._compiler_check_test(root)
                self._compiler(root, "info", "--target", "native")
                self.assertTrue((root / "pkg.generated.mbti").is_file())
            before = self._snapshot(before_root / "pkg.generated.mbti", name="before.json")
            after = self._snapshot(after_root / "pkg.generated.mbti", version="0.3.0", name="after.json")
            value = self._policy_json(self._api_cli(before, after, "--format", "json"), 1, "api-check")
            self.assertEqual({key: value["counts"][key] for key in
                              ("exports_before", "exports_after", "removed", "changed", "added")},
                             {"exports_before": 2, "exports_after": 1,
                              "removed": 1, "changed": 0, "added": 0})
            self.assertEqual(value["metadata"]["version_policy"], "none")
            finding = value["findings"][0]
            self.assertEqual(finding["rule_id"], "api/removed")
            self.assertEqual(finding["details"]["symbol"], "fn:gone")
            self.assertGreater(int(finding["details"]["before_line"]), 0)
            self.assertNotIn("after_line", finding["details"])
            allowed = self._policy_json(self._api_cli(
                before, after, "--api-version-policy", "semver", "--format", "json"), 0, "api-check")
            self.assertEqual(allowed["counts"]["errors"], 0)
            self.assertEqual(allowed["counts"]["warnings"], 1)
            self.assertEqual(allowed["findings"][0]["severity"], "warning")
            filtered = self._policy_json(self._api_cli(
                before, after, "--api-version-policy", "semver", "--errors-only",
                "--format", "json"), 0, "api-check")
            self.assertEqual(filtered["findings"], [])

        def test_api_cosmetics_additions_and_historical_same_version_removals(self):
            original = self._interface("original.mbti",
                'pub enum Mode { Full; Incremental } derive(Eq)\n'
                'pub fn Mode::incremental() -> Mode\npub fn stay(value : Int) -> Int\n')
            reordered = self._interface("reordered.mbti",
                '// Compiler banner\npub fn stay(value:Int)->Int\n'
                '#derive(Eq)\npub enum Mode { Incremental; Full }\n'
                'pub fn Mode::incremental() -> Mode\npub fn added() -> String\n')
            before = self._snapshot(original, name="before.json")
            after = self._snapshot(reordered, name="reordered.json")
            value = self._policy_json(self._api_cli(before, after, "--format", "json"), 0, "api-check")
            self.assertEqual(value["counts"]["added"], 1)
            self.assertEqual(value["counts"]["changed"], 0)
            self.assertEqual(value["findings"], [])
            removed = self._snapshot(self._interface("removed.mbti",
                '#derive(Eq)\npub enum Mode { Full }\npub fn stay(value : Int) -> Int\n'),
                name="removed.json")
            value = self._policy_json(self._api_cli(before, removed, "--format", "json"), 1, "api-check")
            self.assertEqual(value["counts"]["removed"], 1)
            self.assertEqual(value["counts"]["changed"], 1)
            self.assertEqual({f["rule_id"] for f in value["findings"]}, {"api/removed", "api/changed"})
            value = self._policy_json(self._api_cli(before, removed,
                "--api-version-policy", "semver", "--format", "json"), 1, "api-check")
            self.assertIn("api/version-policy", {f["rule_id"] for f in value["findings"]})
            self.assertEqual(value["counts"]["warnings"], 0)

        def test_api_metadata_schema_unknown_syntax_and_arguments_are_inconclusive(self):
            interface = self._interface("api.mbti", 'pub fn live() -> Unit\n')
            snapshot = self._snapshot(interface)
            original = json.loads(snapshot.read_text(encoding="utf-8"))
            changes = [("toolchain", "different compiler"), ("backend", "js"),
                       ("version", 2), ("version", 1.0), ("version", "1"),
                       ("package", "different/package"), ("unknown", True),
                       ("interface", original["interface"] + 'pub future Extension\n')]
            for field, value in changes:
                with self.subTest(field=field, value=value):
                    bad = copy.deepcopy(original)
                    bad[field] = value
                    self.assert_exit(self._api_cli(snapshot, self._json_file("bad.json", bad)), 2)
            missing = {k: v for k, v in original.items() if k != "backend"}
            self.assert_exit(self._api_cli(snapshot, self._json_file("bad.json", missing)), 2)
            duplicate = snapshot.read_text(encoding="utf-8").replace(
                '"version": 1', '"version": 1, "version": 1', 1)
            self.assertNotEqual(duplicate, snapshot.read_text(encoding="utf-8"))
            bad = self.write_file("duplicate.json", duplicate, root=self.base)
            self.assert_exit(self._api_cli(snapshot, bad), 2)
            prerelease = copy.deepcopy(original)
            prerelease["module_version"] = "0.3.0-rc.1"
            bad = self._json_file("prerelease.json", prerelease)
            result = self._api_cli(snapshot, bad, "--api-version-policy", "semver")
            self.assert_exit(result, 2)
            self.assertIn("cannot judge prerelease policy", self.text_of(result))
            for declaration in ('pub extern fn foreign() -> Unit\n',
                                'pub fn broken() -> (Int\n',
                                'pub fn repeated() -> Unit\npub fn repeated() -> Unit\n'):
                with self.subTest(declaration=declaration):
                    bad_interface = self._interface("unsupported.mbti", declaration)
                    self.assert_exit(self.run_cli([
                        "--api-snapshot", bad_interface, "--api-toolchain", "moon",
                        "--api-backend", "native", "--api-module-version", "0.2.0"]), 2)
            for arguments in (["--api-snapshot", interface],
                              ["--api-check", snapshot],
                              ["--api-check", snapshot, snapshot, "--api-version-policy", "guess"],
                              ["--api-check", snapshot, snapshot, "--config", self.config],
                              ["--api-check", snapshot, snapshot, "--api-toolchain", "moon"],
                              ["--api-snapshot", interface, "--api-toolchain", "moon",
                               "--api-backend", "unknown", "--api-module-version", "0.2.0"]):
                with self.subTest(arguments=arguments):
                    self.assert_exit(self.run_cli(arguments), 2)

        def test_api_formats_retain_symbol_properties_without_virtual_locations(self):
            before = self._snapshot(self._interface("before.mbti", 'pub fn gone() -> Unit\n'),
                                    name="before.json")
            after = self._snapshot(self._interface("after.mbti", ''), name="after.json")
            value = self._policy_json(self._api_cli(before, after, "--format", "json"), 1, "api-check")
            self.assertEqual(value["findings"][0]["details"]["symbol"], "fn:gone")
            result = self._api_cli(before, after, "--format", "github")
            self.assert_exit(result, 1)
            annotation = next(s for s in self.output(result).splitlines() if s.startswith("::error"))
            self.assertIn("title=api/removed", annotation)
            self.assertNotIn("file=", annotation)
            self.assertNotIn("line=", annotation)
            run = self._sarif(self._api_cli(before, after, "--format", "sarif"),
                              1, {"api/removed"}, "api-check")
            self.assertEqual(run["results"][0]["properties"]["symbol"], "fn:gone")
            result = self._api_cli(before, after, "--format", "text")
            self.assert_exit(result, 1)
            self.assertIn("fn:gone", self.output(result))
            self.assertIn("coverage:", self.output(result))

        def test_real_compiler_calls_in_code_not_docs_literals_or_declarations(self):
            source = r'''///|
struct Item { text : String }
///|
fn Item::panic(self : Item) -> String { self.text }
///|
fn Item::println(self : Item) -> String { self.text }
///|
fn Item::unwrap(self : Item) -> String { self.text }
///|
/// Prose: panic() println() value.unwrap() are not executable calls.
pub fn texts() -> (String, String) {
  let quoted = "panic() println() value.unwrap()"
  let raw =
    #|panic() println() value.unwrap() { } // literal
  (quoted, raw)
}
///|
fn calls(value : Int?) -> (String, String) {
  ignore("prefix"); ignore(value.unwrap())
  let quoted = "\{value.unwrap()}"
  let interpolated =
    $|value \{value.unwrap()}
  (quoted, interpolated)
}
///|
fn qualified(value : Item) -> Unit {
  ignore(Item::panic(value)); ignore(Item::println(value))
}
///|
fn loud() -> Unit { ignore("prefix"); println("output") }
///|
fn never() -> Unit { ignore("prefix"); panic() }
'''
            runtime = r'''///|
test "call values" {
  assert_eq(calls(Some(7)), ("7", "value 7"))
  let (quoted, raw) = texts()
  assert_eq(quoted, "panic() println() value.unwrap()")
  assert_eq(raw, "panic() println() value.unwrap() { } // literal")
}
'''
            root = self._module("lex-calls", "fixture/lex", {"lib.mbt": source,
                                                               "lib_wbtest.mbt": runtime})
            self._compiler_check_test(root)
            self._lex_config()
            value = self._lint_json(self.invoke("--format", "json", root=root), 1)
            findings = value["findings"]
            self.assertEqual(len(findings), 5)
            self.assertEqual({rule: sum(f["rule_id"] == rule for f in findings)
                              for rule in ("lex/unwrap", "lex/panic", "lex/println")},
                             {"lex/unwrap": 3, "lex/panic": 1, "lex/println": 1})
            expected_lines = {i for i, line in enumerate(source.splitlines(), 1)
                              if 'ignore(value.unwrap())' in line or
                              'let quoted = "\\{value.unwrap()}"' in line or
                              '$|value \\{value.unwrap()}' in line}
            self.assertEqual({f["line"] for f in findings if f["rule_id"] == "lex/unwrap"},
                             expected_lines)
            self.assertEqual(len(expected_lines), 3)
            for finding in findings:
                self.assertEqual(finding["file"], "lib.mbt")
                self.assertGreater(finding["column"], 1)
            self.assertFalse(any("Prose:" in f["snippet"] or "fn Item::" in f["snippet"]
                                 for f in findings))

        def test_real_compiler_safe_fix_preserves_literal_bytes_crlf_and_runtime(self):
            raw_lines = ["#|雪 // value.unwrap()   \t", "#|第二行 panic()     "]
            rich_lines = [r'$|值 \{"白"} println()   ' + "\t", "$|尾巴 { }     "]
            quoted = "é😀\t #| value.unwrap()"
            lines = ["///|", "/// Literal payload fixture.",
                     "pub fn payloads() -> (String, String, String) {   ", "\tlet raw ="]
            lines.extend("\t  " + line for line in raw_lines)
            lines.append("\tlet rich =")
            lines.extend("\t  " + line for line in rich_lines)
            lines.extend([f'\tlet quoted = "{quoted}"   ', "\t(raw, rich, quoted)", "}   "])
            source = "\r\n".join(lines)
            expected = ["///|", 'test "unchanged runtime payloads" {',
                        "  let (raw, rich, quoted) = payloads()", "  let expected_raw ="]
            expected.extend("    " + line for line in raw_lines)
            expected.append("  let expected_rich =")
            expected.extend("    " + line for line in rich_lines)
            expected.extend(["  assert_eq(raw, expected_raw)", "  assert_eq(rich, expected_rich)",
                             f'  assert_eq(quoted, "{quoted}")',
                             '  assert_true(raw.contains("雪"))',
                             '  assert_true(rich.has_suffix("     "))', "}", ""])
            root = self._module("lex-fix", "fixture/fix", {})
            path = self.assert_owned(root / "lib.mbt")
            path.write_bytes(source.encode("utf-8"))
            runtime = self.assert_owned(root / "lib_wbtest.mbt")
            runtime.write_bytes("\r\n".join(expected).encode("utf-8"))
            before, runtime_before = path.read_bytes(), runtime.read_bytes()
            self._compiler_check_test(root)
            self._lex_config(whitespace=True)
            dry_run = self._lint_json(self.invoke("--fix", "--dry-run", "--fix-tab-width", "4",
                                                  "--format", "json", root=root), 1)
            self.assertGreaterEqual(dry_run["counts"]["errors"], 2)
            self.assertEqual(path.read_bytes(), before)
            value = self._lint_json(self.invoke("--fix", "--fix-tab-width", "4",
                                                "--format", "json", root=root), 1)
            # FileCheck is a whole-file policy. Literal whitespace can remain
            # reportable even though the safe fixer must not change its value.
            expected_remaining = set()
            for number, line in enumerate(lines, 1):
                token = line.lstrip(" \t")
                if token.startswith(("#|", "$|")):
                    expected_remaining.add(("fix/trailing", number))
                    if "\t" in token:
                        expected_remaining.add(("fix/tabs", number))
                elif "let quoted =" in line:
                    expected_remaining.add(("fix/tabs", number))
            self.assertEqual({(f["rule_id"], f["line"]) for f in value["findings"]},
                             expected_remaining)
            self.assertEqual(len(value["findings"]), len(expected_remaining))
            self.assertEqual({f["file"] for f in value["findings"]}, {"lib.mbt"})
            after = path.read_bytes()
            self.assertNotEqual(after, before, "fix must actually change code whitespace")
            def payloads(data):
                return [line.lstrip(b" \t") for line in data.splitlines(keepends=True)
                        if line.lstrip(b" \t").startswith((b"#|", b"$|"))]
            self.assertEqual(payloads(after), payloads(before))
            self.assertIn(quoted.encode("utf-8"), after)
            self.assertIn(b"\r\n", after)
            self.assertNotIn(b"\n", after.replace(b"\r\n", b""))
            self.assertTrue(after.endswith(b"}\r\n"))
            self.assertIn(b"    let raw =\r\n", after)
            self.assertEqual(runtime.read_bytes(), runtime_before)
            self._compiler_check_test(root)
            repeated = self._lint_json(self.invoke("--fix", "--fix-tab-width", "4",
                                                    "--format", "json", root=root), 1)
            self.assertEqual({(f["rule_id"], f["line"]) for f in repeated["findings"]},
                             expected_remaining)
            self.assertEqual(path.read_bytes(), after)
            # A final raw literal is valid source; adding a final newline must
            # never extend its payload. The compiler checks both runtime values.
            eof_root = self._module("lex-raw-eof", "fixture/eof", {
                "lib_wbtest.mbt": '///|\ntest "raw EOF value" { assert_eq(end_value, "EOF 雪  \t  ") }\n',
            })
            eof_path = self.assert_owned(eof_root / "lib.mbt")
            eof_path.write_bytes('let end_value : String =\r\n  #|EOF 雪  \t  '.encode("utf-8"))
            eof_before = eof_path.read_bytes()
            self._compiler_check_test(eof_root)
            eof_result = self._lint_json(self.invoke("--fix", "--fix-tab-width", "4",
                                                     "--format", "json", root=eof_root), 1)
            self.assertIn("fix/newline", {f["rule_id"] for f in eof_result["findings"]})
            self.assertEqual(eof_path.read_bytes(), eof_before)
            self._compiler_check_test(eof_root)

        def test_public_suberror_empty_documentation_and_block_markers_are_reported(self):
            self._lex_config(docs=True)
            source = ('pub(all) suberror MissingError { MissingError(String) }\n'
                      '///|\npub fn empty_marker() -> Unit { () }\n'
                      '///|\n///   \npub struct EmptyDoc { value : String }\n'
                      '///|\n/// Real error documentation.\n'
                      'pub(all) suberror GoodError { GoodError(String) }\n'
                      '///|\n/// Real function documentation.\npub fn good() -> Unit { () }\n')
            self.write_file("public.mbt", source)
            value = self._lint_json(self.invoke("--format", "json"), 1)
            self.assertEqual(len(value["findings"]), 3)
            self.assertEqual({f["line"] for f in value["findings"]}, {1, 3, 6})
            self.assertEqual({f["rule_id"] for f in value["findings"]}, {"lex/docs"})
            self.assertTrue(any("MissingError" in f["message"] for f in value["findings"]))
            self.assertFalse(any("GoodError" in f["message"] or "good" == f["snippet"]
                                 for f in value["findings"]))

        def test_v2_content_moves_preserve_count_budget_but_new_copies_and_renames_do_not(self):
            self._baseline_rule()
            path = self.write_file("debt.ts", (TOKEN + "\n") * 2)
            value = self._capture_v2()
            self.assertEqual(len(value["entries"]), 1)
            self.assertEqual(value["entries"][0]["count"], 2)
            before = self.baseline.read_bytes()
            self._capture_v2()
            self.assertEqual(self.baseline.read_bytes(), before)
            self.write_file("debt.ts", "// moved\n// padded\n// again\n" + (TOKEN + "\n") * 2)
            value = self._lint_json(self.invoke("--baseline", self.baseline, "--format", "json"), 0)
            self.assertEqual(value["scan"]["baseline_suppressed"], 2)
            self.assertEqual(value["findings"], [])
            self.write_file("debt.ts", path.read_text(encoding="utf-8") + TOKEN + "\n")
            value = self._lint_json(self.invoke("--baseline", self.baseline, "--format", "json"), 1)
            self.assertEqual(value["scan"]["baseline_suppressed"], 2)
            self.assertEqual(len(value["findings"]), 1)
            self.assertEqual(value["findings"][0]["line"], 6)
            self.assertEqual(self.baseline.read_bytes(), before)
            self.write_file("debt.ts", "SAFE\n")
            self.write_file("renamed.ts", (TOKEN + "\n") * 2)
            value = self._lint_json(self.invoke("--baseline", self.baseline, "--format", "json"), 1)
            self.assertEqual(value["scan"]["baseline_suppressed"], 0)
            self.assertEqual(len(value["findings"]), 2)
            self.assertEqual({f["file"] for f in value["findings"]}, {"renamed.ts"})
            audit = self._policy_json(self._audit("2024-02-29", "--format", "json"),
                                      1, "baseline-audit")
            self.assertEqual(audit["counts"]["unused_entries"], 1)
            self.assertIn("baseline/unused", {f["rule_id"] for f in audit["findings"]})

        def test_v2_audit_full_tree_expiry_boundary_unused_entries_and_unused_count(self):
            self._baseline_rule()
            self.write_file("src/debt.ts", (TOKEN + "\n") * 2)
            self.write_file("outside/debt.ts", TOKEN + "\n")
            self._capture_v2(expires="2024-02-29")
            value = self._policy_json(self._audit("2024-02-29", "--format", "json"),
                                      0, "baseline-audit")
            self.assertEqual(value["counts"]["suppressed"], 3)
            self.assertEqual(value["counts"]["unused_entries"], 0)
            self.assertEqual(value["counts"]["expired_entries"], 0)
            self.assertEqual(value["counts"]["unused_occurrences"], 0)
            self.write_file("src/debt.ts", TOKEN + "\n")
            value = self._policy_json(self._audit("2024-02-29", "--format", "json"),
                                      1, "baseline-audit")
            self.assertEqual(value["counts"]["suppressed"], 2)
            self.assertEqual(value["counts"]["unused_entries"], 0)
            self.assertEqual(value["counts"]["unused_occurrences"], 1)
            self.assertIn("baseline/unused-budget", {f["rule_id"] for f in value["findings"]})
            self._sarif(self._audit("2024-02-29", "--format", "sarif"),
                        1, {"baseline/unused-budget"}, "baseline-audit")
            value = self._policy_json(self._audit("2024-03-01", "--format", "json"),
                                      1, "baseline-audit")
            self.assertEqual(value["counts"]["suppressed"], 0)
            self.assertEqual(value["counts"]["expired_entries"], 2)
            self.assertEqual(value["counts"]["unused_entries"], 0)
            self.assertEqual(sum(f["rule_id"] == "baseline/expired" for f in value["findings"]), 2)
            self.write_file("outside/debt.ts", "SAFE\n")
            value = self._policy_json(self._audit("2024-03-01", "--format", "json"),
                                      1, "baseline-audit")
            self.assertEqual(value["counts"]["expired_entries"], 2)
            self.assertEqual(value["counts"]["unused_entries"], 1)
            ids = {f["rule_id"] for f in value["findings"]}
            self.assertTrue({"baseline/expired", "baseline/unused"}.issubset(ids))

        def test_v2_capture_raw_warnings_and_strict_schema_metadata_and_cli_safety(self):
            self._baseline_rule(warning=True)
            self.write_file("debt.ts", TOKEN + "\nWARNING\n")
            valid = self._capture_v2(errors_only=True)
            self.assertEqual({e["rule_id"] for e in valid["entries"]}, {RULE_ID, "policy/warning"})
            self.assertEqual(len(valid["entries"]), 2)
            original = self.baseline.read_bytes()
            value = self._lint_json(self.invoke("--baseline", self.baseline, "--format", "json"), 0)
            self.assertEqual(value["scan"]["baseline_suppressed"], 2)
            mutants = []
            for field, value in (("version", 3), ("fingerprint", "future"), ("unknown", True)):
                bad = copy.deepcopy(valid)
                bad[field] = value
                mutants.append(bad)
            for field, value in (("count", 0), ("count", 1.5), ("count", "1"),
                                 ("owner", " "), ("reason", ""),
                                 ("expires", "2024-02-30"), ("key", "not-a-hash"),
                                 ("unknown", True)):
                bad = copy.deepcopy(valid)
                bad["entries"][0][field] = value
                mutants.append(bad)
            bad = copy.deepcopy(valid)
            bad["entries"].append(copy.deepcopy(bad["entries"][0]))
            mutants.append(bad)
            for invalid in mutants:
                with self.subTest(baseline=invalid):
                    self.baseline.write_text(json.dumps(invalid), encoding="utf-8")
                    before = self.baseline.read_bytes()
                    self.assert_exit(self.invoke("--baseline", self.baseline), 2)
                    self.assertEqual(self.baseline.read_bytes(), before)
            self.baseline.write_bytes(original)
            duplicate = original.decode("utf-8").replace('"version": 2', '"version": 2, "version": 2', 1)
            self.assertNotEqual(duplicate, original.decode("utf-8"))
            self.baseline.write_text(duplicate, encoding="utf-8")
            self.assert_exit(self.invoke("--baseline", self.baseline), 2)
            self.baseline.write_bytes(original)
            update = ["--update-baseline", "--baseline-format", "v2", "--baseline", self.baseline]
            unsafe = [update,
                      update + ["--baseline-reason", "R"],
                      update + ["--baseline-owner", "O"],
                      update + ["--baseline-reason", "R", "--baseline-owner", " "],
                      update + ["--baseline-reason", "R", "--baseline-owner", "O",
                                "--baseline-expires", "2023-02-29"],
                      update + ["--baseline-reason", "R", "--baseline-owner", "O", "--glob", "src/**"],
                      ["--audit-baseline", "--baseline", self.baseline, "--baseline-today", "2024-02-30"],
                      ["--audit-baseline", "--baseline", self.baseline, "--baseline-today", "2024-02-29",
                       "--glob", "src/**"],
                      ["--audit-baseline", "--baseline", self.baseline, "--baseline-today", "2024-02-29",
                       "--ext", ".ts"],
                      ["--baseline-format", "future", "--baseline", self.baseline],
                      ["--baseline-reason", "R", "--baseline", self.baseline]]
            for arguments in unsafe:
                with self.subTest(arguments=arguments):
                    self.assert_exit(self.invoke(*arguments), 2)
                    self.assertEqual(self.baseline.read_bytes(), original)
            self.assert_exit(self.invoke("--baseline", self.baseline), 0)

        def test_legacy_baseline_requires_explicit_migration_and_does_not_approve_new_debt(self):
            self._baseline_rule()
            self.write_file("accepted.ts", TOKEN + "\n")
            self.assert_exit(self.invoke("--baseline", self.baseline, "--update-baseline"), 0)
            legacy = json.loads(self.baseline.read_text(encoding="utf-8"))
            self.assertIsInstance(legacy, list)
            self.assertEqual(len(legacy), 1)
            legacy.append("0000000000000000")  # Valid but stale: never migrate phantom debt.
            self.baseline.write_text(json.dumps(legacy) + "\n", encoding="utf-8")
            original = self.baseline.read_bytes()
            value = self._lint_json(self.invoke("--baseline", self.baseline, "--format", "json"), 0)
            self.assertEqual(value["scan"]["baseline_suppressed"], 1)
            self.assertEqual(self.baseline.read_bytes(), original)
            self.write_file("accepted.ts", "SAFE\n" + TOKEN + "\n")
            value = self._lint_json(self.invoke("--baseline", self.baseline, "--format", "json"), 1)
            self.assertEqual(value["scan"]["baseline_suppressed"], 0)
            self.assertEqual(len(value["findings"]), 1)
            self.write_file("accepted.ts", TOKEN + "\n")
            self.write_file("new.ts", TOKEN + "\n")
            for arguments in (["--migrate-baseline", "--baseline", self.baseline],
                              ["--migrate-baseline", "--baseline", self.baseline,
                               "--baseline-reason", "R", "--baseline-owner", "O", "--glob", "*.ts"]):
                with self.subTest(arguments=arguments):
                    self.assert_exit(self.invoke(*arguments), 2)
                    self.assertEqual(self.baseline.read_bytes(), original)
            value = self._lint_json(self.invoke(
                "--migrate-baseline", "--baseline", self.baseline,
                "--baseline-reason", "Migrated accepted debt", "--baseline-owner", "reviewer",
                "--format", "json"), 1)
            self.assertEqual(value["scan"]["baseline_suppressed"], 1)
            self.assertEqual(len(value["findings"]), 1)
            self.assertEqual(value["findings"][0]["file"], "new.ts")
            migrated = json.loads(self.baseline.read_text(encoding="utf-8"))
            self.assertEqual(migrated["version"], 2)
            self.assertEqual(len(migrated["entries"]), 1)
            self.assertEqual(migrated["entries"][0]["file"], "accepted.ts")
            self.assertEqual(migrated["entries"][0]["count"], 1)
            migrated_bytes = self.baseline.read_bytes()
            value = self._lint_json(self.invoke("--baseline", self.baseline, "--format", "json"), 1)
            self.assertEqual(value["scan"]["baseline_suppressed"], 1)
            self.assertEqual({f["file"] for f in value["findings"]}, {"new.ts"})
            self.assert_exit(self.invoke("--migrate-baseline", "--baseline", self.baseline,
                                        "--baseline-reason", "R", "--baseline-owner", "O"), 2)
            self.assertEqual(self.baseline.read_bytes(), migrated_bytes)
            self.write_file("new.ts", "SAFE\n")
            clean = self._lint_json(self.invoke("--baseline", self.baseline, "--format", "json"), 0)
            self.assertEqual(clean["findings"], [])
            self.assertEqual(clean["scan"]["baseline_suppressed"], 1)
            self.assertEqual(self.baseline.read_bytes(), migrated_bytes)
            audit = self._policy_json(self._audit("2024-02-29", "--format", "json"),
                                      0, "baseline-audit")
            self.assertEqual(audit["counts"]["suppressed"], 1)
            self.assertEqual(audit["counts"]["unsuppressed"], 0)
            self.assertEqual(audit["counts"]["unused_occurrences"], 0)

    return PolicyTests
