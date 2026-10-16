#!/bin/sh
# Run inside a disposable Linux VM with namespace/mount privileges.
set -eu
runtime=${1:-.build/debug/swift-container-runtime}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
before_hostname=$(hostname)
before_uts=$(readlink /proc/self/ns/uts)
before_mnt=$(readlink /proc/self/ns/mnt)
before_pid=$(readlink /proc/self/ns/pid)
"$runtime" namespace-run --hostname swiftbox -- /bin/sh -c '
    test "$(hostname)" = swiftbox
    test "$$" = 1
    test "$(awk '\''/^NSpid:/ { print $NF }'\'' /proc/self/status)" = 1
    printf "%s\n" "$(readlink /proc/self/ns/uts)" "$(readlink /proc/self/ns/mnt)" "$(readlink /proc/self/ns/pid)"
' > "$scratch/namespaces"
test "$(sed -n '1p' "$scratch/namespaces")" != "$before_uts"
test "$(sed -n '2p' "$scratch/namespaces")" != "$before_mnt"
test "$(sed -n '3p' "$scratch/namespaces")" != "$before_pid"
test "$(hostname)" = "$before_hostname"
test "$(readlink /proc/self/ns/mnt)" = "$before_mnt"

set +e
"$runtime" namespace-run -- /bin/sh -c 'exit 42'
status=$?
set -e
test "$status" = 42

# Kill PID 1 from its ancestor namespace; self-signals have special PID 1 rules.
"$runtime" namespace-run -- /bin/sh -c 'echo ready > "$1"; exec /bin/sleep 30' -- "$scratch/ready" &
runtime_pid=$!
timeout 5 /bin/sh -c 'while test ! -f "$1"; do sleep 0.01; done' -- "$scratch/ready"
launcher_pid=$(ps -o pid= --ppid "$runtime_pid")
launcher_pid=$(printf '%s' "$launcher_pid" | tr -d ' ')
init_pid=$(ps -o pid= --ppid "$launcher_pid")
init_pid=$(printf '%s' "$init_pid" | tr -d ' ')
kill -KILL "$init_pid"
set +e
wait "$runtime_pid"
status=$?
set -e
test "$status" = 137

# An exec failure is distinct from a workload choosing to exit 125.
set +e
"$runtime" namespace-run -- /definitely/not/a/program 2> "$scratch/error"
status=$?
set -e
test "$status" = 125
grep -q 'exec workload:' "$scratch/error"
"$runtime" namespace-run -- /bin/sh -c 'printf "%s\n" "$@"' -- 'a b' '\$(hostname)' '' > "$scratch/args"
printf '%s\n' 'a b' '\$(hostname)' '' > "$scratch/expected"
cmp "$scratch/args" "$scratch/expected"

# Running unprivileged must fail before any workload executes.
set +e
setpriv --reuid=65534 --regid=65534 --clear-groups "$runtime" namespace-run -- /bin/echo should-not-run > "$scratch/output" 2> "$scratch/error"
status=$?
set -e
test "$status" = 125
test ! -s "$scratch/output"
grep -q 'create namespaces:' "$scratch/error"
printf '%s\n' 'Linux integration checks passed: namespaces, procfs, host preservation, exit/signal status, exec errors, argv, privilege errors.'
