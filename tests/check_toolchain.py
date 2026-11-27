#!/usr/bin/env python3
"""Fail early unless the active MoonBit compiler meets the acceptance minimum."""
from __future__ import annotations

import re
import subprocess
import sys

MINIMUM = "1.0.0-rc1"
VERSION = re.compile(
    r"(?:^|\s)v?(\d+)\.(\d+)\.(\d+)"
    r"(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?(?=\s|$)"
)


def meets_minimum(output: str) -> bool:
    match = VERSION.search(output)
    if match is None:
        return False
    release = tuple(int(part) for part in match.group(1, 2, 3))
    if release != (1, 0, 0):
        return release > (1, 0, 0)
    prerelease = match.group(4)
    if prerelease is None:
        return True
    candidate = re.fullmatch(r"rc\.?([0-9]+)", prerelease)
    return candidate is not None and int(candidate.group(1)) >= 1


def main() -> int:
    try:
        result = subprocess.run(
            ["moonc", "-v"], text=True, capture_output=True, check=True
        )
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Cannot query moonc: {error}", file=sys.stderr)
        return 1
    version = (result.stdout + result.stderr).strip()
    if not meets_minimum(version):
        print(f"Required moonc >= {MINIMUM}; found: {version or '(empty output)'}", file=sys.stderr)
        return 1
    print(f"Compiler requirement satisfied: {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
