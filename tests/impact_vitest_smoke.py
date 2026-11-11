#!/usr/bin/env python3
"""Optional real-Vitest smoke in an owned synthetic fixture; installs nothing.

Pass --vitest-dir pointing at an existing trusted Vitest installation. Only its
package code is linked; all tests, Vite cache and fault injection live in a new
temporary directory. The business project's tests/configuration are not loaded.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--vitest-dir", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    vitest = args.vitest_dir.resolve(strict=True)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("--binary must be executable")
    if not (vitest / "vitest.mjs").is_file():
        parser.error("--vitest-dir must contain vitest.mjs")
    if shutil.which("node") is None or shutil.which("pnpm") is None:
        parser.error("existing node and pnpm executables are required")
    temp = tempfile.TemporaryDirectory(prefix="moonimpact-vitest-smoke-")
    owner = Path(temp.name).resolve()
    try:
        root = owner / "demo"
        shutil.copytree(REPO / "examples/impact-demo", root,
                        ignore=shutil.ignore_patterns("node_modules", ".vite-cache"))
        modules = root / "node_modules"
        modules.mkdir()
        (modules / "vitest").symlink_to(vitest, target_is_directory=True)
        (modules / ".bin").mkdir()
        (modules / ".bin/vitest").symlink_to(vitest / "vitest.mjs")
        (root / "vitest.config.mjs").write_text(
            "export default { cacheDir: './.vite-cache', test: { include: ['test/**/*.test.ts'], "
            "maxWorkers: 1, minWorkers: 1, fileParallelism: false } }\n", encoding="utf-8")
        env = dict(os.environ, NO_COLOR="1")

        def run(change, expected):
            result = subprocess.run(
                [str(binary), "--file", change, "--config", str(root / "moonimpact.json"),
                 "--run", "--timeout-ms", "60000", "--format", "json", str(root)],
                cwd=root, env=env, text=True, capture_output=True, timeout=90)
            document = json.loads(result.stdout)
            if result.returncode != expected:
                raise AssertionError(result.stdout + "\n" + result.stderr)
            print(f"{change}: strategy={document['strategy']}, exit={result.returncode}, tests={document['tests']}")
            for line in result.stderr.splitlines():
                if "Test Files" in line or "Tests  " in line:
                    print(line)
            return document

        fees = run("src/fees.ts", 0)
        assert fees["tests"] == ["test/fees.test.ts", "test/summary.test.ts"]
        theme = run("src/theme.css", 0)
        assert theme["tests"] == ["test/theme.test.ts"]
        assert theme["traces"][0]["chain"][0]["kind"] == "read-root"
        # Compare the same synthetic stylesheet input with Vitest's existing
        # static-import-based selector. This is a scope demonstration, not a
        # claim about every Vitest version or an end-to-end speed benchmark.
        comparison = subprocess.run(
            ["pnpm", "exec", "vitest", "related", "--run", "src/theme.css"],
            cwd=root, env=env, text=True, capture_output=True, timeout=90)
        combined = comparison.stdout + comparison.stderr
        print(f"Vitest related stylesheet comparison: exit={comparison.returncode}")
        print("\n".join(line for line in combined.splitlines() if "No test files" in line))
        # Inject one fault into the just-created fixture only.
        (root / "src/fees.ts").write_text(
            "export function calculateFee(_minutes: number, _rate: number): number { return 0 }\n",
            encoding="utf-8")
        broken = run("src/fees.ts", 1)
        assert broken["tests"] == fees["tests"]
        full = run("package.json", 1)
        assert full["strategy"] == "full"
        print("PASS: selective real tests, stylesheet file dependency and fault detection (no installs)")
    finally:
        assert Path(temp.name).resolve() == owner
        assert owner.parent == Path(tempfile.gettempdir()).resolve()
        assert owner.name.startswith("moonimpact-vitest-smoke-")
        temp.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
