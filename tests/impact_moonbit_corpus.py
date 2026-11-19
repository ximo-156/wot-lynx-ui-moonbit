#!/usr/bin/env python3
"""Pinned public MoonBit corpus: runner inventory and optional fault comparisons.

No network, installation, Git writes, or snapshot updates. Supply existing clean
checkouts with --project NAME=DIR. --mutate explicitly enables temporary source
faults, restored byte-for-byte in finally. Build artifacts may be written by moon.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path

COUNTS = re.compile(r"Total tests: (\d+), passed: (\d+), failed: (\d+)\.")
FAILURES = re.compile(r"^\[.*?\] test .*? failed(?=:|$)", re.MULTILINE)


def command(argv, root, timeout=120):
    started = time.monotonic()
    process = subprocess.run(list(map(str, argv)), cwd=root, text=True,
                             capture_output=True, timeout=timeout)
    return process, round(time.monotonic() - started, 3)


def runner_result(process, seconds):
    text = process.stdout + "\n" + process.stderr
    summaries = COUNTS.findall(text)
    if len(summaries) != 1:
        raise RuntimeError(f"expected one runner summary, exit={process.returncode}: {text[-3000:]}")
    total, passed, failed = map(int, summaries[0])
    identities = sorted(set(FAILURES.findall(text)))
    if total != passed + failed or len(identities) != failed:
        raise RuntimeError(f"incomplete test identities or counts: {summaries}; {identities}")
    if (failed == 0) != (process.returncode == 0):
        raise RuntimeError(f"runner exit and test counts disagree: {process.returncode}; {summaries}")
    return dict(exit=process.returncode, seconds=seconds, total=total,
                passed=passed, failed=failed, failure_tests=identities)


def git(root, *args):
    process, _ = command(["git", "-C", root, *args], root)
    if process.returncode:
        raise RuntimeError(process.stderr)
    return process.stdout.strip()


def clean(root):
    if git(root, "status", "--porcelain"):
        raise RuntimeError(f"checkout must be clean: {root}")


def plan(binary, root, *args):
    process, seconds = command([binary, "plan", "--format", "json", *args, root], root)
    if process.returncode or not process.stdout.startswith("{"):
        raise RuntimeError(f"planning failed: {process.stderr[-3000:]}")
    return json.loads(process.stdout), process.stdout, seconds


def inventory_audit(binary, root, spec):
    descriptor = "moon.mod" if (root / "moon.mod").is_file() else "moon.mod.json"
    doc, raw, _ = plan(binary, root, "--file", descriptor)
    _, again, _ = plan(binary, root, "--file", descriptor)
    if raw != again:
        raise AssertionError("repeated plans differ")
    outline, _ = command(["moon", "test", "--outline"], root)
    if outline.returncode:
        raise RuntimeError(f"runner outline failed: {outline.stderr[-3000:]}")
    labels = set(re.findall(r"^\s*\d+\.\s+(\S+)\s", outline.stdout, re.MULTILINE))
    if not labels:
        raise RuntimeError("runner outline contains no recognizable test entries")
    actual = set()
    for label in labels:
        if label == spec["module"]:
            suffix = ""
        elif label.startswith(spec["module"] + "/"):
            suffix = label[len(spec["module"]) + 1:]
        else:
            raise RuntimeError(f"unmapped runner package: {label}")
        actual.add("/".join(p for p in (spec["source"], suffix) if p))
    missing = sorted(actual - set(doc["inventory"]))
    if missing:
        raise AssertionError(f"runner packages missing from inventory: {missing}")
    return dict(runner_packages=sorted(actual), inventory=doc["inventory"],
                conservative_extras=sorted(set(doc["inventory"]) - actual),
                deterministic=True)


def mutation_audit(binary, root, mutation):
    relative = Path(mutation["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("mutation path must stay in checkout")
    target = root / relative
    if target.is_symlink() or target.resolve(strict=True) != target:
        raise ValueError("mutation target must not use symbolic links")
    original = target.read_bytes()
    before, after = mutation["before"].encode(), mutation["after"].encode()
    if not before or before == after or original.count(before) != 1:
        raise ValueError(f"mutation target is absent or ambiguous: {mutation['name']}")
    clean(root)
    try:
        target.write_bytes(original.replace(before, after))
        selected, seconds = command([binary, "plan", "--worktree", "--format", "json",
                                     "--run", "--timeout-ms", "90000", root], root)
        doc = json.loads(selected.stdout)
        selected_result = runner_result(selected, seconds)
        full, seconds = command(["moon", "test"], root)
        full_result = runner_result(full, seconds)
        if selected_result["failure_tests"] != full_result["failure_tests"]:
            raise AssertionError(f"selected/full failure mismatch: {selected_result}; {full_result}")
        return dict(name=mutation["name"], path=mutation["path"],
                    status="matched" if full_result["failed"] else "survived_full_suite",
                    strategy=doc["strategy"], selected_packages=doc["tests"],
                    selected=selected_result, full=full_result)
    finally:
        target.write_bytes(original)
        clean(root)


def audit(binary, root, spec, mutate):
    clean(root)
    commit = git(root, "rev-parse", "HEAD")
    if commit != spec["commit"]:
        raise ValueError(f"expected {spec['commit']}, got {commit}")
    process, seconds = command(["moon", "test"], root)
    baseline = runner_result(process, seconds)
    if baseline["failed"]:
        raise RuntimeError(f"baseline has pre-existing failures: {baseline}")
    result = dict(commit=commit, repository=spec["repository"], baseline=baseline,
                  inventory=inventory_audit(binary, root, spec), mutations=[])
    if mutate:
        for mutation in spec["mutations"]:
            result["mutations"].append(mutation_audit(binary, root, mutation))
    clean(root)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--project", action="append", required=True, metavar="NAME=DIR")
    parser.add_argument("--mutate", action="store_true", help="temporarily inject declared faults")
    parser.add_argument("--report", type=Path, help="create a new JSON report; never overwrite")
    args = parser.parse_args()
    config = json.loads(Path(__file__).with_suffix(".json").read_text())
    if args.report and args.report.exists():
        parser.error("report path already exists")
    projects = {}
    for argument in args.project:
        name, separator, path = argument.partition("=")
        if not separator or name not in config["projects"] or name in projects:
            parser.error("each project must have a unique configured NAME=DIR")
        projects[name] = Path(path).resolve(strict=True)
    binary = args.binary.resolve(strict=True)
    version, _ = command(["moon", "version", "--all"], Path.cwd())
    report = dict(version=1, toolchain=version.stdout.strip(), mutated=args.mutate,
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  corpus_sha256=hashlib.sha256(Path(__file__).with_suffix(".json").read_bytes()).hexdigest(),
                  projects={}, errors={})
    for name, root in projects.items():
        print(f"Auditing {name}", file=sys.stderr, flush=True)
        try:
            report["projects"][name] = audit(binary, root, config["projects"][name], args.mutate)
        except (AssertionError, ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            report["errors"][name] = str(error)
    encoded = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if args.report:
        with args.report.open("x", encoding="utf-8") as handle:
            handle.write(encoded)
    sys.stdout.write(encoded)
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
