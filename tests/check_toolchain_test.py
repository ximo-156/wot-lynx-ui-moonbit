#!/usr/bin/env python3
"""Boundary checks for the compiler version gate used by CI."""
import unittest

from check_toolchain import meets_minimum


class CompilerRequirementTests(unittest.TestCase):
    def test_rejects_old_prerelease_and_unrecognized_versions(self):
        for output in (
            "v0.10.21+06da1ed44 (2026-11-16)",
            "v1.0.0-alpha1",
            "v1.0.0-beta2",
            "v1.0.0-rc0",
            "v1.0.0-dev",
            "v1.0.0-rc",
            "moon 0.1.20261126",
            "v1.0",
            "unknown",
            "",
        ):
            with self.subTest(output=output):
                self.assertFalse(meets_minimum(output))

    def test_accepts_minimum_stable_and_newer_compilers(self):
        for output in (
            "v1.0.0-rc1+3c0520448 (2026-11-26)",
            "moonc v1.0.0-rc1",
            "1.0.0-rc.1",
            "v1.0.0-rc2",
            "v1.0.0-rc10",
            "v1.0.0",
            "v1.0.1",
            "v1.1.0-beta1",
            "v2.0.0",
        ):
            with self.subTest(output=output):
                self.assertTrue(meets_minimum(output))


if __name__ == "__main__":
    unittest.main(verbosity=2)
