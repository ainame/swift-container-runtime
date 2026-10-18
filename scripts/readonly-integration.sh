#!/bin/sh
# root.readonly checks, compared with runc. A static probe
# (scripts/fixtures/readonly-probe.c) reports the exact errno of real writes:
# with readonly true, writing an existing rootfs file and creating a file or
# directory fail with EROFS, while the /dev and /scratch tmpfs child mounts
# stay writable and a missing process.cwd is still created first. With
# readonly false or absent the same writes succeed, as root and as uid 1000
# (the test paths are world-writable, so EACCES cannot pass for EROFS). The
# host's rootfs content is unchanged by denied writes, its mount stays
# writable (also while a created container waits), and the rootfs mount's
# nosuid/nodev are kept. Runs foreground, detached, and create/start, plus
# setup failures that must leave no state or process.
# Run as root inside a disposable Linux VM. Requires CC (default clang) able
# to link statically. RUNC_COMPARE=auto (default) runs the shared checks
# under runc when it is installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/srunc}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cc=${CC:-clang}
compare=${RUNC_COMPARE:-auto}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
state_root=$scratch/state
runc_root=$scratch/runc-state
results=$scratch/results
fsroot=$scratch/fs
ours="timeout -k 2 60 $runtime --root $state_root"
theirs="timeout -k 2 60 runc --root $runc_root"

cleanup() {
    for id in $($ours list -q 2>/dev/null); do $ours delete --force "$id" >/dev/null 2>&1 || :; done
    if [ "$compare" = 1 ]; then
        for id in $($theirs list -q 2>/dev/null); do $theirs delete --force "$id" >/dev/null 2>&1 || :; done
    fi
    umount "$fsroot" 2>/dev/null || :
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Diagnostics go to fd 3, the script's stderr, even from inside a step whose
# stderr is redirected to a result file.
exec 3>&2
fail() {
    echo "readonly-integration: $*" >&3
    exit 1
}

case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

# The rootfs lives on its own nosuid,nodev tmpfs, so a remount that cleared
# the inherited flags would show, and the host mount can be inspected.
mkdir -p "$fsroot" "$results"
mount -t tmpfs -o nosuid,nodev,mode=755 tmpfs "$fsroot" || fail "cannot mount the host tmpfs"
rootfs=$fsroot/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/scratch" "$rootfs/data"
chmod 1777 "$rootfs/data"
"$cc" -static -O2 -o "$rootfs/bin/readonly-probe" "$here/fixtures/readonly-probe.c" \
    || fail "cannot build the static probe with $cc"
if ldd "$rootfs/bin/readonly-probe" >/dev/null 2>&1; then fail "the probe is not statically linked"; fi
probe=$rootfs/bin/readonly-probe

# Restores the rootfs between runs: one world-writable existing file, no
# created entries, and no cwd, which each run must create itself.
# Byte-exact host contents: unchanged after a denied write, and the
# original plus the probe's single appended byte after an allowed one.
printf 'host\n' > "$results/existing.original"
printf 'host\nx' > "$results/existing.appended"
reset_rootfs() {
    rm -rf "$rootfs/data/new" "$rootfs/data/newdir" "$rootfs/work"
    cp "$results/existing.original" "$rootfs/data/existing"
    chmod 0666 "$rootfs/data/existing"
}

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
  {"destination": "/scratch", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "nodev", "mode=1777", "size=1024k"]}
]'
operations='"/bin/readonly-probe", "id", "flags:/", "flags:/scratch", "write:/data/existing", "create:/data/new",
  "mkdir:/data/newdir", "create:/scratch/new", "mkdir:/scratch/dir", "write:/scratch/new", "cwd"'
# Root may also create in the root-owned /dev tmpfs and in the cwd the runtime made.
root_operations="$operations, \"create:/dev/probe\", \"create:cwd-file\""
bundles=$scratch/bundles
# write_config NAME READONLY_FIELD USER_JSON ARGS
write_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"$2},
  "process": {"terminal": false, "user": $3, "args": [$4], "env": ["PATH=/bin"], "cwd": "/work/missing"},
  "mounts": $mounts,
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}]}
}
EOF
}
for who in root user; do
    if [ "$who" = root ]; then user='{"uid": 0, "gid": 0}' ops=$root_operations; else user='{"uid": 1000, "gid": 1000}' ops=$operations; fi
    write_config "readonly-$who" ', "readonly": true' "$user" "$ops"
    write_config "writable-$who" ', "readonly": false' "$user" "$ops"
    write_config "absent-$who" '' "$user" "$ops"
done
write_config readonly-missing ', "readonly": true' '{"uid": 0, "gid": 0}' '"/bin/missing"'
mkdir -p "$bundles/readonly-sysctl"
sed 's|"namespaces"|"sysctl": {"kernel.domainname": "x"}, "namespaces"|' "$bundles/readonly-root/config.json" \
    > "$bundles/readonly-sysctl/config.json"

field() { sed -n "s/^ *\"$1\" *: *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p"; }
status_of() { $1 state "$2" 2>/dev/null | field status; }
pid_of() { $1 state "$2" | field pid; }
wait_until() { # DESCRIPTION COMMAND...: polls for up to 30 seconds.
    wait_description=$1
    shift
    wait_deadline=$(($(date +%s) + 30))
    until "$@"; do
        [ "$(date +%s)" -lt "$wait_deadline" ] || fail "timed out waiting for $wait_description"
        sleep 0.05
    done
}
has_status() { test "$(status_of "$1" "$2")" = "$3"; }
wait_status() { wait_until "$2 to become $3" has_status "$1" "$2" "$3"; }
dump() {
    for dump_kind in stdout stderr; do
        if [ -e "$results/$1.$dump_kind" ]; then
            echo "--- $1.$dump_kind" >&3
            cat "$results/$1.$dump_kind" >&3
        fi
    done
}
# not_timeout TAG COMMAND STATUS: a status from the timeout wrapper (124, or
# 137/143 after KILL/TERM) is a hang, never an expected outcome.
not_timeout() {
    case "$3" in
    124 | 137 | 143) dump "$1"; fail "$1: $2 timed out or was killed (status $3)" ;;
    esac
}
# step TAG COMMAND...: must exit 0; its status is captured directly.
step() {
    step_tag=$1
    shift
    if "$@"; then return 0; else step_status=$?; fi
    not_timeout "$step_tag" "$*" "$step_status"
    dump "$step_tag"
    fail "$step_tag: command failed with status $step_status: $*"
}
rootfs_identity=$(stat -L -c '%d:%i' "$rootfs")
# No process may keep the test rootfs as its root after a container ends.
no_process_left() {
    left_deadline=$(($(date +%s) + 10))
    while :; do
        left_remaining=
        for left_dir in /proc/[0-9]*; do
            left_identity=$(stat -L -c '%d:%i' "$left_dir/root" 2>/dev/null) || continue
            [ "$left_identity" != "$rootfs_identity" ] || left_remaining="$left_remaining ${left_dir#/proc/}"
        done
        [ -n "$left_remaining" ] || return 0
        [ "$(date +%s)" -lt "$left_deadline" ] || fail "$1: processes remain:$left_remaining"
        sleep 0.05
    done
}
# expect FILE TAG LINES: each |-separated line occurs exactly in FILE.
expect() {
    expect_file=$1 expect_tag=$2 expect_lines=$3
    expect_old_ifs=$IFS
    IFS='|'
    for expect_line in $expect_lines; do
        grep -qxF -- "$expect_line" "$expect_file" || { IFS=$expect_old_ifs; dump "$expect_tag"; fail "$expect_tag: expected '$expect_line' in ${expect_file##*/}"; }
    done
    IFS=$expect_old_ifs
}
# The host's view: the rootfs mount stays rw,nosuid,nodev and writable.
check_host_writable() {
    "$probe" "flags:$rootfs" > "$results/$1.host" || fail "$1: host probe failed"
    expect "$results/$1.host" "$1" "flags $rootfs rw nosuid nodev"
    printf 'probe\n' > "$rootfs/data/host-write" || fail "$1: the host can no longer write the rootfs"
    mkdir "$rootfs/data/host-dir" || fail "$1: the host can no longer create directories in the rootfs"
    rm -rf "$rootfs/data/host-write" "$rootfs/data/host-dir"
}

# observe RT TAG BUNDLE MODE: runs a probe bundle; TAG.stdout holds its record.
observe() {
    observe_rt=$1 observe_tag=$2 observe_name=$3 observe_mode=$4
    reset_rootfs
    case "$observe_mode" in
    foreground)
        step "$observe_tag" $observe_rt run --bundle "$bundles/$observe_name" "$observe_tag" < /dev/null > "$results/$observe_tag.stdout" 2> "$results/$observe_tag.stderr"
        ;;
    detached)
        step "$observe_tag" $observe_rt run --detach --bundle "$bundles/$observe_name" "$observe_tag" < /dev/null > "$results/$observe_tag.stdout" 2> "$results/$observe_tag.stderr"
        wait_status "$observe_rt" "$observe_tag" stopped
        step "$observe_tag" $observe_rt delete "$observe_tag"
        ;;
    created)
        step "$observe_tag" $observe_rt create --bundle "$bundles/$observe_name" "$observe_tag" < /dev/null > "$results/$observe_tag.stdout" 2> "$results/$observe_tag.stderr"
        observe_status=$(status_of "$observe_rt" "$observe_tag")
        [ "$observe_status" = created ] || { dump "$observe_tag"; fail "$observe_tag: status after create is '$observe_status'"; }
        observe_pid=$(pid_of "$observe_rt" "$observe_tag")
        # The waiting init already has its final root mount and its cwd,
        # while the host's mount of the same rootfs stays writable.
        awk '$5 == "/" { split($6, options, ","); print options[1] }' "/proc/$observe_pid/mountinfo" > "$results/$observe_tag.root" \
            || { dump "$observe_tag"; fail "$observe_tag: cannot read /proc/$observe_pid/mountinfo"; }
        case "$observe_name" in
        readonly-*) expect "$results/$observe_tag.root" "$observe_tag" ro ;;
        *) expect "$results/$observe_tag.root" "$observe_tag" rw ;;
        esac
        test -d "$rootfs/work/missing" || { dump "$observe_tag"; fail "$observe_tag: cwd not created before readiness"; }
        check_host_writable "$observe_tag-waiting"
        [ ! -s "$results/$observe_tag.stdout" ] || { dump "$observe_tag"; fail "$observe_tag: workload ran before start"; }
        step "$observe_tag" $observe_rt start "$observe_tag"
        wait_status "$observe_rt" "$observe_tag" stopped
        step "$observe_tag" $observe_rt delete "$observe_tag"
        ;;
    esac
    no_process_left "$observe_tag"
    test -s "$results/$observe_tag.stdout" || { dump "$observe_tag"; fail "$observe_tag: no probe record"; }
}

denied='write /data/existing EROFS|create /data/new EROFS|mkdir /data/newdir EROFS'
allowed='write /data/existing ok|create /data/new ok|mkdir /data/newdir ok'
child='flags /scratch rw nosuid nodev|create /scratch/new ok|mkdir /scratch/dir ok|write /scratch/new ok|cwd /work/missing'
shared_checks() {
    impl=$1 rt=$2
    for mode in foreground detached created; do
        for who in root user; do
            if [ "$who" = root ]; then id='id 0 0'; else id='id 1000 1000'; fi
            # Readonly: real writes to the root mount fail with EROFS, the
            # child mounts and the created cwd work, and the host is intact.
            tag=readonly-$who-$mode-$impl
            observe "$rt" "$tag" "readonly-$who" "$mode"
            expect "$results/$tag.stdout" "$tag" "$id|$denied|$child"
            [ "$who" = user ] || expect "$results/$tag.stdout" "$tag" "create /dev/probe ok|create cwd-file EROFS"
            cmp -s "$results/existing.original" "$rootfs/data/existing" || fail "$tag: the denied write changed the host file"
            ! test -e "$rootfs/data/new" && ! test -e "$rootfs/data/newdir" || fail "$tag: a denied create reached the host"
            test -d "$rootfs/work/missing" || fail "$tag: the missing cwd was not created"
            check_host_writable "$tag"

            # False and absent: the same writes succeed and reach the host.
            for kind in writable absent; do
                tag=$kind-$who-$mode-$impl
                observe "$rt" "$tag" "$kind-$who" "$mode"
                expect "$results/$tag.stdout" "$tag" "$id|flags / rw nosuid nodev|$allowed|$child"
                [ "$who" = user ] || expect "$results/$tag.stdout" "$tag" "create /dev/probe ok|create cwd-file ok"
                cmp -s "$results/existing.appended" "$rootfs/data/existing" \
                    || fail "$tag: the host file is not the original plus the written byte"
                test -f "$rootfs/data/new" && test -d "$rootfs/data/newdir" || fail "$tag: created entries missing on the host"
            done
        done
    done
    echo "$impl: readonly root EROFS, writable /dev and /scratch, cwd creation, and false/absent writes ok"
}

shared_checks swift "$ours"
# This runtime restates the rootfs mount's flags in the remount.
for record in "$results"/readonly-*-swift.stdout; do
    tag=${record##*/}
    expect "$record" "${tag%.stdout}" "flags / ro nosuid nodev"
done
if [ "$compare" = 1 ]; then
    shared_checks runc "$theirs"
    # runc's setReadonly first remounts with MS_RDONLY alone, which may drop
    # nosuid/nodev inherited from the host mount; that line is recorded, and
    # every other probe line must match.
    echo "runc readonly root flags: $(grep '^flags / ' "$results/readonly-root-foreground-runc.stdout")"
    for record in $(cd "$results" && ls -- *-swift.stdout); do
        theirs_record=$(echo "$record" | sed 's/-swift\./-runc./')
        grep -v '^flags / ' "$results/$record" > "$results/$record.compared"
        grep -v '^flags / ' "$results/$theirs_record" > "$results/$theirs_record.compared"
        if ! cmp -s "$results/$record.compared" "$results/$theirs_record.compared"; then
            diff "$results/$theirs_record.compared" "$results/$record.compared" >&2 || :
            fail "$record differs from runc (diff: runc -> swift)"
        fi
    done
fi

# expect_failure IMPL RT NAME MODE MESSAGE: setup fails without a hang,
# with MESSAGE (when given), leaving no state or process.
expect_failure() {
    failure_impl=$1 failure_rt=$2 failure_name=$3 failure_mode=$4 failure_message=$5
    failure_tag=$failure_name-$failure_mode-$failure_impl
    case "$failure_mode" in foreground) failure_command=run ;; created) failure_command=create ;; esac
    reset_rootfs
    if $failure_rt $failure_command --bundle "$bundles/$failure_name" "$failure_tag" < /dev/null > "$results/$failure_tag.stdout" 2> "$results/$failure_tag.stderr"; then
        dump "$failure_tag"
        fail "$failure_tag: $failure_command succeeded"
    else
        failure_status=$?
    fi
    not_timeout "$failure_tag" "$failure_command" "$failure_status"
    [ -z "$failure_message" ] || grep -qF -- "$failure_message" "$results/$failure_tag.stderr" || { dump "$failure_tag"; fail "$failure_tag: expected error '$failure_message'"; }
    if $failure_rt state "$failure_tag" > /dev/null 2>&1; then dump "$failure_tag"; fail "$failure_tag: failed $failure_command left state"; fi
    no_process_left "$failure_tag"
    check_host_writable "$failure_tag"
}
for mode in foreground created; do
    # A missing program fails after the remount, before readiness.
    expect_failure swift "$ours" readonly-missing "$mode" "exec workload"
    [ "$compare" = 1 ] && expect_failure runc "$theirs" readonly-missing "$mode" ""
    # A sysctl of a namespace the container does not own is rejected before any setup.
    expect_failure swift "$ours" readonly-sysctl "$mode" "linux.sysctl kernel.domainname is not allowed in the host's uts namespace"
done

test -z "$(ls -A "$state_root")" || { ls -A "$state_root" >&2; fail "state left behind"; }
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Readonly root integration checks passed (comparison: $comparison): EROFS for existing-file writes and new files/directories, writable /dev and /scratch child mounts, missing cwd created before the remount, false/absent writable, root and uid 1000, foreground/detached/create-start, host rootfs unchanged and writable with nosuid/nodev kept, setup failures leave nothing."
