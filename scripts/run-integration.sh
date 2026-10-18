#!/bin/sh
# Shared suite inventory for focused local runs and the complete CI gate.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
suites="namespace oci lifecycle lookup credentials capabilities rlimits preserve-fds readonly path-controls cgroup cpu cpuset freezer ps update events metadata"
usage() {
    echo "Usage: $0 BINARY [SUITE ...] | --list | --check [SUITE ...]"
    echo "With no suites, run all suites. RUNC_COMPARE defaults to 1."
}
script_for() {
    case "$1" in
        namespace) echo "$root/scripts/integration.sh" ;;
        *) echo "$root/scripts/$1-integration.sh" ;;
    esac
}
validate() {
    for suite do
        case " $suites " in
            *" $suite "*) ;;
            *) echo "Unknown integration suite: $suite (use --list)" >&2; exit 2 ;;
        esac
        [ -f "$(script_for "$suite")" ] || {
            echo "Missing integration script: $suite" >&2; exit 2;
        }
    done
}
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --list) for suite in $suites; do echo "$suite"; done; exit 0 ;;
    --check) shift; validate "$@"; exit 0 ;;
    '') usage >&2; exit 2 ;;
esac
binary=$1
shift
# Validate the whole selection before executing even the first suite.
[ "$#" -gt 0 ] || set -- $suites
validate "$@"
[ -x "$binary" ] || { echo "Runtime binary is not executable: $binary" >&2; exit 2; }
export RUNC_COMPARE=${RUNC_COMPARE:-1}
for suite do
    started=$(date +%s)
    echo "=== $suite: START ==="
    if sh "$(script_for "$suite")" "$binary"; then
        echo "=== $suite: PASS ($(($(date +%s) - started))s) ==="
    else
        result=$?
        echo "=== $suite: FAIL status=$result ($(($(date +%s) - started))s) ===" >&2
        exit "$result"
    fi
done
