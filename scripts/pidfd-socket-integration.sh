#!/bin/sh
# --pidfd-socket checks, compared with runc. An independent static receiver
# (scripts/fixtures/pidfd-receiver.c) listens on the host and must get one
# stream message: the label (standard for a container init, setns for an
# exec process) with exactly one SCM_RIGHTS pidfd. In signal mode its fdinfo
# PID must be the --pid-file (and state) PID and pidfd_send_signal(0) must
# reach the live process; then poll must report its exit, reaping must make
# the stale pidfd fail with ESRCH, and nothing more may follow.
#
# Covered as uid 1000 with no_new_privs, the socket on the host outside the
# rootfs: foreground run and command exec with a relative path (runc resolves
# it in the bundle; the runtime runs elsewhere), exec --process with a
# relative path (runc resolves it in the caller's directory), detached run
# and detached exec with absolute paths, and create with an abstract name,
# whose pidfd arrives before start. With --preserve-fds 1 the workload sees
# exactly 0-3. A missing listener, a non-socket, an over-long or missing
# value fail without state, workload, or a changed exec target; a duplicate
# or unknown container ID fails without connecting at all. A listener that
# vanishes before the send is covered by the Swift transport tests
# (PidfdSocketTransportTests), not here: closing a listener against a real
# launch races the send.
#
# The whole suite runs under the subreaper fixture, the caller runc requires
# for detached processes (runc docs/terminals.md), so detached inits and exec
# processes are reaped and their pidfds reach ESRCH.
# Run as root inside a disposable Linux VM. Requires CC (default clang) able
# to link statically and BusyBox (BUSYBOX).
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cc=${CC:-clang}

if [ "${PIDFD_SOCKET_SUITE_SUBREAPED:-}" != 1 ]; then
    pfs_outer=$(mktemp -d)
    "$cc" -O2 -Wall -Wextra -Werror -o "$pfs_outer/subreaper" "$here/fixtures/subreaper.c" || {
        rm -rf "$pfs_outer"
        echo "pidfd-socket-integration: cannot build the subreaper fixture with $cc" >&2
        exit 1
    }
    pfs_suite_status=0
    PIDFD_SOCKET_SUITE_SUBREAPED=1 timeout -k 5 1200 "$pfs_outer/subreaper" sh "$here/pidfd-socket-integration.sh" "$@" \
        || pfs_suite_status=$?
    rm -rf "$pfs_outer"
    case "$pfs_suite_status" in
    124 | 137 | 143) echo "pidfd-socket-integration: suite timed out or was killed (status $pfs_suite_status)" >&2; exit 1 ;;
    esac
    exit "$pfs_suite_status"
fi

runtime=${1:-.build/debug/swift-container-runtime}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-auto}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
state_root=$scratch/state
runc_root=$scratch/runc-state
results=$scratch/results
# Every relative launch runs here, where no socket exists, so a path that
# resolved against the working directory instead of the bundle would fail.
elsewhere=$scratch/elsewhere
ours="timeout -k 2 60 $runtime --root $state_root"
theirs="timeout -k 2 60 runc --root $runc_root"
# Receivers still running at exit; each is bounded by timeout anyway.
pfs_receivers=

pfs_cleanup() {
    for pfs_pid in $pfs_receivers; do kill -KILL "$pfs_pid" 2>/dev/null || :; done
    for id in $($ours list -q 2>/dev/null); do $ours delete --force "$id" >/dev/null 2>&1 || :; done
    if [ "$compare" = 1 ]; then
        for id in $($theirs list -q 2>/dev/null); do $theirs delete --force "$id" >/dev/null 2>&1 || :; done
    fi
    rm -rf "$scratch"
}
trap pfs_cleanup EXIT
trap 'exit 1' HUP INT TERM

pfs_fail() {
    echo "pidfd-socket-integration: $*" >&2
    exit 1
}

if ldd "$busybox" >/dev/null 2>&1; then pfs_fail "BusyBox at $busybox must be statically linked"; fi
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || pfs_fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

# Rootfs: static BusyBox and the static descriptor probe. The receiver and
# its sockets stay on the host, outside the rootfs. /tmp holds the workload's
# readiness marker, written as uid 1000.
rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$results" "$scratch/sockets" "$elsewhere"
chmod 1777 "$rootfs/tmp"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
"$cc" -static -O2 -Wall -Wextra -Werror -o "$rootfs/bin/fd-probe" "$here/fixtures/fd-probe.c" \
    || pfs_fail "cannot build the static descriptor probe with $cc"
receiver=$scratch/pidfd-receiver
"$cc" -static -O2 -Wall -Wextra -Werror -o "$receiver" "$here/fixtures/pidfd-receiver.c" \
    || pfs_fail "cannot build the static receiver with $cc"
for binary in "$rootfs/bin/fd-probe" "$receiver"; do
    if ldd "$binary" >/dev/null 2>&1; then pfs_fail "$binary is not statically linked"; fi
done
timeout -k 2 30 "$receiver" --self-test > "$results/self-test" || pfs_fail "receiver self-test failed"
grep -qxF "self-test ok" "$results/self-test" || pfs_fail "receiver self-test produced no verdict"

# The waiter exits 7 on SIGUSR1, which works for a container's PID 1 too
# (it has a handler). It creates /tmp/ready only after installing the trap,
# so no USR1 is sent before the handler exists; the marker argument finds a
# leaked workload.
marker=pidfd-waiter-$$
ready=$rootfs/tmp/ready
waiter_script="trap 'exit 7' USR1; : > /tmp/ready; while :; do sleep 0.1; done"
waiter="[\"/bin/sh\", \"-c\", \"$waiter_script\", \"$marker\"]"
mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}
]'
bundles=$scratch/bundles
process_fields='"terminal": false, "user": {"uid": 1000, "gid": 1000}, "env": ["PATH=/bin"], "cwd": "/", "noNewPrivileges": true'
# pfs_config NAME ARGS_JSON
pfs_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {$process_fields, "args": $2},
  "hostname": "pidfdbox",
  "mounts": $mounts,
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}
}
EOF
}
pfs_config waiter "$waiter"
pfs_config probe '["/bin/fd-probe"]'
pfs_config sleeper '["/bin/sleep", "1000"]'
cat > "$scratch/process.json" <<EOF
{$process_fields, "args": $waiter}
EOF

pfs_field() { sed -n "s/^ *\"$1\" *: *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p"; }
pfs_status() { $1 state "$2" 2>/dev/null | pfs_field status; }
pfs_wait() { # DESCRIPTION COMMAND...: polls for up to 30 seconds.
    pfs_description=$1
    shift
    pfs_deadline=$(($(date +%s) + 30))
    until "$@"; do
        [ "$(date +%s)" -lt "$pfs_deadline" ] || pfs_fail "timed out waiting for $pfs_description"
        sleep 0.05
    done
}
pfs_has_status() { test "$(pfs_status "$1" "$2")" = "$3"; }
pfs_has_line() { grep -qxF "$2" "$results/$1.receiver"; }
pfs_gone() { ! test -e "/proc/$1"; }
pfs_dump() {
    for kind in receiver receiver-err stdout stderr; do
        if [ -e "$results/$1.$kind" ]; then
            echo "--- $1.$kind" >&2
            cat "$results/$1.$kind" >&2
        fi
    done
}
# pfs_not_timeout TAG STATUS: 124, or 137/143 after KILL/TERM, is a hang.
pfs_not_timeout() {
    case "$2" in
    124 | 137 | 143) pfs_dump "$1"; pfs_fail "$1: timed out or was killed (status $2)" ;;
    esac
}
pfs_valid_pid() {
    case "$2" in "" | 0 | *[!0-9]*) pfs_fail "$1: bad PID '$2'" ;; esac
}
# pfs_stop TAG PID: waits for the workload's handler, signals it, and waits
# until its host PID is gone (reaped by its parent or the suite subreaper).
pfs_stop() {
    pfs_wait "$1 workload handler" test -e "$ready"
    kill -USR1 "$2"
    pfs_wait "$1 PID $2 to be reaped" pfs_gone "$2"
}

# pfs_listen TAG DIRECTORY ADDRESS MODE: starts a bounded receiver in
# DIRECTORY and waits until it listens. Sets pfs_receiver to its PID.
pfs_listen() {
    rm -f "$results/$1.ready"
    (cd "$2" && exec timeout -k 2 60 "$receiver" "$3" "$results/$1.ready" "$4") \
        > "$results/$1.receiver" 2> "$results/$1.receiver-err" &
    pfs_receiver=$!
    pfs_receivers="$pfs_receivers $pfs_receiver"
    pfs_wait "$1 receiver to listen" test -e "$results/$1.ready"
}
# pfs_receiver_done TAG: the receiver must exit 0 on its own, not by timeout.
pfs_receiver_done() {
    if wait "$pfs_receiver"; then :; else
        pfs_status_code=$?
        pfs_not_timeout "$1" "$pfs_status_code"
        pfs_dump "$1"
        pfs_fail "$1: receiver failed with status $pfs_status_code"
    fi
}
# pfs_received TAG LABEL PID: the receiver got LABEL and a pidfd for PID.
pfs_received() {
    pfs_wait "$1 pidfd" pfs_has_line "$1" "signal0 ok"
    pfs_has_line "$1" "label $2" || { pfs_dump "$1"; pfs_fail "$1: expected label $2"; }
    pfs_valid_pid "$1" "$3"
    pfs_has_line "$1" "pid $3" || { pfs_dump "$1"; pfs_fail "$1: pidfd does not name PID $3"; }
}
# pfs_summary TAG: the receiver's PID-independent record, compared with runc.
pfs_summary() {
    pfs_has_line "$1" "after-exit ESRCH" && pfs_has_line "$1" "eof" || { pfs_dump "$1"; pfs_fail "$1: incomplete receiver record"; }
    grep -v '^pid ' "$results/$1.receiver" > "$results/$1.summary"
}
pfs_workload_gone() { ! grep -qF "$marker" /proc/[0-9]*/cmdline 2>/dev/null; }

# pfs_observe IMPL RT MODE: one launch whose receiver checks the live pidfd.
pfs_observe() {
    impl=$1 rt=$2 mode=$3
    tag=$mode-$impl
    pidfile=$scratch/$tag.pid
    rm -f "$pidfile" "$ready"
    case "$mode" in
    run)
        # Relative: the listener is in the bundle, the runtime elsewhere.
        pfs_listen "$tag" "$bundles/waiter" "$tag.sock" signal
        (cd "$elsewhere" && exec $rt run --pidfd-socket "$tag.sock" --pid-file "$pidfile" --bundle "$bundles/waiter" "$tag") \
            < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr" &
        pfs_runner=$!
        pfs_wait "$tag PID file" test -s "$pidfile"
        pid=$(cat "$pidfile")
        pfs_received "$tag" standard "$pid"
        test "$($rt state "$tag" | pfs_field pid)" = "$pid" || pfs_fail "$tag: state PID differs from the pidfd"
        pfs_wait "$tag workload handler" test -e "$ready"
        kill -USR1 "$pid"
        if wait "$pfs_runner"; then pfs_fail "$tag: run did not report the workload status"; else
            pfs_run_status=$?
        fi
        pfs_not_timeout "$tag" "$pfs_run_status"
        test "$pfs_run_status" = 7 || { pfs_dump "$tag"; pfs_fail "$tag: run exited $pfs_run_status, expected 7"; }
        pfs_wait "$tag PID $pid to be reaped" pfs_gone "$pid"
        ;;
    detached | created)
        address=$scratch/sockets/$tag.sock
        command="run --detach"
        if [ "$mode" = created ]; then
            # runc dials Go's "@name" as an abstract address.
            address=@pidfd-$tag-$$
            command=create
        fi
        pfs_listen "$tag" "$scratch/sockets" "$address" signal
        $rt $command --pidfd-socket "$address" --pid-file "$pidfile" --bundle "$bundles/waiter" "$tag" \
            < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr" \
            || { pfs_status_code=$?; pfs_not_timeout "$tag" "$pfs_status_code"; pfs_dump "$tag"; pfs_fail "$tag: $command failed"; }
        pid=$(cat "$pidfile")
        pfs_valid_pid "$tag" "$pid"
        test "$($rt state "$tag" | pfs_field pid)" = "$pid" || pfs_fail "$tag: state PID differs from the PID file"
        # The created init sent its pidfd during create, before start.
        pfs_received "$tag" standard "$pid"
        if [ "$mode" = created ]; then
            test "$(pfs_status "$rt" "$tag")" = created || pfs_fail "$tag: no longer created before start"
            $rt start "$tag" || pfs_fail "$tag: start failed"
            test "$($rt state "$tag" | pfs_field pid)" = "$pid" || pfs_fail "$tag: start changed the init"
        fi
        pfs_stop "$tag" "$pid"
        pfs_wait "$tag to stop" pfs_has_status "$rt" "$tag" stopped
        $rt delete "$tag"
        ;;
    exec | exec-process)
        if [ "$mode" = exec ]; then
            # Relative: command exec resolves it in the recorded bundle.
            pfs_listen "$tag" "$bundles/sleeper" "$tag.sock" signal
            set -- "box-$impl" /bin/sh -c "$waiter_script" "$marker"
        else
            # Relative: --process resolves it in the caller's directory.
            pfs_listen "$tag" "$elsewhere" "$tag.sock" signal
            set -- --process "$scratch/process.json" "box-$impl"
        fi
        (cd "$elsewhere" && exec $rt exec --pidfd-socket "$tag.sock" --pid-file "$pidfile" "$@") \
            < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr" &
        pfs_runner=$!
        pfs_wait "$tag PID file" test -s "$pidfile"
        pid=$(cat "$pidfile")
        pfs_received "$tag" setns "$pid"
        pfs_wait "$tag workload handler" test -e "$ready"
        kill -USR1 "$pid"
        if wait "$pfs_runner"; then pfs_fail "$tag: exec did not report the workload status"; else
            pfs_run_status=$?
        fi
        pfs_not_timeout "$tag" "$pfs_run_status"
        test "$pfs_run_status" = 7 || { pfs_dump "$tag"; pfs_fail "$tag: exec exited $pfs_run_status, expected 7"; }
        pfs_wait "$tag PID $pid to be reaped" pfs_gone "$pid"
        ;;
    exec-detached)
        pfs_listen "$tag" "$scratch/sockets" "$scratch/sockets/$tag.sock" signal
        $rt exec --detach --pidfd-socket "$scratch/sockets/$tag.sock" --pid-file "$pidfile" "box-$impl" \
            /bin/sh -c "$waiter_script" "$marker" \
            < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr" \
            || { pfs_status_code=$?; pfs_not_timeout "$tag" "$pfs_status_code"; pfs_dump "$tag"; pfs_fail "$tag: detached exec failed"; }
        pid=$(cat "$pidfile")
        pfs_received "$tag" setns "$pid"
        pfs_stop "$tag" "$pid"
        ;;
    esac
    rm -f "$ready"
    pfs_receiver_done "$tag"
    pfs_summary "$tag"
}

# pfs_descriptors IMPL RT MODE: with --preserve-fds 1, the workload sees
# exactly 0-3, so neither the connection nor any pidfd reaches it. The probe
# may exit and be reaped before the receiver reads fdinfo (observe mode).
pfs_descriptors() {
    impl=$1 rt=$2 mode=$3
    tag=fds-$mode-$impl
    pfs_listen "$tag" "$scratch/sockets" "$scratch/sockets/$tag.sock" observe
    case "$mode" in
    run) set -- run --preserve-fds 1 --pidfd-socket "$scratch/sockets/$tag.sock" --bundle "$bundles/probe" "$tag" ;;
    exec) set -- exec --preserve-fds 1 --pidfd-socket "$scratch/sockets/$tag.sock" "box-$impl" /bin/fd-probe ;;
    esac
    $rt "$@" 3< "$scratch/process.json" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr" \
        || { pfs_status_code=$?; pfs_not_timeout "$tag" "$pfs_status_code"; pfs_dump "$tag"; pfs_fail "$tag: launch failed"; }
    grep -qxF "fds 0 1 2 3" "$results/$tag.stdout" || { pfs_dump "$tag"; pfs_fail "$tag: expected exactly descriptors 0 1 2 3"; }
    pfs_receiver_done "$tag"
    pfs_summary "$tag"
}

pfs_shared() {
    impl=$1 rt=$2
    $rt run --detach --bundle "$bundles/sleeper" "box-$impl" < /dev/null > /dev/null 2>&1 \
        || pfs_fail "$impl: cannot start the exec target"
    for mode in run detached created exec exec-process exec-detached; do pfs_observe "$impl" "$rt" "$mode"; done
    for mode in run exec; do pfs_descriptors "$impl" "$rt" "$mode"; done
    echo "$impl: pidfd labels, identity, liveness, reaping, relative resolution, and descriptor isolation ok"
}

# pfs_rejects RT TAG ID COMMAND...: COMMAND fails, never by timeout, and
# leaves no state for ID and no workload.
pfs_rejects() {
    rt=$1 tag=$2 id=$3
    shift 3
    if "$@" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"; then
        pfs_dump "$tag"; pfs_fail "$tag: succeeded"
    else
        pfs_status_code=$?
    fi
    pfs_not_timeout "$tag" "$pfs_status_code"
    if [ -n "$id" ] && $rt state "$id" > /dev/null 2>&1; then pfs_fail "$tag: failed launch left state"; fi
    pfs_wait "$tag workload to be gone" pfs_workload_gone
}
# pfs_undialled RT TAG ID COMMAND...: as pfs_rejects, with a listener at
# $scratch/sockets/TAG.sock that must see no connection.
pfs_undialled() {
    pfs_listen "$2" "$scratch/sockets" "$scratch/sockets/$2.sock" untouched
    pfs_rejects "$@"
    rm -f "$results/$2.ready"
    pfs_receiver_done "$2"
    pfs_has_line "$2" untouched || pfs_fail "$2: listener was dialled"
}
pfs_failures() {
    impl=$1 rt=$2
    box_pid=$($rt state "box-$impl" | pfs_field pid)
    : > "$scratch/sockets/not-a-socket"
    long=$scratch/sockets/$(printf '%0120d' 0)
    for command in run create; do
        pfs_rejects "$rt" "missing-$command-$impl" "missing-$command-$impl" $rt $command \
            --pidfd-socket "$scratch/sockets/missing.sock" --bundle "$bundles/waiter" "missing-$command-$impl"
        pfs_rejects "$rt" "not-socket-$command-$impl" "not-socket-$command-$impl" $rt $command \
            --pidfd-socket "$scratch/sockets/not-a-socket" --bundle "$bundles/waiter" "not-socket-$command-$impl"
        pfs_rejects "$rt" "long-$command-$impl" "long-$command-$impl" $rt $command \
            --pidfd-socket "$long" --bundle "$bundles/waiter" "long-$command-$impl"
        pfs_rejects "$rt" "no-value-$command-$impl" "no-value-$command-$impl" $rt $command \
            --bundle "$bundles/waiter" "no-value-$command-$impl" --pidfd-socket
        # A duplicate ID is refused before the listener is dialled.
        tag=duplicate-$command-$impl
        pfs_undialled "$rt" "$tag" "" $rt $command --pidfd-socket "$scratch/sockets/$tag.sock" \
            --bundle "$bundles/waiter" "box-$impl"
    done
    pfs_rejects "$rt" "missing-exec-$impl" "" $rt exec --pidfd-socket "$scratch/sockets/missing.sock" \
        "box-$impl" /bin/sh -c 'sleep 1000' "$marker"
    pfs_rejects "$rt" "long-exec-$impl" "" $rt exec --pidfd-socket "$long" "box-$impl" /bin/sh -c 'sleep 1000' "$marker"
    # An unknown container is refused before the listener is dialled.
    tag=unknown-exec-$impl
    pfs_undialled "$rt" "$tag" "" $rt exec --pidfd-socket "$scratch/sockets/$tag.sock" \
        "absent-$impl" /bin/sh -c 'sleep 1000' "$marker"
    test "$(pfs_status "$rt" "box-$impl")" = running || pfs_fail "$impl: exec target stopped"
    test "$($rt state "box-$impl" | pfs_field pid)" = "$box_pid" || pfs_fail "$impl: exec target init changed"
    echo "$impl: missing, non-socket, over-long, and valueless sockets fail cleanly; refused IDs dial nothing"
}

pfs_shared swift "$ours"
pfs_failures swift "$ours"
# Deliberate difference: runc treats an empty value as an absent option.
for command in run create; do
    pfs_rejects "$ours" "empty-$command" "empty-$command" $ours $command --pidfd-socket "" \
        --bundle "$bundles/waiter" "empty-$command"
done
pfs_rejects "$ours" empty-exec "" $ours exec --pidfd-socket "" box-swift /bin/sh -c 'sleep 1000' "$marker"
$ours delete --force box-swift

if [ "$compare" = 1 ]; then
    pfs_shared runc "$theirs"
    pfs_failures runc "$theirs"
    $theirs delete --force box-runc
    for record in $(cd "$results" && ls -- *-swift.summary); do
        theirs_record=$(echo "$record" | sed 's/-swift\./-runc./')
        cmp -s "$results/$record" "$results/$theirs_record" || {
            diff "$results/$theirs_record" "$results/$record" >&2 || :
            pfs_fail "$record differs from runc (diff: runc -> swift)"
        }
    done
fi

pfs_wait "every workload to be gone" pfs_workload_gone
test -z "$($ours list -q)" || pfs_fail "containers left behind"
test -z "$(ls -A "$state_root")" || { ls -A "$state_root" >&2; pfs_fail "state left behind"; }
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Pidfd-socket integration checks passed (comparison: $comparison): one labelled pidfd per launch naming the PID-file and state PID in foreground run, detached run, create before start, exec, exec --detach, and exec --process, as uid 1000, through bundle-relative, caller-relative, absolute, and abstract host addresses; signal 0, exit, and ESRCH after reaping through it; no descriptor leaks with --preserve-fds; failing sockets and invalid values leave no state, workload, or changed container; refused IDs dial nothing."
