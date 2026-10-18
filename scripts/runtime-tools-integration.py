#!/usr/bin/env python3
"""Run unmodified runtime-tools tests with isolated runtime state and TAP checks.

Run as root on a disposable Linux host. Preserve raw TAP and harness results;
only JSON diagnostic blocks are removed from the stream fed to Perl's parser.
"""
import argparse
import json
import os
import platform
from pathlib import Path
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


def check_output(name, text, normalized, harness):
    """Check TAP plans/assertions, with two explicit upstream exit-only tests."""
    try:
        normalized.write_text(normalize_tap(text))
    except ValueError as error:
        harness.write_text(str(error) + "\n")
        return False
    negative = {"process_capabilities_fail": "CAP_TEST", "process_rlimits_fail": "RLIMIT_TEST"}
    if name in negative:
        harness.write_text("Upstream exit-only negative test; require its specific rejection diagnostic.\n")
        return "failed to create the container" in text and negative[name] in text
    with harness.open("w") as stream:
        return subprocess.run(["prove", "--exec", "cat", str(normalized)],
                              stdout=stream, stderr=subprocess.STDOUT).returncode == 0


def host_exclusion(name):
    """Host LSM tests require their configured policy, not just a kernel module."""
    if name == "linux_mount_label" and not Path("/sys/fs/selinux/enforce").exists():
        return "SELinux is disabled on this host; requested unavailable labels are refused by srunc."
    if name == "linux_process_apparmor_profile":
        try:
            profiles = Path("/sys/kernel/security/apparmor/profiles").read_text()
        except OSError:
            profiles = ""
        if not any(line.startswith("acme_secure_profile ") for line in profiles.splitlines()):
            return "The upstream acme_secure_profile AppArmor policy is not loaded on this host."
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("tests", nargs="*", help="suite names; default: all suites")
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--strict", action="store_true", help="run every test, including documented exclusions")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 600:
        parser.error("timeout must be 1...600 seconds")
    runtime, checkout, output = (p.resolve() for p in (args.runtime, args.checkout, args.output))
    if os.geteuid() != 0:
        parser.error("run as root on a disposable Linux host")
    revision = Path(__file__).with_name("runtime-tools-revision").read_text().strip()
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    if actual != revision:
        parser.error(f"runtime-tools revision {actual} differs from pinned {revision}")
    subprocess.run(["git", "diff", "--exit-code", "HEAD"], cwd=checkout, check=True)
    inventory = {p.stem: p.with_suffix(".t") for p in checkout.glob("validation/*/*.go") if p.parent.name != "util"}
    fixture = checkout / ".srunc-fixture"
    arch = subprocess.check_output(["go", "env", "GOARCH"], text=True).strip()
    if not (fixture / "runtimetest").is_file() or not (fixture / f"rootfs-{arch}.tar.gz").is_file():
        parser.error("native fixtures are missing; run scripts/prepare-runtime-tools.sh CHECKOUT first")
    names = args.tests or sorted(inventory)
    for name in names:
        if name not in inventory or not inventory[name].is_file():
            parser.error(f"unknown or unbuilt suite: {name}")
    exclusions = json.loads(Path(__file__).with_name("runtime-tools-exclusions.json").read_text())
    if set(exclusions) - inventory.keys():
        parser.error("exclusion inventory does not match the pinned upstream checkout")
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
            # Naming a suite explicitly or --strict always runs it unchanged.
            excluded = exclusions.get(name) if not args.strict and not args.tests else None
            unavailable = host_exclusion(name) if not args.strict and not args.tests else None
            if excluded or unavailable:
                reason = excluded["reason"] if excluded else unavailable
                category = excluded["category"] if excluded else "host"
                results.append({"suite": name, "status": "EXCLUDED", "category": category, "reason": reason, "exit": None})
                (output / f"{name}.exclusion.txt").write_text(reason + "\n")
                print(f"EXCLUDED ({category}): {name}: {reason}", flush=True)
                continue
            raw = output / f"{name}.tap"
            with raw.open("w") as stream:
                run = subprocess.run(["timeout", "--kill-after=5", str(args.timeout), str(inventory[name])],
                                     cwd=fixture, env=env, stdout=stream, stderr=subprocess.STDOUT)
            text = raw.read_text(errors="replace")
            normalized = output / f"{name}.normalized.tap"
            harness = output / f"{name}.harness.log"
            status = "FAIL"
            valid = check_output(name, text, normalized, harness)
            if run.returncode == 0 and valid:
                status = "PASS"
            elif run.returncode in {124, 137}:
                status = "TIMEOUT"
            # Upstream tests normally clean themselves; on failure/timeout,
            # delete only containers in this invocation's private state root.
            cleanup_log = output / f"{name}.cleanup.log"
            try:
                cleanup = subprocess.run([str(wrapper), "list", "--quiet"], text=True, capture_output=True, timeout=10)
                cleanup_log.write_text(cleanup.stdout + cleanup.stderr)
                if cleanup.returncode:
                    status = "ERROR"
                else:
                    for container in cleanup.stdout.splitlines():
                        deleted = subprocess.run([str(wrapper), "delete", "--force", container],
                                                 capture_output=True, timeout=15)
                        with cleanup_log.open("a") as stream:
                            stream.write(deleted.stdout.decode(errors="replace") + deleted.stderr.decode(errors="replace"))
                        if deleted.returncode:
                            status = "ERROR"
            except subprocess.TimeoutExpired as error:
                with cleanup_log.open("a") as stream:
                    stream.write(str(error) + "\n")
                status = "ERROR"
            results.append({"suite": name, "status": status, "exit": run.returncode})
            print(f"{status}: {name} (exit {run.returncode})", flush=True)
    report = {"runtime_tools_revision": revision, "host": platform.platform(),
              "runtime_version": subprocess.check_output([str(runtime), "--version"], text=True).strip(), "results": results}
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    summary = ["## OCI runtime-tools validation", "", f"Upstream: `{revision}`", "",
               "| Suite | Result | Exit |", "| --- | --- | --- |"]
    summary.extend(f"| {r['suite']} | {r['status']} | {r['exit'] if r['exit'] is not None else '-'} |" for r in results)
    summary.extend(["", "### Explicit exclusions", ""])
    summary.extend(f"- `{r['suite']}` ({r['category']}): {r['reason']}" for r in results if r['status'] == "EXCLUDED")
    passed = sum(r['status'] == 'PASS' for r in results)
    excluded = sum(r['status'] == 'EXCLUDED' for r in results)
    summary.extend(["", f"{passed} passed, {excluded} excluded, {len(results) - passed - excluded} failed."])
    print(summary[-1], flush=True)
    (output / "summary.md").write_text("\n".join(summary) + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write("\n".join(summary) + "\n")
    return int(not any(r["status"] == "PASS" for r in results) or any(r["status"] not in {"PASS", "EXCLUDED"} for r in results))


if __name__ == "__main__":
    raise SystemExit(main())
