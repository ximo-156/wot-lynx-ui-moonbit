#!/usr/bin/env python3
"""Validate corpus evidence parsing and restoration on failed execution."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import impact_moonbit_corpus as corpus


class CorpusEvidenceTests(unittest.TestCase):
    def result(self, stdout, stderr="", code=2):
        return subprocess.CompletedProcess([], code, stdout, stderr)

    def test_failure_identity_is_backend_independent(self):
        heading = '[example/mod] test a_test.mbt:3 ("a") failed'
        summary = "Total tests: 2, passed: 1, failed: 1.\n"
        plain = corpus.runner_result(self.result(heading + "\n" + summary), 0.1)
        detailed = corpus.runner_result(self.result("", heading + ": assertion failed\n" + summary), 0.2)
        self.assertEqual(plain["failure_tests"], detailed["failure_tests"])

    def test_failure_without_identity_is_not_accepted(self):
        with self.assertRaises(RuntimeError):
            corpus.runner_result(self.result("Total tests: 2, passed: 1, failed: 1.\n"), 0)

    def test_runner_startup_error_is_not_a_passing_test(self):
        with self.assertRaises(RuntimeError):
            corpus.runner_result(self.result("", "dependency unavailable"), 0)

    def test_mutation_is_restored_when_runner_evidence_is_invalid(self):
        with tempfile.TemporaryDirectory(prefix="moonimpact-corpus-test-") as directory:
            root = Path(directory).resolve()
            target = root / "lib.mbt"
            original = b"pub fn value() -> Int { 1 }\r\n"
            target.write_bytes(original)
            mutation = dict(name="value", path="lib.mbt", before="{ 1 }", after="{ 2 }")
            failed_run = self.result(json.dumps(dict(strategy="related", tests=[""])))
            with patch.object(corpus, "clean"), patch.object(corpus, "command", return_value=(failed_run, 0)):
                with self.assertRaises(RuntimeError):
                    corpus.mutation_audit(Path("/unused/impact"), root, mutation)
            self.assertEqual(target.read_bytes(), original)

    def test_mutation_cannot_traverse_outside_checkout(self):
        with tempfile.TemporaryDirectory(prefix="moonimpact-corpus-test-") as directory:
            with self.assertRaises(ValueError):
                corpus.mutation_audit(Path("/unused/impact"), Path(directory).resolve(),
                                      dict(name="escape", path="../outside.mbt"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
