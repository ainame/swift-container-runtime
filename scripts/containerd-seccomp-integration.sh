#!/bin/sh
# Opt-in image checks with containerd's default and an actively tested deny rule.
set -eu
[ "$#" -eq 4 ] || { echo "Usage: $0 LINUX_RUNTIME SOCKET NAMESPACE IMAGE@sha256:DIGEST" >&2; exit 2; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
"${CC:-clang}" -static -O2 -Wall -Wextra -Werror "$here/fixtures/seccomp-probe.c" -o "$scratch/probe"
cat > "$scratch/profile.json" <<'JSON'
{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getcwd"],"action":"SCMP_ACT_ERRNO","errnoRet":13}]}
JSON
capture=${ENGINE_CAPTURE_DIRECTORY:-}
for profile in default deny-getcwd; do
    case "$profile" in default) policy=default expectation=allowed ;; *) policy=$scratch/profile.json expectation=denied ;; esac
    target=
    [ -z "$capture" ] || target=$capture/$profile
    ENGINE_SECCOMP=$policy ENGINE_SECCOMP_PROBE=$scratch/probe ENGINE_SECCOMP_EXPECTATION=$expectation \
        ENGINE_CAPTURE_DIRECTORY=$target sh "$here/containerd-image-integration.sh" "$@"
done
echo 'containerd-seccomp: PASS (default and custom policy, init mode, exec syscall enforcement and image cleanup)'
