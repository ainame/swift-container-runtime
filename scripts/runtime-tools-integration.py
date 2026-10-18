#!/usr/bin/env python3
"""Run unmodified runtime-tools tests with isolated runtime state and TAP checks.

Run as root on a disposable Linux host. Preserve raw TAP and harness results;
only JSON diagnostic blocks are removed from the stream fed to Perl's parser.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


def normalize_tap(output):
    """Remove tap-go's JSON diagnostics, which are not Perl YAMLish syntax."""
    lines = []
    diagnostic = False
    for line in output.splitlines(keepends=True):
        if line.rstrip() == "  ---":
            if diagnostic:
                raise ValueError("nested TAP diagnostic")
            diagnostic = True
        elif diagnostic and line.rstrip() == "  ...":
            diagnostic = False
        elif not diagnostic:
            lines.append(line)
    if diagnostic:
        raise ValueError("unterminated TAP diagnostic")
    return "".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("tests", nargs="*", help="suite names; default: all suites")
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()
    runtime, checkout, output = (p.resolve() for p in (args.runtime, args.checkout, args.output))
    if os.geteuid() != 0:
        parser.error("run as root on a disposable Linux host")
    revision = Path(__file__).with_name("runtime-tools-revision").read_text().strip()
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    if actual != revision:
        parser.error(f"runtime-tools revision {actual} differs from pinned {revision}")
    subprocess.run(["git", "diff", "--exit-code", "HEAD"], cwd=checkout, check=True)
    inventory = {p.stem: p.with_suffix(".t") for p in checkout.glob("validation/*/*.go") if p.parent.name != "util"}
    names = args.tests or sorted(inventory)
    for name in names:
        if name not in inventory or not inventory[name].is_file():
            parser.error(f"unknown or unbuilt suite: {name}")
    output.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix="srunc-validation-") as temporary:
        work = Path(temporary)
        state = work / "state"
        wrapper = work / "runtime"
        wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(str(runtime))} --root {shlex.quote(str(state))} \"$@\"\n")
        wrapper.chmod(0o755)
        env = dict(os.environ, RUNTIME=str(wrapper))
        for name in names:
            raw = output / f"{name}.tap"
            with raw.open("w") as stream:
                run = subprocess.run(["timeout", "--kill-after=5", str(args.timeout), str(inventory[name])],
                                     cwd=checkout, env=env, stdout=stream, stderr=subprocess.STDOUT)
            text = raw.read_text(errors="replace")
            normalized = output / f"{name}.normalized.tap"
            harness = output / f"{name}.harness.log"
            status = "FAIL"
            try:
                normalized.write_text(normalize_tap(text))
                # These upstream negative tests intentionally emit no assertions.
                # Require a real rejection diagnostic as well as exit zero.
                if name in {"process_capabilities_fail", "process_rlimits_fail"}:
                    valid = "failed to create the container" in text and "srunc:" in text
                    harness.write_text("Upstream exit-only negative test; creation must fail.\n")
                else:
                    with harness.open("w") as stream:
                        valid = subprocess.run(["prove", "--exec", "cat", str(normalized)],
                                               stdout=stream, stderr=subprocess.STDOUT).returncode == 0
                if run.returncode == 0 and valid:
                    status = "PASS"
                elif run.returncode in {124, 137}:
                    status = "TIMEOUT"
            except ValueError as error:
                harness.write_text(str(error) + "\n")
            # Upstream tests normally clean themselves; on failure/timeout,
            # delete only containers in this invocation's private state root.
            cleanup = subprocess.run([str(wrapper), "list", "--quiet"], text=True, capture_output=True, timeout=10)
            if cleanup.returncode:
                status = "ERROR"
            else:
                for container in cleanup.stdout.splitlines():
                    deleted = subprocess.run([str(wrapper), "delete", "--force", container],
                                             capture_output=True, timeout=15)
                    if deleted.returncode:
                        status = "ERROR"
            results.append({"suite": name, "status": status, "exit": run.returncode})
            print(f"{status}: {name} (exit {run.returncode})", flush=True)
    report = {"runtime_tools_revision": revision, "results": results}
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    summary = ["## OCI runtime-tools validation", "", f"Upstream: `{revision}`", "",
               "| Suite | Result | Exit |", "| --- | --- | --- |"]
    summary.extend(f"| {r['suite']} | {r['status']} | {r['exit']} |" for r in results)
    (output / "summary.md").write_text("\n".join(summary) + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write("\n".join(summary) + "\n")
    return int(any(r["status"] != "PASS" for r in results))


if __name__ == "__main__":
    raise SystemExit(main())
