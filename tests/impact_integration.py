#!/usr/bin/env python3
"""Isolated MoonImpact CLI regressions; never mutates the real target project.

python3 tests/impact_integration.py --binary /absolute/path/to/impact/main.exe
An already-built executable is required. No dependencies are installed.
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


class ImpactCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moonimpact-integration-")
        self.owner = Path(self.temp.name).resolve()
        self.addCleanup(self.cleanup_owned)
        self.root = self.owner / "project"
        self.root.mkdir()
        self.config = self.owner / "moonimpact.json"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull, "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        })
        self.settings = {"version": 1, "include": ["src/**", "test/**"]}
        self.save_config()
        self.write("src/value.ts", "export const value = 1;\n")
        self.write("src/wrapper.ts", "import { value } from './value';\nexport const wrapped = value;\n")
        self.write("test/value.test.ts", "import { wrapped } from '../src/wrapper';\nconsole.log(wrapped);\n")
        self.write("test/other.test.ts", "const unrelated = 1;\n")

    def cleanup_owned(self):
        actual = Path(self.temp.name).resolve()
        assert actual == self.owner
        assert actual.parent == Path(tempfile.gettempdir()).resolve()
        assert actual.name.startswith("moonimpact-integration-")
        self.temp.cleanup()

    def write(self, name, content):
        path = self.root / name
        assert path.resolve().is_relative_to(self.owner)
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        return path

    def save_config(self):
        self.config.write_text(json.dumps(self.settings), encoding="utf-8")

    def invoke(self, *args, expected=0, root=None):
        result = subprocess.run(
            [str(BINARY), "plan", "--config", str(self.config), *map(str, args), str(root or self.root)],
            cwd=self.root, env=self.env, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, expected, result.stdout + "\n" + result.stderr)
        return result

    def plan(self, *args, expected=0):
        return json.loads(self.invoke(*args, "--format", "json", expected=expected).stdout)

    def invoke_bare(self, *args, expected=0):
        """Invoke without --config: MoonBit modules plan natively."""
        result = subprocess.run(
            [str(BINARY), "plan", *map(str, args), str(self.root)],
            cwd=self.root, env=self.env, text=True, capture_output=True, timeout=60,
        )
        self.assertEqual(result.returncode, expected, result.stdout + "\n" + result.stderr)
        return result

    def bare_plan(self, *args, expected=0):
        return json.loads(self.invoke_bare(*args, "--format", "json", expected=expected).stdout)

    def write_moonbit_fixture(self):
        self.write("moon.mod", 'name = "fixture/mod"\n\nversion = "0.1.0"\n')
        self.write("moon.pkg", "")
        self.write("lib.mbt", "pub fn lib() -> Int32 { 1 }\n")
        self.write("lib_test.mbt", 'test "lib" { assert_eq(lib(), 1) }\n')
        self.write("cli/moon.pkg", 'import {\n  "fixture/mod" @lib,\n}\n')
        self.write("cli/main.mbt", "fn main { println(@lib.lib()) }\n")

    def fake_runner(self, code=0):
        bindir = self.owner / "bin"
        bindir.mkdir(exist_ok=True)
        self.marker = self.owner / "executed.json"
        runner = bindir / "pnpm"
        runner.write_text(
            f"#!{sys.executable}\nimport json,os,sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['IMPACT_TEST_MARKER']).write_text(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd()}))\n"
            "print('RUNNER_STDOUT')\nprint('RUNNER_STDERR',file=sys.stderr)\n"
            f"sys.exit({code})\n", encoding="utf-8")
        runner.chmod(0o755)
        # MoonBit mode runs `moon test`; the same marker records its argv.
        moon = bindir / "moon"
        moon.write_text(runner.read_text(encoding="utf-8"), encoding="utf-8")
        moon.chmod(0o755)
        self.env["PATH"] = str(bindir) + os.pathsep + self.env.get("PATH", "")
        self.env["IMPACT_TEST_MARKER"] = str(self.marker)

    def git(self, *args):
        if shutil.which("git") is None:
            self.skipTest("Git unavailable")
        result = subprocess.run(["git", "-C", str(self.root), *args], env=self.env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def commit_fixture(self):
        self.git("init", "--initial-branch=main")
        self.git("config", "core.hooksPath", os.devnull)
        self.git("config", "commit.gpgsign", "false")
        self.git("add", ".")
        self.git("commit", "-m", "fixture")

    def test_import_chain_is_explained_without_running_anything(self):
        self.fake_runner()
        doc = self.plan("--file", "src/value.ts")
        self.assertEqual(doc["strategy"], "related")
        self.assertEqual(doc["tests"], ["test/value.test.ts"])
        self.assertEqual(len(doc["traces"][0]["chain"]), 2)
        self.assertEqual(doc["traces"][0]["chain"][0]["dependency"], "src/value.ts")
        self.assertTrue(doc["advisory"])
        self.assertEqual(doc["kind"], "test-plan")
        self.assertFalse(self.marker.exists())

    def test_file_reading_wrapper_connects_non_imported_stylesheet(self):
        self.settings["file_readers"] = ["readSource"]
        self.save_config()
        self.write("src/theme.scss", ":root { --surface: white; }\n")
        self.write("test/theme.test.ts", """import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
function readSource(file: string) { return readFileSync(resolve(process.cwd(), file), 'utf8') }
const css = readSource('src/theme.scss')
""")
        doc = self.plan("--file", "src/theme.scss")
        self.assertEqual(doc["strategy"], "related")
        self.assertEqual(doc["tests"], ["test/theme.test.ts"])
        self.assertEqual(doc["traces"][0]["chain"][0]["kind"], "read-root")

    def test_immutable_root_and_single_return_reader_are_inferred(self):
        self.write("src/theme.scss", ":root { color: red; }\n")
        self.write("test/read.test.ts", """import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
const ROOT = process.cwd()
function read(file: string) { return readFileSync(resolve(ROOT, file), 'utf8') }
const source = read('src/theme.scss')
""")
        doc = self.plan("--file", "src/theme.scss")
        self.assertEqual(doc["strategy"], "related")
        self.assertEqual(doc["tests"], ["test/read.test.ts"])
        self.assertEqual(doc["issues"], [])

    def test_module_relative_url_and_file_url_to_path(self):
        self.write("src/theme.css", ":root { color: red; }\n")
        self.write("test/url.test.ts", """import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
const input = new URL('../src/theme.css', import.meta.url)
const source = readFileSync(fileURLToPath(input), 'utf8')
""")
        doc = self.plan("--file", "src/theme.css")
        self.assertEqual(doc["strategy"], "related")
        self.assertEqual(doc["tests"], ["test/url.test.ts"])
        self.assertEqual(doc["traces"][0]["chain"][0]["kind"], "read-file")

    def test_dirname_reads_have_file_relative_evidence(self):
        self.write("src/theme.css", ":root { color: red; }\n")
        self.write("test/dirname.test.ts", """import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
const source = readFileSync(resolve(__dirname, '../src/theme.css'), 'utf8')
""")
        doc = self.plan("--file", "src/theme.css")
        self.assertEqual(doc["strategy"], "related")
        self.assertEqual(doc["tests"], ["test/dirname.test.ts"])
        self.assertEqual(doc["traces"][0]["chain"][0]["kind"], "read-file")

    def test_reader_with_side_effects_or_dynamic_path_still_falls_back(self):
        self.write("test/read.test.ts", """import { readFileSync } from 'node:fs'
function read(file: string) { readFileSync(otherPath, 'utf8'); return readFileSync(file, 'utf8') }
const source = read('src/value.ts')
""")
        doc = self.plan("--file", "src/value.ts")
        self.assertEqual(doc["strategy"], "full")
        self.assertTrue(doc["issues"])

    def test_mutated_filesystem_namespace_does_not_authorize_selection(self):
        self.write("test/read.test.ts", """import fs from 'node:fs'
fs.readFileSync = replacement
const source = fs.readFileSync('src/value.ts', 'utf8')
""")
        doc = self.plan("--file", "src/value.ts")
        self.assertEqual(doc["strategy"], "full")
        self.assertTrue(doc["issues"])

    def test_transitive_vue_sass_and_font_dependency(self):
        self.settings["aliases"] = {"@": "src"}
        self.save_config()
        self.write("src/Card.vue", "<template><view>Card</view></template>\n<style lang=\"scss\">\n@use '@/styles/theme' as *;\n</style>\n")
        self.write("src/styles/theme.scss", "@use './palette' as *;\n@import './fonts.css';\n")
        self.write("src/styles/_palette.scss", "$color: red;\n")
        self.write("src/styles/fonts.css", "@font-face { src: url('./font.woff2?v=1#glyph'); }\n")
        self.write("src/styles/font.woff2", b"\x00\xff\x01binary font input")
        self.write("test/card.test.ts", "import Card from '../src/Card.vue';\nconsole.log(Card);\n")
        doc = self.plan("--file", "src/styles/font.woff2")
        self.assertEqual(doc["strategy"], "related")
        self.assertEqual(doc["tests"], ["test/card.test.ts"])
        chain = doc["traces"][0]["chain"]
        self.assertEqual(len(chain), 4)
        self.assertEqual(chain[0]["dependency"], "src/styles/font.woff2")
        self.assertEqual(chain[0]["kind"], "style-url")
        self.assertEqual(doc["issues"], [])
        partial = self.plan("--file", "src/styles/_palette.scss")
        self.assertEqual(partial["tests"], ["test/card.test.ts"])

    def test_unsupported_style_input_keeps_full_fallback(self):
        self.write("src/theme.scss", "@use '#{selected}/theme';\n")
        self.write("test/style.test.ts", "import '../src/theme.scss';\n")
        doc = self.plan("--file", "src/value.ts")
        self.assertEqual(doc["strategy"], "full")
        self.assertTrue(doc["issues"])

    def test_unreadable_stylesheet_blocks_execution(self):
        self.fake_runner()
        self.write("src/theme.scss", b"\xff\xfe invalid stylesheet")
        doc = self.plan("--file", "src/value.ts", "--run", expected=2)
        self.assertEqual(doc["strategy"], "blocked")
        self.assertFalse(self.marker.exists())

    def test_dynamic_dependency_requests_all_tests(self):
        self.write("src/wrapper.ts", "export const load = () => import(runtimePath);\n")
        doc = self.plan("--file", "src/value.ts")
        self.assertEqual(doc["strategy"], "full")
        self.assertEqual(doc["tests"], doc["inventory"])
        self.assertGreater(len(doc["issues"]), 0)

    def test_alias_and_vue_script_are_supported(self):
        self.settings["aliases"] = {"@": "src"}
        self.save_config()
        self.write("src/Card.vue", "<template><view>Card</view></template>\n<script setup lang=\"ts\">\nimport { value } from '@/value';\n</script>\n")
        self.write("test/card.test.ts", "import Card from '../src/Card.vue';\nconsole.log(Card);\n")
        doc = self.plan("--file", "src/value.ts")
        self.assertEqual(doc["strategy"], "related")
        self.assertIn("test/card.test.ts", doc["tests"])

    def test_membership_covers_reads_outside_the_analysis_scope(self):
        self.write("docs/data.json", '{"a":1}\n')
        self.write(
            "test/other.test.ts",
            "import { readFileSync } from 'node:fs'\nimport { join } from 'node:path'\n"
            "const data = readFileSync(join(__dirname, '../docs/data.json'), 'utf8')\nconsole.log(data);\n",
        )
        doc = self.plan("--file", "docs/data.json")
        self.assertEqual(doc["strategy"], "related")
        self.assertEqual(doc["tests"], ["test/other.test.ts"])
        self.assertEqual(doc["issues"], [])

    def test_directory_read_depends_on_every_current_entry(self):
        self.write(
            "test/dir.test.ts",
            "import { readdirSync } from 'node:fs'\nfor (const e of readdirSync('src')) console.log(e);\n",
        )
        self.write("src/other.ts", "export const other = 2;\n")
        doc = self.plan("--file", "src/other.ts")
        self.assertEqual(doc["strategy"], "related")
        self.assertIn("test/dir.test.ts", doc["tests"])
        chain = [t for t in doc["traces"] if t["test"] == "test/dir.test.ts"][0]["chain"]
        self.assertEqual(chain[0]["kind"], "read-dir-root")

    def test_existence_check_covers_a_path_that_does_not_exist_yet(self):
        self.write(
            "test/exists.test.ts",
            "import { existsSync } from 'node:fs'\nif (existsSync('config/optional.json')) console.log(1);\n",
        )
        dormant = self.plan("--file", "src/value.ts")
        self.assertEqual(dormant["strategy"], "related")
        self.assertNotIn("test/exists.test.ts", dormant["tests"])
        self.write("config/optional.json", "{}\n")
        live = self.plan("--file", "config/optional.json")
        self.assertEqual(live["strategy"], "related")
        self.assertEqual(live["tests"], ["test/exists.test.ts"])

    def test_literal_glob_import_expands_against_membership(self):
        self.write(
            "test/glob.test.ts",
            "const mods = import.meta.glob('../src/*.ts')\nconsole.log(mods);\n",
        )
        doc = self.plan("--file", "src/value.ts")
        self.assertEqual(doc["strategy"], "related")
        chain = [t for t in doc["traces"] if t["test"] == "test/glob.test.ts"][0]["chain"]
        self.assertEqual(chain[0]["kind"], "glob-import")

    def test_style_load_paths_resolve_bare_sass_specifiers(self):
        self.settings["style_load_paths"] = ["src"]
        self.save_config()
        self.write("src/shared/vars.scss", "$primary: #fff;\n")
        self.write("src/theme.scss", "@use 'shared/vars';\n.a { color: vars.$primary; }\n")
        self.write("test/style.test.ts", "import '../src/theme.scss';\n")
        doc = self.plan("--file", "src/shared/vars.scss")
        self.assertEqual(doc["strategy"], "related")
        self.assertEqual(doc["tests"], ["test/style.test.ts"])
        self.assertEqual(doc["issues"], [])

    def test_skip_dirs_override_reads_conventional_build_output(self):
        self.write("docs/.vitepress/theme/demos/a.vue", "<template><view/></template>\n")
        self.write(
            "test/docs.test.ts",
            "import { readFileSync } from 'node:fs'\nimport { join } from 'node:path'\n"
            "const demo = readFileSync(join(__dirname, '../docs/.vitepress/theme/demos/a.vue'), 'utf8')\nconsole.log(demo);\n",
        )
        skipped = self.plan("--file", "docs/.vitepress/theme/demos/a.vue")
        self.assertEqual(skipped["strategy"], "full")
        self.settings["skip_dirs"] = [".git", "node_modules"]
        self.save_config()
        scanned = self.plan("--file", "docs/.vitepress/theme/demos/a.vue")
        self.assertEqual(scanned["strategy"], "related")
        self.assertEqual(scanned["tests"], ["test/docs.test.ts"])

    def test_glob_dependency_declaration_covers_unprovable_reads(self):
        self.write(
            "src/dynamic.ts",
            "import { readFileSync } from 'node:fs'\nimport { join } from 'node:path'\n"
            "export const load = (base: string, name: string) => readFileSync(join(base, name), 'utf8');\n",
        )
        self.write("test/dynamic.test.ts", "import { load } from '../src/dynamic';\nconsole.log(load('.', 'x'));\n")
        plain = self.plan("--file", "src/value.ts")
        self.assertEqual(plain["strategy"], "full")
        self.settings["dependencies"] = [
            {"dependent": "src/dynamic.ts", "dependency": "src/*.ts"},
        ]
        self.save_config()
        declared = self.plan("--file", "src/value.ts")
        self.assertEqual(declared["strategy"], "related")
        self.assertTrue(
            any(reason.startswith("declared-dependencies") for reason in declared["reasons"]),
        )

    def test_empty_glob_dependency_is_reported_not_silent(self):
        self.settings["dependencies"] = [
            {"dependent": "test/other.test.ts", "dependency": "absent/**"},
        ]
        self.save_config()
        doc = self.plan("--file", "src/value.ts")
        self.assertEqual(doc["strategy"], "full")
        self.assertTrue(
            any(
                issue["reason"].startswith("unresolved-explicit-dependency")
                for issue in doc["issues"]
            ),
        )

    def test_runner_dir_executes_in_the_configured_package_directory(self):
        # A monorepo configures Vitest in a subdirectory; --run must execute
        # there and pass test paths relative to it.
        self.settings["runner_dir"] = "app"
        self.settings["include"] = ["src/**", "test/**", "app/**"]
        self.save_config()
        self.write("app/package.json", '{"name":"app","private":true}\n')
        self.write("app/vitest.config.ts", "export default {}\n")
        self.write("app/src/lib.ts", "export const inner = 1;\n")
        self.write(
            "app/test/inner.test.ts",
            "import { inner } from '../src/lib';\nconsole.log(inner);\n",
        )
        args = self.plan("--file", "app/src/lib.ts")
        self.assertEqual(args["tests"], ["app/test/inner.test.ts"])
        self.fake_runner()
        self.invoke("--file", "app/src/lib.ts", "--run")
        executed = json.loads(self.marker.read_text())
        self.assertEqual(executed["cwd"].endswith("/app"), True)
        self.assertEqual(executed["argv"][-1], "./test/inner.test.ts")

    def test_selected_test_outside_runner_dir_is_a_configuration_error(self):
        self.settings["runner_dir"] = "app"
        self.save_config()
        self.write("app/package.json", '{"name":"app","private":true}\n')
        self.fake_runner()
        result = self.invoke("--file", "src/value.ts", "--run", expected=2)
        self.assertIn("outside runner_dir", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_moonbit_module_is_planned_without_a_config(self):
        self.write_moonbit_fixture()
        doc = self.bare_plan("--file", "lib.mbt")
        self.assertEqual(doc["mode"], "moonbit")
        self.assertEqual(doc["strategy"], "related")
        self.assertEqual(doc["tests"], [""])
        self.assertEqual(doc["issues"], [])
        chain = doc["traces"][0]["chain"]
        self.assertEqual(chain[0]["kind"], "owns")

    def test_moonbit_cli_only_change_runs_no_library_tests(self):
        self.write_moonbit_fixture()
        doc = self.bare_plan("--file", "cli/main.mbt")
        self.assertEqual(doc["strategy"], "none")
        self.assertEqual(doc["tests"], [])
        self.assertEqual(doc["affected"], ["cli"])

    def test_moonbit_descriptor_change_requests_every_package(self):
        self.write_moonbit_fixture()
        doc = self.bare_plan("--file", "moon.mod")
        self.assertEqual(doc["strategy"], "full")
        self.assertTrue(
            any(r.startswith("global-input-changed") for r in doc["reasons"])
        )

    def test_moonbit_run_executes_moon_test_per_package(self):
        self.write_moonbit_fixture()
        self.fake_runner()
        self.invoke_bare("--file", "lib.mbt", "--run")
        executed = json.loads(self.marker.read_text())
        # The module root package is addressed as the current directory.
        self.assertEqual(executed["argv"], ["test", "."])

    def test_no_config_and_no_moonbit_module_is_an_error(self):
        result = self.invoke_bare("--file", "src/value.ts", expected=2)
        self.assertIn("moonimpact:", result.stderr)

    def test_global_change_requests_full_suite(self):
        doc = self.plan("--file", "package.json")
        self.assertEqual(doc["strategy"], "full")
        self.assertTrue(any(reason.startswith("global-input-changed") for reason in doc["reasons"]))

    def test_deleted_input_is_not_silently_discarded(self):
        doc = self.plan("--file", "src/deleted.ts")
        self.assertEqual(doc["strategy"], "full")
        self.assertIn("src/deleted.ts", doc["changed"])

    def test_bad_utf8_blocks_run(self):
        self.fake_runner()
        self.write("src/broken.ts", b"\xff\xfe invalid")
        doc = self.plan("--file", "src/value.ts", "--run", expected=2)
        self.assertEqual(doc["strategy"], "blocked")
        self.assertFalse(self.marker.exists())

    def test_symlinks_are_not_followed(self):
        self.fake_runner()
        target = self.owner / "outside.ts"
        target.write_text("export const outside = 1;\n", encoding="utf-8")
        (self.root / "src/link.ts").symlink_to(target)
        doc = self.plan("--file", "src/value.ts", "--run", expected=2)
        self.assertEqual(doc["strategy"], "blocked")
        self.assertFalse(self.marker.exists())

    def test_related_run_has_safe_argv_and_keeps_stdout_json(self):
        self.fake_runner()
        result = self.invoke("--file", "src/value.ts", "--run", "--format", "json")
        json.loads(result.stdout)
        self.assertEqual(json.loads(self.marker.read_text())["argv"], ["exec", "vitest", "run", "./test/value.test.ts"])
        self.assertIn("RUNNER_STDOUT", result.stderr)
        self.assertIn("RUNNER_STDERR", result.stderr)

    def test_full_run_intentionally_has_no_filters(self):
        self.fake_runner(code=1)
        self.invoke("--file", "package.json", "--run", expected=1)
        self.assertEqual(json.loads(self.marker.read_text())["argv"], ["exec", "vitest", "run"])

    def test_report_is_create_only_and_html_escapes_names(self):
        report = self.owner / "plan.json"
        self.invoke("--file", "src/value.ts", "--report", report)
        original = report.read_bytes()
        self.invoke("--file", "src/value.ts", "--report", report, expected=2)
        self.assertEqual(report.read_bytes(), original)
        source = self.root / "src/value.ts"
        original_source = source.read_bytes()
        self.invoke("--file", "src/value.ts", "--report", source, expected=2)
        self.assertEqual(source.read_bytes(), original_source)
        html = self.invoke("--file", "missing<script>.ts", "--format", "html").stdout
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;script&gt;", html)

    def test_strict_configuration_and_input_validation(self):
        self.invoke(expected=2)
        self.invoke("--file", "src/value.ts", "--worktree", expected=2)
        self.invoke("--file", "../outside.ts", expected=2)
        self.invoke("--file", "src/value.ts", "--timeout-ms", "4", expected=2)
        self.settings["execute"] = "pnpm test"
        self.save_config()
        self.invoke("--file", "src/value.ts", expected=2)

    def test_git_empty_worktree_never_runs_tests(self):
        self.commit_fixture()
        self.fake_runner()
        doc = self.plan("--worktree", "--run")
        self.assertEqual(doc["changed"], [])
        self.assertEqual(doc["strategy"], "none")
        self.assertFalse(self.marker.exists())

    def test_git_worktree_includes_staged_unstaged_and_untracked(self):
        self.commit_fixture()
        self.write("src/value.ts", "export const value = 2;\n")
        self.git("add", "src/value.ts")
        self.write("src/wrapper.ts", "import { value } from './value';\nexport const wrapped = value + 1;\n")
        self.write("src/new.ts", "export const added = 1;\n")
        doc = self.plan("--worktree")
        self.assertEqual(doc["changed"], ["src/new.ts", "src/value.ts", "src/wrapper.ts"])

    def test_unknown_git_reference_fails_instead_of_empty_success(self):
        self.commit_fixture()
        self.invoke("--base", "nonexistent-moonimpact-ref", expected=2)


def main():
    global BINARY
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    BINARY = args.binary.resolve(strict=True)
    if not BINARY.is_file() or not os.access(BINARY, os.X_OK):
        parser.error("--binary must be an existing executable")
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ImpactCLI)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
