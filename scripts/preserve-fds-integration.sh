#!/bin/sh
# --preserve-fds checks, compared with runc: with caller descriptors 3, 4,
# 5, and 7 open, the workload of foreground run, detached run, create/start,
# exec, exec --detach, and exec --process sees exactly 0-2 plus 3..2+N at
# the same numbers, reads 3 and 4, writes 5, keeps its stdio, and inherits
# no runtime descriptor; counts 0 and 2 drop 5 and above; nothing preserved
# is chowned for the uid 1000 workload; a hole in the range, a negative or
# out-of-range count, and a missing executable fail without state, process,
# or a changed container. The probe is scripts/fixtures/fd-probe.c, linked
# statically into a static BusyBox rootfs.
# Run as root inside a disposable Linux VM. Requires CC (default clang) able
# to link statically and BusyBox (BUSYBOX).
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/swift-container-runtime}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
busybox=${BUSYBOX:-/bin/busybox}
cc=${CC:-clang}
compare=${RUNC_COMPARE:-auto}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
state_root=$scratch/state
runc_root=$scratch/runc-state
results=$scratch/results
inputs=$scratch/inputs
ours="timeout -k 2 60 $runtime --root $state_root"
theirs="timeout -k 2 60 runc --root $runc_root"

pfd_cleanup() {
    for id in $($ours list -q 2>/dev/null); do $ours delete --force "$id" >/dev/null 2>&1 || :; done
    if [ "$compare" = 1 ]; then
        for id in $($theirs list -q 2>/dev/null); do $theirs delete --force "$id" >/dev/null 2>&1 || :; done
    fi
    rm -rf "$scratch"
}
trap pfd_cleanup EXIT
trap 'exit 1' HUP INT TERM

pfd_fail() {
    echo "preserve-fds-integration: $*" >&2
    exit 1
}

if ldd "$busybox" >/dev/null 2>&1; then pfd_fail "BusyBox at $busybox must be statically linked"; fi
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || pfd_fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

# Rootfs: static BusyBox plus the static probe.
rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$results" "$inputs"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
"$cc" -static -O2 -Wall -Wextra -Werror -o "$rootfs/bin/fd-probe" "$here/fixtures/fd-probe.c" \
    || pfd_fail "cannot build the static probe with $cc"
if ldd "$rootfs/bin/fd-probe" >/dev/null 2>&1; then pfd_fail "the probe is not statically linked"; fi
# Detached exec children are reaped by this caller, as runc documents.
"$cc" -O2 -Wall -Wextra -Werror -o "$scratch/subreaper" "$here/fixtures/subreaper.c" \
    || pfd_fail "cannot build the subreaper fixture with $cc"

# Caller descriptors are root-owned 0600 files, so the uid 1000 workload can
# use them only through inheritance, and a chown would show.
printf 'three\n' > "$inputs/three"
printf 'four\n' > "$inputs/four"
printf 'seven\n' > "$inputs/seven"
printf 'stdin-data\n' > "$inputs/stdin"
chmod 600 "$inputs/three" "$inputs/four" "$inputs/seven" "$inputs/stdin"

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}
]'
bundles=$scratch/bundles
user='{"uid": 1000, "gid": 1000}'
# pfd_config NAME ARGS_JSON
pfd_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": $user, "args": $2, "env": ["PATH=/bin"], "cwd": "/"},
  "hostname": "fdbox",
  "mounts": $mounts,
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}
}
EOF
}
pfd_config probe '["/bin/fd-probe"]'
pfd_config sleeper '["/bin/sleep", "1000"]'
pfd_config missing '["/bin/no-such-binary"]'
cat > "$scratch/process.json" <<EOF
{"terminal": false, "user": $user, "args": ["/bin/fd-probe"], "env": ["PATH=/bin"], "cwd": "/"}
EOF

pfd_field() { sed -n "s/^ *\"$1\" *: *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p"; }
pfd_status() { $1 state "$2" 2>/dev/null | pfd_field status; }
pfd_wait() { # DESCRIPTION COMMAND...: polls for up to 30 seconds.
    pfd_description=$1
    shift
    pfd_deadline=$(($(date +%s) + 30))
    until "$@"; do
        [ "$(date +%s)" -lt "$pfd_deadline" ] || pfd_fail "timed out waiting for $pfd_description"
        sleep 0.05
    done
}
pfd_has_status() { test "$(pfd_status "$1" "$2")" = "$3"; }
pfd_wait_status() { pfd_wait "$2 to become $3" pfd_has_status "$1" "$2" "$3"; }
pfd_has_record() { grep -q '^stdin ' "$results/$1.stdout"; }

pfd_dump() {
    for kind in stdout stderr fd5; do
        if [ -e "$results/$1.$kind" ]; then
            echo "--- $1.$kind" >&2
            cat "$results/$1.$kind" >&2
        fi
    done
}
# pfd_not_timeout TAG STATUS: 124, or 137/143 after KILL/TERM, is a hang.
pfd_not_timeout() {
    case "$2" in
    124 | 137 | 143) pfd_dump "$1"; pfd_fail "$1: timed out or was killed (status $2)" ;;
    esac
}
# pfd_with TAG COMMAND...: runs COMMAND with caller descriptors 3, 4, 5, and
# 7 open (not close-on-exec, as any shell redirection), stdin from a file,
# and stdout/stderr captured. Returns COMMAND's status.
pfd_with() {
    pfd_tag=$1
    shift
    : > "$results/$pfd_tag.fd5"
    chmod 600 "$results/$pfd_tag.fd5"
    "$@" 3< "$inputs/three" 4< "$inputs/four" 5>> "$results/$pfd_tag.fd5" 7< "$inputs/seven" \
        < "$inputs/stdin" > "$results/$pfd_tag.stdout" 2> "$results/$pfd_tag.stderr"
}
pfd_step() { # TAG COMMAND...: pfd_with, which must succeed.
    pfd_step_tag=$1
    if pfd_with "$@"; then :; else
        pfd_step_status=$?
        pfd_not_timeout "$pfd_step_tag" "$pfd_step_status"
        pfd_dump "$pfd_step_tag"
        pfd_fail "$pfd_step_tag: command failed with status $pfd_step_status"
    fi
}
# pfd_expect TAG COUNT: the probe record of TAG matches --preserve-fds COUNT.
pfd_expect() {
    tag=$1 count=$2
    case "$count" in
    0) fds="0 1 2" ;;
    2) fds="0 1 2 3 4" ;;
    3) fds="0 1 2 3 4 5" ;;
    esac
    grep -qxF "fds $fds" "$results/$tag.stdout" || { pfd_dump "$tag"; pfd_fail "$tag: expected exactly descriptors $fds"; }
    grep -qxF "stdin stdin-data" "$results/$tag.stdout" || { pfd_dump "$tag"; pfd_fail "$tag: stdin changed"; }
    grep -qxF "fd-probe stderr" "$results/$tag.stderr" || { pfd_dump "$tag"; pfd_fail "$tag: stderr changed"; }
    if [ "$count" = 0 ]; then
        ! grep -q '^fd[34] ' "$results/$tag.stdout" || { pfd_dump "$tag"; pfd_fail "$tag: read an unpreserved descriptor"; }
    else
        grep -qxF "fd3 three" "$results/$tag.stdout" && grep -qxF "fd4 four" "$results/$tag.stdout" \
            || { pfd_dump "$tag"; pfd_fail "$tag: cannot read preserved descriptors 3 and 4"; }
    fi
    if [ "$count" = 3 ]; then
        test "$(cat "$results/$tag.fd5")" = "fd5 written" || { pfd_dump "$tag"; pfd_fail "$tag: no write through descriptor 5"; }
    else
        test ! -s "$results/$tag.fd5" || { pfd_dump "$tag"; pfd_fail "$tag: wrote an unpreserved descriptor 5"; }
    fi
    for file in "$inputs/three" "$inputs/four" "$results/$tag.fd5"; do
        test "$(stat -c '%u:%g:%a' "$file")" = "0:0:600" || pfd_fail "$tag: ${file##*/} ownership or mode changed"
    done
}

# pfd_observe IMPL RT MODE COUNT: one probe launch; TAG is MODE-COUNT-IMPL.
pfd_observe() {
    impl=$1 rt=$2 mode=$3 count=$4
    tag=$mode-$count-$impl
    option="--preserve-fds $count"
    [ "$count" != 0 ] || option=
    case "$mode" in
    run)
        pfd_step "$tag" $rt run $option --bundle "$bundles/probe" "$tag"
        ;;
    detached)
        pfd_step "$tag" $rt run --detach $option --bundle "$bundles/probe" "$tag"
        pfd_wait_status "$rt" "$tag" stopped
        $rt delete "$tag"
        ;;
    created)
        pfd_step "$tag" $rt create $option --bundle "$bundles/probe" "$tag"
        test "$(pfd_status "$rt" "$tag")" = created || { pfd_dump "$tag"; pfd_fail "$tag: not created"; }
        test ! -s "$results/$tag.stdout" || { pfd_dump "$tag"; pfd_fail "$tag: workload ran before start"; }
        # start has no descriptors of its own to pass.
        $rt start "$tag" < /dev/null > /dev/null 2>&1 3<&- 4<&- 5<&- 7<&- || pfd_fail "$tag: start failed"
        pfd_wait_status "$rt" "$tag" stopped
        $rt delete "$tag"
        ;;
    exec)
        pfd_step "$tag" $rt exec $option "box-$impl" /bin/fd-probe
        ;;
    exec-process)
        pfd_step "$tag" $rt exec $option --process "$scratch/process.json" "box-$impl"
        ;;
    exec-detached)
        # The subreaper reaps the reparented probe while the shell waits
        # until its host PID is gone; output alone does not prove exit. The
        # whole wait is bounded, so a hang ends in a rejected timeout status.
        pidfile=$scratch/$tag.pid
        rm -f "$pidfile"
        pfd_step "$tag" timeout -k 2 60 "$scratch/subreaper" sh -c '
            pidfile=$1
            shift
            "$@" || exit
            pid=$(cat "$pidfile") || exit 3
            case "$pid" in "" | 0 | *[!0-9]*) echo "bad exec PID file: $pid" >&2; exit 3 ;; esac
            while [ -e "/proc/$pid" ]; do sleep 0.05; done' \
            sh "$pidfile" $rt exec --detach --pid-file "$pidfile" $option "box-$impl" /bin/fd-probe
        ;;
    esac
    pfd_wait "$tag record" pfd_has_record "$tag"
    pfd_expect "$tag" "$count"
}

pfd_shared() {
    impl=$1 rt=$2
    $rt run --detach --bundle "$bundles/sleeper" "box-$impl" < /dev/null > /dev/null 2>&1 \
        || pfd_fail "$impl: cannot start the exec target"
    for mode in run detached created exec exec-process exec-detached; do
        for count in 3 2 0; do pfd_observe "$impl" "$rt" "$mode" "$count"; done
    done
    echo "$impl: preserved descriptors, dropped descriptors, stdio, and ownership ok in every launch mode"
}

# pfd_rejects IMPL RT TAG MESSAGE COMMAND...: COMMAND fails with MESSAGE (if
# any) on stderr, never by timeout, and runs nothing.
pfd_rejects() {
    impl=$1 rt=$2 tag=$3 message=$4
    shift 4
    if "$@" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"; then
        pfd_dump "$tag"; pfd_fail "$tag: succeeded"
    else
        status=$?
    fi
    pfd_not_timeout "$tag" "$status"
    [ -z "$message" ] || grep -qF -- "$message" "$results/$tag.stderr" || { pfd_dump "$tag"; pfd_fail "$tag: expected error '$message'"; }
    test ! -s "$results/$tag.stdout" || { pfd_dump "$tag"; pfd_fail "$tag: workload ran"; }
}
pfd_no_state() { # RT TAG
    if $1 state "$2" > /dev/null 2>&1; then pfd_fail "$2: failed launch left state"; fi
}
pfd_failures() {
    impl=$1 rt=$2
    box_pid=$($rt state "box-$impl" | pfd_field pid)
    # A hole at 4: only 3 and 5 are open. It is checked before any runtime
    # descriptor could fill it, so the launch fails before any state exists.
    # Swift only: runc opens /proc/self/fd before its check (utils_linux.go),
    # which can take the hole and pass that handle to the workload.
    if [ "$impl" = swift ]; then
        msg='unable to stat preserved-fd 1 (of 3)'
        for command in run create; do
            tag=hole-$command-$impl
            pfd_rejects "$impl" "$rt" "$tag" "$msg" \
                $rt $command --preserve-fds 3 --bundle "$bundles/probe" "$tag" 3< "$inputs/three" 4<&- 5< "$inputs/seven"
            pfd_no_state "$rt" "$tag"
        done
        pfd_rejects "$impl" "$rt" "hole-exec-$impl" "$msg" \
            $rt exec --preserve-fds 3 "box-$impl" /bin/fd-probe 3< "$inputs/three" 4<&- 5< "$inputs/seven"
    fi
    # A missing executable fails exec and run but leaves caller descriptors
    # usable and the exec target's init unchanged.
    # Within the same redirections, the caller then reads 3 and writes 5
    # (status 99 if it cannot).
    tag=missing-exec-$impl
    if pfd_with "$tag" sh -c '"$@"; status=$?
        read -r line <&3 && [ "$line" = three ] && echo caller-after >&5 || exit 99
        exit "$status"' sh $rt exec --preserve-fds 3 "box-$impl" /bin/no-such-binary
    then pfd_fail "$tag: succeeded"; else
        status=$?; pfd_not_timeout "$tag" "$status"
        [ "$status" != 99 ] || { pfd_dump "$tag"; pfd_fail "$tag: caller descriptors unusable after the failure"; }
    fi
    test "$(cat "$results/$tag.fd5")" = caller-after || { pfd_dump "$tag"; pfd_fail "$tag: descriptor 5 changed"; }
    tag=missing-run-$impl
    if pfd_with "$tag" $rt run --preserve-fds 3 --bundle "$bundles/missing" "$tag"; then pfd_fail "$tag: succeeded"; else
        status=$?; pfd_not_timeout "$tag" "$status"
    fi
    pfd_no_state "$rt" "$tag"
    test "$(pfd_status "$rt" "box-$impl")" = running || pfd_fail "$impl: exec target stopped"
    test "$($rt state "box-$impl" | pfd_field pid)" = "$box_pid" || pfd_fail "$impl: exec target init changed"
    echo "$impl: holes (swift) and missing executables fail cleanly"
}

pfd_shared swift "$ours"
pfd_failures swift "$ours"
# Strict differences from runc, which ignores a negative count: invalid
# counts are refused before anything is opened, and the largest count whose
# first internal descriptor, 3+N, fits Int32 is accepted and fails on the first missing one.
for value in -1 2147483645 99999999999999999999 abc; do
    for command in "run --bundle $bundles/probe" "create --bundle $bundles/probe"; do
        pfd_rejects swift "$ours" "count-$value" "" $ours ${command%% *} --preserve-fds "$value" ${command#* } "count-$value"
        pfd_no_state "$ours" "count-$value"
    done
    pfd_rejects swift "$ours" "count-exec-$value" "" $ours exec --preserve-fds "$value" box-swift /bin/fd-probe
done
pfd_rejects swift "$ours" count-max 'unable to stat preserved-fd 0 (of 2147483644)' \
    $ours run --preserve-fds 2147483644 --bundle "$bundles/probe" count-max 3<&-
pfd_no_state "$ours" count-max
$ours delete --force box-swift

if [ "$compare" = 1 ]; then
    pfd_shared runc "$theirs"
    pfd_failures runc "$theirs"
    $theirs delete --force box-runc
    for record in $(cd "$results" && ls -- run-*-swift.stdout detached-*-swift.stdout created-*-swift.stdout exec-*-swift.stdout); do
        theirs_record=$(echo "$record" | sed 's/-swift\./-runc./')
        cmp -s "$results/$record" "$results/$theirs_record" || {
            diff "$results/$theirs_record" "$results/$record" >&2 || :
            pfd_fail "$record differs from runc (diff: runc -> swift)"
        }
    done
fi

test -z "$($ours list -q)" || pfd_fail "containers left behind"
test -z "$(ls -A "$state_root")" || { ls -A "$state_root" >&2; pfd_fail "state left behind"; }
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Preserve-fds integration checks passed (comparison: $comparison): descriptors 3..2+N at the same numbers with nothing else in foreground run, detached run, create/start, exec, exec --detach, and exec --process; counts 0 and 2 drop 5 and above; stdio and ownership unchanged; holes, invalid counts, and missing executables fail without state or a changed container."
