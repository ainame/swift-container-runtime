#!/usr/bin/python3
"""Trace an OCI runtime boundary in a disposable, secret-free test guest.

Set SCT_CAPTURE_DIR and SCT_REFERENCE_RUNTIME in the containerd daemon's
inherited environment before starting it. The defaults match engine-baseline.md.
Requires Python only for tracing, never for the Swift runtime itself. Captured
bundles/processes may contain secrets: inspect/redact before sharing. This wrapper
copies supplied JSON and preserves argv unchanged when replacing itself with the
reference runtime; it does not manufacture an engine bundle.
"""
import json
import os
import pathlib
import shutil
import sys
import time

os.umask(0o077)
args = sys.argv[1:]
base = pathlib.Path(os.environ.get("SCT_CAPTURE_DIR", "/tmp/sct-engine/capture"))
base.mkdir(parents=True, exist_ok=True)
entry = base / (str(time.time_ns()) + "-" + str(os.getpid()))
entry.mkdir()
(entry / "argv.json").write_text(json.dumps(args, indent=2) + "\n")
(entry / "cwd.txt").write_text(os.getcwd() + "\n")
for flag, name in [("--bundle", "config.json"), ("--process", "process.json")]:
    if flag in args:
        source = pathlib.Path(args[args.index(flag) + 1])
        if flag == "--bundle":
            source = source / "config.json"
        if source.exists():
            shutil.copyfile(source, entry / name)
reference = os.environ.get("SCT_REFERENCE_RUNTIME", "/usr/bin/runc")
os.execv(reference, [reference] + args)
