#!/usr/bin/env python3
"""Regression checks for false passes in the upstream validation harness."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("runtime-tools-integration.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class TAPChecks(unittest.TestCase):
    def check_tap(self, text, name="default"):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            return runner.check_output(name, text, directory / "out.tap", directory / "harness.log")

    def test_json_diagnostics_preserve_assertions(self):
        self.assertTrue(self.check_tap('TAP version 13\nok 1 - sample\n  ---\n  {"detail":"value"}\n  ...\n1..1\n'))

    def test_exit_zero_is_not_enough(self):
        for text in ["", "ok 1 - no plan\n", "ok 1 - truncated\n1..2\n", "not ok 1 - failure\n1..1\n", "Bail out! broken\n"]:
            with self.subTest(text=text):
                self.assertFalse(self.check_tap(text))

    def test_broken_diagnostics_are_errors(self):
        self.assertFalse(self.check_tap('ok 1\n  ---\n  {"ok":true}\n1..1\n'))

    def test_exit_only_probe_requires_the_intended_rejection(self):
        name = "process_capabilities_fail"
        self.assertFalse(self.check_tap("failed to create the container\nsrunc: seccomp unavailable\n", name))
        self.assertTrue(self.check_tap("failed to create the container\nsrunc: unknown capability CAP_TEST\n", name))


if __name__ == "__main__":
    unittest.main()
