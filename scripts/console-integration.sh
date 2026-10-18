#!/bin/sh
# process.terminal with --console-socket, compared with runc. An independent
# static receiver (scripts/fixtures/console-receiver.c) must get one terminal
# master, report its size, answer a prompt, and read the workload's output.
#
# Covered as uid 1000 with no_new_privs: create/start with consoleSize (the
# workload's stdio and controlling terminal are the peer, it owns it, and
# /dev/console is that terminal), detached command exec with --tty, and
# detached exec --process with its own size. Swift-only: a terminal without a
# console socket, a console socket without a terminal, a foreground terminal,
# and a missing devpts mount fail without state or workload.
# Run as root inside a disposable Linux VM; requires CC (default clang) able to
# link statically and BusyBox (BUSYBOX). RUNC_COMPARE=1 also runs runc.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cc=${CC:-clang}

# Detached exec processes are reaped by the caller's subreaper (runc's
# contract). Under a PID 1 that never reaps, such as a CI job container's
# `tail -f /dev/null`, they would stay zombies and block the container's PID
# namespace teardown, so the suite reruns itself under the subreaper fixture.
if [ "${CONSOLE_SUITE_SUBREAPED:-}" != 1 ]; then
    outer=$(mktemp -d)
    "$cc" -O2 -Wall -Wextra -Werror -o "$outer/subreaper" "$here/fixtures/subreaper.c" || {
        rm -rf "$outer"
        echo "console-integration: cannot build the subreaper fixture with $cc" >&2
        exit 1
    }
    suite_status=0
    CONSOLE_SUITE_SUBREAPED=1 timeout -k 5 600 "$outer/subreaper" sh "$here/console-integration.sh" "$@" || suite_status=$?
    rm -rf "$outer"
    exit "$suite_status"
fi
runtime=${1:-.build/debug/srunc}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-0}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
ours="timeout -k 2 60 $runtime --root $scratch/state"
theirs="timeout -k 2 60 runc --root $scratch/runc-state"
receivers=

cleanup() {
    for pid in $receivers; do kill -KILL "$pid" 2>/dev/null || :; done
    for rt in "$ours" "$theirs"; do
        for id in $($rt list -q 2>/dev/null); do $rt delete --force "$id" >/dev/null 2>&1 || :; done
    done
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { echo "console-integration: $*" >&2; exit 1; }

rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$scratch/sockets" "$scratch/results"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
receiver=$scratch/console-receiver
"$cc" -static -O2 -Wall -Wextra -Werror -o "$receiver" "$here/fixtures/console-receiver.c" \
    || fail "cannot build the static receiver with $cc"

# The workload reports its terminal, then reads one line through it.
probe='tty | sed s/^/tty=/; echo size=$(stty size 2>/dev/null); [ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo stdio=tty; echo ctty > /dev/tty; echo owner=$(stat -L -c %u /proc/self/fd/0); [ -c /dev/console ] && echo console=$(stat -L -c %t:%T /dev/console); stty -echo; echo INPUT?; read line; echo got:$line'
devpts='{"destination": "/dev/pts", "type": "devpts", "source": "devpts", "options": ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5"]}'
# config NAME TERMINAL ARGS [EXTRA_PROCESS_FIELDS] [DEVPTS]
config() {
    mkdir -p "$scratch/$1"
    cat > "$scratch/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": $2, "user": {"uid": 1000, "gid": 1000}, "args": $3, "env": ["PATH=/bin"], "cwd": "/", "noNewPrivileges": true${4:-}},
  "hostname": "ttybox",
  "mounts": [
    {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
    {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}${5-, $devpts}
  ],
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}
}
EOF
}
# listen NAME: start a receiver for NAME and wait until it listens.
listen() {
    rm -f "$scratch/sockets/$1" "$scratch/sockets/$1.ready"
    "$receiver" "$scratch/sockets/$1" "$scratch/sockets/$1.ready" hello > "$scratch/results/$1" 2> "$scratch/results/$1.err" &
    receiver_pid=$!
    receivers="$receivers $receiver_pid"
    for _ in $(seq 100); do [ -e "$scratch/sockets/$1.ready" ] && return; sleep 0.05; done
    fail "$1: receiver did not start"
}
# collected NAME: wait for the receiver, then print its normalized output.
collected() {
    wait "$receiver_pid" || { cat "$scratch/results/$1.err" >&2; fail "$1: receiver failed"; }
    # pts numbers are reused once a terminal closes; compare the directory only.
    tr -d '\r' < "$scratch/results/$1" | sed 's|^tty=/dev/pts/[0-9]*$|tty=/dev/pts/N|'
}
# expect NAME EXPECTED
expect() {
    collected "$1" > "$scratch/results/$1.clean"
    printf '%s\n' "$2" > "$scratch/results/$1.expected"
    cmp -s "$scratch/results/$1.expected" "$scratch/results/$1.clean" || {
        echo "expected:"; cat "$scratch/results/$1.expected"; echo "got:"; cat "$scratch/results/$1.clean"
        fail "$1: terminal output differs"
    }
}

exercise() {
    impl=$1 rt=$2
    # create/start: the init's terminal, sized and bound to /dev/console.
    tag=tty-init-$impl
    config "$tag" true "[\"/bin/sh\", \"-c\", \"$probe\"]" ', "consoleSize": {"height": 30, "width": 100}'
    listen "$tag"
    $rt create --bundle "$scratch/$tag" --console-socket "$scratch/sockets/$tag" "$tag" > /dev/null 2> "$scratch/results/$tag.create" \
        || { cat "$scratch/results/$tag.create"; fail "$tag: create failed"; }
    $rt start "$tag"
    expect "$tag" "winsize 30 100
tty=/dev/pts/N
size=30 100
stdio=tty
ctty
owner=1000
console=88:0
INPUT?
got:hello"
    $rt delete --force "$tag"

    # Detached exec with --tty (no size) and with a process file's size.
    tag=tty-exec-$impl
    config "$tag" false '["/bin/sleep", "1000"]'
    $rt create --bundle "$scratch/$tag" "$tag" < /dev/null > /dev/null 2>&1
    $rt start "$tag"
    listen "$tag-command"
    $rt exec --detach --tty --console-socket "$scratch/sockets/$tag-command" "$tag" /bin/sh -c "$probe" > /dev/null
    expect "$tag-command" "winsize 0 0
tty=/dev/pts/N
size=
stdio=tty
ctty
owner=1000
INPUT?
got:hello"
    printf '{"terminal":true,"consoleSize":{"height":40,"width":120},"user":{"uid":1000,"gid":1000},"args":["/bin/sh","-c","%s"],"env":["PATH=/bin"],"cwd":"/","noNewPrivileges":true}' \
        "$(printf '%s' "$probe" | sed 's/"/\\"/g')" > "$scratch/process.json"
    listen "$tag-process"
    $rt exec --detach --process "$scratch/process.json" --console-socket "$scratch/sockets/$tag-process" "$tag" > /dev/null
    expect "$tag-process" "winsize 40 120
tty=/dev/pts/N
size=40 120
stdio=tty
ctty
owner=1000
INPUT?
got:hello"
    $rt delete --force "$tag"
    echo "$impl: init terminal with size, ownership, ctty and /dev/console; exec --tty and process-file terminals passed"
}
exercise swift "$ours"
if [ "$compare" = 1 ]; then exercise runc "$theirs"; fi

# Contract and setup failures leave neither state nor a workload.
refused() {
    tag=$1 message=$2
    shift 2
    if $ours "$@" > "$scratch/results/$tag.out" 2> "$scratch/results/$tag.err"; then fail "$tag: succeeded"; fi
    grep -qF -- "$message" "$scratch/results/$tag.err" || { cat "$scratch/results/$tag.err"; fail "$tag: expected '$message'"; }
    if $ours state "$tag" > /dev/null 2>&1; then fail "$tag: left state"; fi
    [ ! -s "$scratch/results/$tag.out" ] || fail "$tag: workload ran"
}
config no-socket true '["/bin/echo", "must-not-run"]'
refused no-socket 'needs --console-socket' create --bundle "$scratch/no-socket" no-socket
config no-terminal false '["/bin/echo", "must-not-run"]'
refused no-terminal 'needs a detached process' create --bundle "$scratch/no-terminal" --console-socket "$scratch/sockets/unused" no-terminal
refused foreground 'in the foreground is not implemented' run --bundle "$scratch/no-socket" foreground
config no-devpts true '["/bin/echo", "must-not-run"]' '' ''
listen no-devpts
refused no-devpts 'devpts' create --bundle "$scratch/no-devpts" --console-socket "$scratch/sockets/no-devpts" no-devpts
wait "$receiver_pid" 2>/dev/null || :
echo 'swift: missing console socket, needless console socket, foreground terminal and missing devpts refused without state'
echo 'Console integration passed.'
