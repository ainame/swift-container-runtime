#!/bin/sh
# Socket activation (LISTEN_FDS) checks, compared with runc. The host
# fixture scripts/fixtures/activation-launcher.c binds a listening Unix
# socket as descriptor 3, sets LISTEN_FDS, LISTEN_PID, and
# LISTEN_FDNAMES=host-name, and executes the runtime in the same process,
# so LISTEN_PID is the runtime's real PID (only the outer timeout forks).
# The static workload scripts/fixtures/activation-probe.c prints its
# LISTEN_* variables and open descriptors, and serves one request on 3.
# With LISTEN_FDS=1 and --preserve-fds 1, foreground run, detached run, and
# create/start must give the uid 1000 workload exactly 0-4 (the socket,
# then the explicit descriptor; 5 is dropped), LISTEN_FDS=1 and
# LISTEN_PID=1, and no host LISTEN_FDNAMES. The socket must answer from
# inside the container. Activation variables override configured ones,
# which are otherwise kept; absent, malformed, mismatched, and
# non-positive values are ignored; a missing activation or explicit
# descriptor fails without state; exec ignores host activation.
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
sockets=$scratch/sockets
launcher=$scratch/activation-launcher
# Direct invocations for the launcher, which must exec the runtime itself.
ours_direct="$runtime --root $state_root"
ours="timeout -k 2 60 $ours_direct"

sa_cleanup() {
    for id in $($ours list -q 2>/dev/null); do $ours delete --force "$id" >/dev/null 2>&1 || :; done
    if [ "$compare" = 1 ]; then
        for id in $($theirs list -q 2>/dev/null); do $theirs delete --force "$id" >/dev/null 2>&1 || :; done
    fi
    rm -rf "$scratch"
}
trap sa_cleanup EXIT
trap 'exit 1' HUP INT TERM

sa_fail() {
    echo "socket-activation-integration: $*" >&2
    exit 1
}

if ldd "$busybox" >/dev/null 2>&1; then sa_fail "BusyBox at $busybox must be statically linked"; fi
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || sa_fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac
if [ "$compare" = 1 ]; then
    theirs_direct="$(command -v runc) --root $runc_root"
    theirs="timeout -k 2 60 $theirs_direct"
fi

# Rootfs: static BusyBox plus the static probe. Sockets live outside it.
rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$results" "$inputs" "$sockets"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
"$cc" -static -O2 -Wall -Wextra -Werror -o "$rootfs/bin/activation-probe" "$here/fixtures/activation-probe.c" \
    || sa_fail "cannot build the static probe with $cc"
if ldd "$rootfs/bin/activation-probe" >/dev/null 2>&1; then sa_fail "the probe is not statically linked"; fi
"$cc" -O2 -Wall -Wextra -Werror -o "$launcher" "$here/fixtures/activation-launcher.c" \
    || sa_fail "cannot build the launcher fixture with $cc"

# Root-owned 0600 files, so the uid 1000 workload can read them only by
# inheritance, and a chown would show.
printf 'four\n' > "$inputs/four"
printf 'five\n' > "$inputs/five"
chmod 600 "$inputs/four" "$inputs/five"

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}
]'
bundles=$scratch/bundles
# sa_config NAME ARGS_JSON ENV_JSON
sa_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": {"uid": 1000, "gid": 1000}, "args": $2, "env": $3, "cwd": "/"},
  "hostname": "activation",
  "mounts": $mounts,
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}
}
EOF
}
sa_config probe '["/bin/activation-probe"]' '["PATH=/bin"]'
sa_config configured '["/bin/activation-probe"]' \
    '["PATH=/bin", "LISTEN_PID=99", "LISTEN_FDS=9", "LISTEN_FDNAMES=cfg-name"]'
sa_config sleeper '["/bin/sleep", "1000"]' '["PATH=/bin"]'

sa_field() { sed -n "s/^ *\"$1\" *: *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p"; }
sa_status() { $1 state "$2" 2>/dev/null | sa_field status; }
sa_wait() { # DESCRIPTION COMMAND...: polls for up to 30 seconds.
    sa_description=$1
    shift
    sa_deadline=$(($(date +%s) + 30))
    until "$@"; do
        [ "$(date +%s)" -lt "$sa_deadline" ] || sa_fail "timed out waiting for $sa_description"
        sleep 0.05
    done
}
sa_has_status() { test "$(sa_status "$1" "$2")" = "$3"; }
sa_wait_status() { sa_wait "$2 to become $3" sa_has_status "$1" "$2" "$3"; }
sa_accepting() { grep -qxF accepting "$results/$1.stdout"; }
sa_dump() {
    for kind in stdout stderr; do
        [ ! -e "$results/$1.$kind" ] || { echo "--- $1.$kind" >&2; cat "$results/$1.$kind" >&2; }
    done
}
# sa_not_timeout TAG STATUS: 124, or 137/143 after KILL/TERM, is a hang.
sa_not_timeout() {
    case "$2" in
    124 | 137 | 143) sa_dump "$1"; sa_fail "$1: timed out or was killed (status $2)" ;;
    esac
}
# sa_launch TAG FDS PID COMMAND...: COMMAND under the launcher, with socket
# TAG.sock as 3, "four" as 4, and "five" as 5; stdout and stderr captured.
sa_launch() {
    sa_tag=$1 sa_fds=$2 sa_pid=$3
    shift 3
    rm -f "$sockets/$sa_tag.sock"
    timeout -k 2 60 "$launcher" listen "$sockets/$sa_tag.sock" "$sa_fds" "$sa_pid" "$@" \
        4< "$inputs/four" 5< "$inputs/five" < /dev/null > "$results/$sa_tag.stdout" 2> "$results/$sa_tag.stderr"
}
sa_step() { # TAG FDS PID COMMAND...: sa_launch, which must succeed.
    if sa_launch "$@"; then :; else
        sa_step_status=$?
        sa_not_timeout "$1" "$sa_step_status"
        sa_dump "$1"
        sa_fail "$1: command failed with status $sa_step_status"
    fi
}
# sa_expect TAG LINE...: the record of TAG is exactly LINE....
sa_expect() {
    sa_expect_tag=$1
    shift
    printf '%s\n' "$@" > "$results/$sa_expect_tag.expected"
    cmp -s "$results/$sa_expect_tag.expected" "$results/$sa_expect_tag.stdout" || {
        diff "$results/$sa_expect_tag.expected" "$results/$sa_expect_tag.stdout" >&2 || :
        sa_dump "$sa_expect_tag"
        sa_fail "$sa_expect_tag: unexpected record (diff: expected -> actual)"
    }
}
# sa_request TAG: the workload is accepting on TAG.sock and answers.
sa_request() {
    sa_wait "$1 to accept" sa_accepting "$1"
    reply=$("$launcher" connect "$sockets/$1.sock" ping) || { sa_dump "$1"; sa_fail "$1: no reply from the workload"; }
    test "$reply" = "pong ping" || sa_fail "$1: unexpected reply '$reply'"
}
sa_no_state() { # RT TAG
    if $1 state "$2" > /dev/null 2>&1; then sa_fail "$2: failed launch left state"; fi
}

# sa_serve IMPL DIRECT RT MODE BUNDLE: LISTEN_FDS=1 and --preserve-fds 1.
sa_serve() {
    impl=$1 direct=$2 rt=$3 mode=$4 bundle=$5
    tag=$mode-$bundle-$impl
    case "$mode" in
    run)
        sa_launch "$tag" 1 self $direct run --preserve-fds 1 --bundle "$bundles/$bundle" "$tag" &
        launched=$!
        sa_request "$tag"
        if wait "$launched"; then :; else
            status=$?
            sa_not_timeout "$tag" "$status"
            sa_dump "$tag"
            sa_fail "$tag: run failed with status $status"
        fi
        ;;
    detached)
        sa_step "$tag" 1 self $direct run --detach --preserve-fds 1 --bundle "$bundles/$bundle" "$tag"
        sa_request "$tag"
        sa_wait_status "$rt" "$tag" stopped
        $rt delete "$tag"
        ;;
    created)
        sa_step "$tag" 1 self $direct create --preserve-fds 1 --bundle "$bundles/$bundle" "$tag"
        test "$(sa_status "$rt" "$tag")" = created || { sa_dump "$tag"; sa_fail "$tag: not created"; }
        test ! -s "$results/$tag.stdout" || { sa_dump "$tag"; sa_fail "$tag: workload ran before start"; }
        # start has neither activation nor descriptors of its own to pass.
        $rt start "$tag" < /dev/null > /dev/null 2>&1 || sa_fail "$tag: start failed"
        sa_request "$tag"
        sa_wait_status "$rt" "$tag" stopped
        $rt delete "$tag"
        ;;
    esac
    case "$bundle" in
    probe) names='LISTEN_FDNAMES (unset)' ;;
    configured) names='LISTEN_FDNAMES cfg-name' ;;
    esac
    sa_expect "$tag" 'LISTEN_FDS 1' 'LISTEN_PID 1' "$names" 'fds 0 1 2 3 4' 'fd4 four' accepting 'served ping'
}

# sa_exec IMPL DIRECT: host activation does not reach exec, which passes
# only an explicit count and the given environment.
sa_exec() {
    impl=$1 direct=$2
    tag=exec-plain-$impl
    sa_step "$tag" 1 self $direct exec "box-$impl" /bin/activation-probe
    sa_expect "$tag" 'LISTEN_FDS (unset)' 'LISTEN_PID (unset)' 'LISTEN_FDNAMES (unset)' 'fds 0 1 2'
    tag=exec-explicit-$impl
    sa_launch "$tag" 1 self $direct exec --preserve-fds 1 -e LISTEN_FDS=1 "box-$impl" /bin/activation-probe &
    launched=$!
    sa_request "$tag"
    if wait "$launched"; then :; else
        status=$?
        sa_not_timeout "$tag" "$status"
        sa_dump "$tag"
        sa_fail "$tag: exec failed with status $status"
    fi
    sa_expect "$tag" 'LISTEN_FDS 1' 'LISTEN_PID (unset)' 'LISTEN_FDNAMES (unset)' 'fds 0 1 2 3' accepting 'served ping'
}

sa_shared() {
    impl=$1 direct=$2 rt=$3
    for mode in run detached created; do
        for bundle in probe configured; do sa_serve "$impl" "$direct" "$rt" "$mode" "$bundle"; done
    done
    $rt run --detach --bundle "$bundles/sleeper" "box-$impl" < /dev/null > /dev/null 2>&1 \
        || sa_fail "$impl: cannot start the exec target"
    sa_exec "$impl" "$direct"
    $rt delete --force "box-$impl"
    echo "$impl: activation served in run, run --detach, and create/start; exec ignores host activation"
}

sa_shared swift "$ours_direct" "$ours"

# Ignored activation keeps the configured variables and drops descriptor 3.
# Values follow Go's strconv.Atoi, so whitespace and hex are malformed.
sa_ignored() { # TAG FDS PID
    sa_step "ignored-$1" "$2" "$3" $ours_direct run --bundle "$bundles/configured" "ignored-$1"
    sa_expect "ignored-$1" 'LISTEN_FDS 9' 'LISTEN_PID 99' 'LISTEN_FDNAMES cfg-name' 'fds 0 1 2'
    sa_no_state "$ours" "ignored-$1"
}
sa_ignored absent - -
sa_ignored no-pid 1 -
sa_ignored no-fds - self
sa_ignored mismatched 1 other
sa_ignored zero 0 self
sa_ignored negative -1 self
sa_ignored spaced ' 1' self
sa_ignored hex 0x1 self
sa_ignored bad-pid 1 abc
sa_ignored spaced-pid 1 ' self'
echo "swift: absent, mismatched, malformed, and non-positive activation ignored"

# A missing activation or explicit descriptor is found before any runtime
# descriptor could take its number, so nothing is created.
for command in run create; do
    tag=missing-activation-$command
    if sa_launch "$tag" 2 self $ours_direct $command --bundle "$bundles/probe" "$tag" 4<&-; then
        sa_fail "$tag: succeeded"
    else
        status=$?; sa_not_timeout "$tag" "$status"
    fi
    grep -qF 'unable to stat preserved-fd 1 (of 2)' "$results/$tag.stderr" || { sa_dump "$tag"; sa_fail "$tag: unexpected error"; }
    test ! -s "$results/$tag.stdout" || { sa_dump "$tag"; sa_fail "$tag: workload ran"; }
    sa_no_state "$ours" "$tag"
    tag=missing-explicit-$command
    if sa_launch "$tag" 1 self $ours_direct $command --preserve-fds 1 --bundle "$bundles/probe" "$tag" 4<&-; then
        sa_fail "$tag: succeeded"
    else
        status=$?; sa_not_timeout "$tag" "$status"
    fi
    grep -qF 'unable to stat preserved-fd 1 (of 2)' "$results/$tag.stderr" || { sa_dump "$tag"; sa_fail "$tag: unexpected error"; }
    test ! -s "$results/$tag.stdout" || { sa_dump "$tag"; sa_fail "$tag: workload ran"; }
    sa_no_state "$ours" "$tag"
done
echo "swift: missing activation and explicit descriptors fail without state"

if [ "$compare" = 1 ]; then
    sa_shared runc "$theirs_direct" "$theirs"
    for record in $(cd "$results" && ls -- *-probe-swift.stdout exec-*-swift.stdout); do
        theirs_record=$(echo "$record" | sed 's/-swift\./-runc./')
        cmp -s "$results/$record" "$results/$theirs_record" || {
            diff "$results/$theirs_record" "$results/$record" >&2 || :
            sa_fail "$record differs from runc (diff: runc -> swift)"
        }
    done
fi

test -z "$(find "$rootfs" -type s)" || sa_fail "a socket appeared inside the rootfs"
for file in "$inputs/four" "$inputs/five" "$sockets"/*.sock; do
    test "$(stat -c '%u:%g' "$file")" = 0:0 || sa_fail "${file##*/} ownership changed"
done
test -z "$($ours list -q)" || sa_fail "containers left behind"
test -z "$(ls -A "$state_root")" || { ls -A "$state_root" >&2; sa_fail "state left behind"; }
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Socket activation integration checks passed (comparison: $comparison)."
