#!/bin/sh
# Shared suite inventory for focused local runs and the complete CI gate.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
suites="namespace oci lifecycle lookup credentials capabilities rlimits preserve-fds pidfd-socket readonly path-controls cgroup cpu cpuset freezer ps update events metadata logging kill filesystems devices device-nodes bind network-namespace user-namespace rootless shared-namespace seccomp oom keyring lsm console sysctl cgroupns hooks"
# CI runs these groups as parallel jobs, balanced by measured release
# durations; "rest" is every suite not named here, so new suites always run.
shard_cpu="cpu lifecycle filesystems"
shard_cgroup="cgroup path-controls shared-namespace devices device-nodes"
shard_controllers="cpuset rlimits events freezer update"
shards="cpu cgroup controllers rest"
usage() {
    echo "Usage: $0 BINARY [SUITE ...] | BINARY --shard NAME | --list | --list-shards | --check [SUITE ...]"
    echo "With no suites, run all suites. RUNC_COMPARE defaults to 1."
}
# Prints the suites of one CI shard.
shard_suites() {
    case "$1" in
        cpu) echo "$shard_cpu" ;;
        cgroup) echo "$shard_cgroup" ;;
        controllers) echo "$shard_controllers" ;;
        rest)
            named=" $shard_cpu $shard_cgroup $shard_controllers "
            for suite in $suites; do
                case "$named" in *" $suite "*) ;; *) printf '%s ' "$suite" ;; esac
            done
            echo ;;
        *) echo "Unknown shard: $1 (use --list-shards)" >&2; exit 2 ;;
    esac
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
    --list-shards) for shard in $shards; do echo "$shard: $(shard_suites "$shard")"; done; exit 0 ;;
    --check) shift; validate "$@"; exit 0 ;;
    '') usage >&2; exit 2 ;;
esac
binary=$1
shift
if [ "${1:-}" = --shard ]; then
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    selection=$(shard_suites "$2")
    set -- $selection
fi
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
