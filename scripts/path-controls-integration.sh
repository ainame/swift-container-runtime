#!/bin/sh
# linux.readonlyPaths and linux.maskedPaths checks, compared with runc. A
# static probe (scripts/fixtures/path-probe.c) reports exact errno names,
# contents, file types, device numbers and inode identity from inside the
# workload: masked files read as the container's 1:3 /dev/null (same inode),
# masked directories are empty read-only tmpfs mounts sharing one inode,
# read-only paths and nested read-only paths fail writes with EROFS while
# keeping nosuid/nodev, a tmpfs below a read-only path stays writable, and
# unrelated paths stay writable unless root.readonly is set. Missing paths,
# paths below a masked directory, duplicates and symlinks that climb out of
# the rootfs are skipped, as runc skips them, and never reach the host. Runs
# as root and uid 1000 in foreground, detached and create/start modes, and
# checks the host's rootfs contents, writability and mount table after each
# run, the created init's mount table, and setup failures (also after part
# of the masks were applied) that must leave no state, process, or mount.
# Run as root inside a disposable Linux VM. Requires CC (default clang) able
# to link statically. RUNC_COMPARE=auto (default) runs the shared checks
# under runc when it is installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/swift-container-runtime}
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
    echo "path-controls-integration: $*" >&3
    exit 1
}

case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

# The rootfs lives on its own nosuid,nodev tmpfs, so a read-only remount that
# cleared inherited flags would show. host-target sits beside the rootfs,
# where a symlink resolved outside the container root would land.
mkdir -p "$fsroot" "$results"
mount -t tmpfs -o nosuid,nodev,mode=755 tmpfs "$fsroot" || fail "cannot mount the host tmpfs"
rootfs=$fsroot/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/scratch"
"$cc" -static -O2 -o "$rootfs/bin/path-probe" "$here/fixtures/path-probe.c" \
    || fail "cannot build the static probe with $cc"
if ldd "$rootfs/bin/path-probe" >/dev/null 2>&1; then fail "the probe is not statically linked"; fi
# Exact expected bytes for every host-side content check, compared with cmp
# (command substitution would drop trailing newlines).
expected=$results/expected
mkdir -p "$expected"
printf 'host\n' > "$expected/host-target"
cp "$expected/host-target" "$fsroot/host-target"
for file in secret inner keep rofile other; do printf '%s\n' "$file" > "$expected/$file"; done
printf 'other\nx' > "$expected/other.appended"
host_mounts() { grep -c -F -- "$fsroot" /proc/self/mountinfo || :; }
host_mount_count=$(host_mounts)

# Recreates /data before every run. Directories are world-writable and files
# world-writable, so a denied write is EROFS for uid 1000 too, not EACCES.
reset_rootfs() {
    rm -rf "$rootfs/data"
    mkdir -p "$rootfs/data/dir" "$rootfs/data/dir2" "$rootfs/data/dir3" "$rootfs/data/ro/child"
    for file in secret dir/inner dir2/inner dir3/inner ro/keep ro/child/keep rofile other; do
        cp "$expected/${file##*/}" "$rootfs/data/$file"
        chmod 0666 "$rootfs/data/$file"
    done
    chmod 1777 "$rootfs/data" "$rootfs/data/dir" "$rootfs/data/dir2" "$rootfs/data/dir3" "$rootfs/data/ro" "$rootfs/data/ro/child"
    ln -s /data/dir3 "$rootfs/data/abs-link"
    ln -s ../../../../host-target "$rootfs/data/escape"
    ln -s ../../host-target "$rootfs/data/ro-escape"
}
# The host's view after a run: exact original contents of every masked or
# read-only file, no denied entry, host-target unchanged and writable, the
# rootfs mount rw,nosuid,nodev, and no mount added on the host.
check_host_common() { # TAG
    for file in secret dir/inner dir2/inner dir3/inner ro/keep ro/child/keep rofile; do
        cmp -s "$expected/${file##*/}" "$rootfs/data/$file" || fail "$1: host /data/$file changed"
    done
    for entry in dir/new dir/newdir dir3/new ro/new ro/newdir ro/child/new; do
        ! test -e "$rootfs/data/$entry" || fail "$1: denied /data/$entry reached the host"
    done
    cmp -s "$expected/host-target" "$fsroot/host-target" || fail "$1: host-target changed"
    cp "$expected/host-target" "$fsroot/host-target" || fail "$1: host-target is no longer writable"
    "$rootfs/bin/path-probe" "flags:$rootfs" > "$results/$1.host" || fail "$1: host probe failed"
    grep -qxF "flags $rootfs rw nosuid nodev" "$results/$1.host" || fail "$1: host rootfs mount flags changed"
    test "$(host_mounts)" = "$host_mount_count" || { grep -F -- "$fsroot" /proc/self/mountinfo >&3; fail "$1: host mount table changed"; }
}
# check_host TAG WRITABLE_ROOT: also the one allowed byte appended to
# /data/other and /data/rw-new when the root is writable, neither otherwise.
check_host() {
    check_host_common "$1"
    if [ "$2" = yes ]; then
        cmp -s "$expected/other.appended" "$rootfs/data/other" && test -f "$rootfs/data/rw-new" || fail "$1: allowed writes missing on the host"
    else
        cmp -s "$expected/other" "$rootfs/data/other" && ! test -e "$rootfs/data/rw-new" || fail "$1: denied writes reached the host"
    fi
}

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
  {"destination": "/scratch", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "nodev", "mode=1777", "size=1024k"]},
  {"destination": "/data/ro/mnt", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "nodev", "mode=1777", "size=1024k"]}
]'
# Duplicates, a nested read-only path, missing paths, a path below a masked
# directory, an in-root absolute symlink and two climbing symlinks.
readonly_paths='"/data/ro", "/data/rofile", "/data/missing", "/data/ro", "/data/ro/child", "/data/ro-escape"'
masked_paths='"/data/secret", "/data/dir", "/data/dir2", "/data/missing/x", "/data/secret", "/data/abs-link",
  "/data/escape", "/data/dir/inner", "/proc/version", "/proc/kcore"'
operations='"/bin/path-probe", "id",
  "read:/data/secret", "write:/data/secret", "stat:/data/secret", "same:/data/secret,/dev/null",
  "stat:/data/dir", "list:/data/dir", "read:/data/dir/inner", "create:/data/dir/new", "mkdir:/data/dir/newdir", "flags:/data/dir",
  "list:/data/dir2", "same:/data/dir,/data/dir2", "same:/data/dir,/data/dir3", "list:/data/dir3", "create:/data/dir3/new",
  "read:/data/ro/keep", "write:/data/ro/keep", "create:/data/ro/new", "mkdir:/data/ro/newdir",
  "write:/data/ro/child/keep", "create:/data/ro/child/new", "write:/data/rofile", "read:/data/rofile",
  "flags:/data/ro", "flags:/data/ro/child", "flags:/data/ro/mnt", "create:/data/ro/mnt/new", "write:/data/ro/mnt/new",
  "read:/host-target", "stat:/data/escape", "stat:/data/ro-escape", "read:/proc/version", "stat:/proc/version",
  "same:/proc/version,/dev/null", "stat:/proc/kcore",
  "write:/data/other", "create:/data/rw-new", "create:/scratch/new"'
bundles=$scratch/bundles
# write_config NAME ROOT_EXTRA USER LINUX_EXTRA [MOUNTS] [ARGS]
write_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"$2},
  "process": {"terminal": false, "user": $3, "args": [${6:-$operations}], "env": ["PATH=/bin"], "cwd": "/"},
  "mounts": ${5:-$mounts},
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}]$4}
}
EOF
}
controls=", \"readonlyPaths\": [$readonly_paths], \"maskedPaths\": [$masked_paths]"
for who in root user; do
    if [ "$who" = root ]; then user='{"uid": 0, "gid": 0}'; else user='{"uid": 1000, "gid": 1000}'; fi
    write_config "controls-$who" '' "$user" "$controls"
    write_config "controls-ro-$who" ', "readonly": true' "$user" "$controls"
done
# readonlyPaths ["/"] next to root.readonly with the same probe: runc binds
# "/" onto itself and remounts whatever "/" then reaches.
root_operations='"/bin/path-probe", "id", "flags:/", "write:/data/other", "create:/data/rw-new", "mkdir:/data/rw-dir",
  "read:/data/ro/keep", "flags:/scratch", "create:/scratch/new", "flags:/data/ro/mnt", "create:/data/ro/mnt/new"'
# Without a /proc mount: real read-only and masked files and directories.
no_proc_mounts='[
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
  {"destination": "/scratch", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "nodev", "mode=1777", "size=1024k"]},
  {"destination": "/data/ro/mnt", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "nodev", "mode=1777", "size=1024k"]}
]'
no_proc_operations='"/bin/path-probe", "id", "read:/data/secret", "stat:/data/secret", "same:/data/secret,/dev/null",
  "list:/data/dir", "create:/data/dir/new", "same:/data/dir,/data/dir2", "write:/data/ro/keep", "write:/data/rofile",
  "flags:/data/ro", "create:/data/ro/mnt/new", "write:/data/other", "create:/data/rw-new", "stat:/proc/self"'
no_proc_controls=', "readonlyPaths": ["/data/ro", "/data/rofile", "/data/ro"], "maskedPaths": ["/data/secret", "/data/dir", "/data/dir2"]'
no_proc_with_proc_mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},'${no_proc_mounts#\[}
no_proc_readonly_operations='"/bin/path-probe", "id", "read:/data/ro/keep", "write:/data/ro/keep", "create:/data/ro/new",
  "write:/data/rofile", "flags:/data/ro", "create:/data/ro/mnt/new", "write:/data/other", "create:/data/rw-new", "stat:/proc/self"'
# Every path missing: nothing is mounted, but masks still need a valid /dev/null.
missing_operations='"/bin/path-probe", "id", "read:/data/secret", "write:/data/other", "create:/data/rw-new", "stat:/data/missing"'
missing_controls=', "readonlyPaths": ["/data/missing", "/data/missing/x", "/data/none"], "maskedPaths": ["/data/missing", "/data/none/x"]'
for who in root user; do
    if [ "$who" = root ]; then user='{"uid": 0, "gid": 0}'; else user='{"uid": 1000, "gid": 1000}'; fi
    write_config "rootpath-$who" '' "$user" ', "readonlyPaths": ["/"]' '' "$root_operations"
    write_config "rootflag-$who" ', "readonly": true' "$user" '' '' "$root_operations"
    write_config "noproc-$who" '' "$user" "$no_proc_controls" "$no_proc_mounts" "$no_proc_operations"
    # runc's maskPaths mounts through /proc/thread-self/fd, so its twin of
    # noproc adds only a /proc mount; stat:/proc/self is the one line it changes.
    write_config "noproc-withproc-$who" '' "$user" "$no_proc_controls" "$no_proc_with_proc_mounts" "$no_proc_operations"
    # Read-only paths alone use plain path mounts in runc and need no /proc.
    write_config "noproc-readonly-$who" '' "$user" ', "readonlyPaths": ["/data/ro", "/data/rofile", "/data/ro"]' \
        "$no_proc_mounts" "$no_proc_readonly_operations"
    write_config "missing-$who" '' "$user" "$missing_controls" '' "$missing_operations"
    write_config "missing-noproc-$who" '' "$user" "$missing_controls" "$no_proc_mounts" "$missing_operations"
done
root_user='{"uid": 0, "gid": 0}'
# Failures shared with runc: a non-directory component after part of the
# masks (or read-only paths) were already applied.
# Expected failures and investigations run only a read-only probe, so a
# runtime that unexpectedly runs the workload (as the installed runc does
# for a hidden mask on "/") cannot change the files check_host compares.
inspect_operations='"/bin/path-probe", "id", "stat:/data/secret", "read:/data/secret"'
write_config fail-mask-notdir '' "$root_user" ', "maskedPaths": ["/data/dir", "/data/secret", "/data/secret/x"]' '' "$inspect_operations"
write_config fail-readonly-notdir '' "$root_user" ', "readonlyPaths": ["/data/ro", "/data/secret/x"]' '' "$inspect_operations"
# Failures of this runtime only: a magic link (runc follows it), a /dev/null
# that is not the 1:3 device (runc creates its own default devices), and
# configurations rejected before setup.
write_config fail-magic '' "$root_user" ', "maskedPaths": ["/data/secret", "/dev/stdout"]' '' "$inspect_operations"
no_dev_mounts='[{"destination": "/proc", "type": "proc", "source": "proc"}]'
write_config fail-devnull '' "$root_user" ', "maskedPaths": ["/data/missing"]' "$no_dev_mounts" "$inspect_operations"
write_config fail-magic-readonly '' "$root_user" ', "readonlyPaths": ["/dev/stdout"]' '' "$inspect_operations"
# A mask on "/": runc mounts it; whether the workload can see it is the
# kernel's lookup decision. Its outcome under runc is recorded, and this
# runtime must fail rather than report an invisible mask as applied.
write_config mask-root '' "$root_user" ', "maskedPaths": ["/"]' '' "$inspect_operations"
write_config fail-dotdot '' "$root_user" ', "readonlyPaths": ["/data/../etc"]' '' "$inspect_operations"
write_config fail-unknown '' "$root_user" ', "maskPaths": ["/data/secret"]' '' "$inspect_operations"

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

# A waiting created init already has every control in place: each applied
# path is a mount point in its namespace, and nothing names host-target.
# /proc/version always exists; /proc/kcore only with CONFIG_PROC_KCORE. The
# container's fresh procfs belongs to the same kernel as the host's /proc,
# so the host decides which outcome is expected, and an existing kcore must
# really be masked.
test -f /proc/version || fail "the host has no /proc/version"
applied_mounts='/data/ro|/data/rofile|/data/ro/child|/data/ro/mnt|/data/secret|/data/dir|/data/dir2|/data/dir3|/proc/version'
if [ -e /proc/kcore ]; then
    applied_mounts="$applied_mounts|/proc/kcore"
    kcore_absent=
    kcore_line='stat /proc/kcore chr 1:3'
else
    kcore_absent=/proc/kcore
    kcore_line='stat /proc/kcore ENOENT'
fi
echo "host /proc/kcore: $kcore_line"
check_created_mounts() { # TAG PID BUNDLE
    awk '{ print $5 }' "/proc/$2/mountinfo" > "$results/$1.mounts" || fail "$1: cannot read /proc/$2/mountinfo"
    # How often each relevant mount point is stacked, as "PATH COUNT" lines.
    grep -E '^(/|/data.*|/proc/version|/proc/kcore|/scratch)$' "$results/$1.mounts" | sort | uniq -c \
        | awk '{ print $2, $1 }' > "$results/$1.mountcounts" || :
    case "$3" in controls-*) ;; *) return 0 ;; esac
    expect "$results/$1.mounts" "$1" "$applied_mounts"
    # The reference maskPaths applies the repeated /data/secret once; each
    # /data/ro bind is recursive, so the second also copies the first's
    # /data/ro/mnt (the configured tmpfs, then two copies). This runtime must
    # match these source-derived counts exactly, whatever runc is installed.
    case "$1" in
    *-swift)
        printf '%s\n' '/ 1' '/data/dir 1' '/data/dir2 1' '/data/dir3 1' '/data/ro 2' '/data/ro/child 1' '/data/ro/mnt 3' \
            '/data/rofile 1' '/data/secret 1' '/proc/version 1' '/scratch 1' > "$results/$1.mountcounts.expected"
        [ -n "$kcore_absent" ] || echo '/proc/kcore 1' >> "$results/$1.mountcounts.expected"
        sort -o "$results/$1.mountcounts.expected" "$results/$1.mountcounts.expected"
        cmp -s "$results/$1.mountcounts.expected" "$results/$1.mountcounts" || {
            diff "$results/$1.mountcounts.expected" "$results/$1.mountcounts" >&3 || :
            fail "$1: mount counts differ from the reference (diff: expected -> actual)"
        }
        ;;
    esac
    ! grep -q host-target "/proc/$2/mountinfo" || fail "$1: a mount reached host-target"
    for absent in /data/missing /data/missing/x /data/dir/inner /data/escape /data/ro-escape $kcore_absent; do
        ! grep -qxF -- "$absent" "$results/$1.mounts" || fail "$1: skipped path $absent was mounted"
    done
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
        check_created_mounts "$observe_tag" "$(pid_of "$observe_rt" "$observe_tag")" "$observe_name"
        test "$(host_mounts)" = "$host_mount_count" || fail "$observe_tag: the created init's mounts reached the host"
        [ ! -s "$results/$observe_tag.stdout" ] || { dump "$observe_tag"; fail "$observe_tag: workload ran before start"; }
        step "$observe_tag" $observe_rt start "$observe_tag"
        wait_status "$observe_rt" "$observe_tag" stopped
        step "$observe_tag" $observe_rt delete "$observe_tag"
        ;;
    esac
    no_process_left "$observe_tag"
    test -s "$results/$observe_tag.stdout" || { dump "$observe_tag"; fail "$observe_tag: no probe record"; }
}

masked='read /data/secret ok 0:|write /data/secret ok|stat /data/secret chr 1:3|same /data/secret /dev/null yes'
masked_dirs='stat /data/dir dir|list /data/dir 0|read /data/dir/inner ENOENT|create /data/dir/new EROFS|mkdir /data/dir/newdir EROFS|flags /data/dir ro'
masked_dirs="$masked_dirs|list /data/dir2 0|list /data/dir3 0|create /data/dir3/new EROFS"
# The checked-out runc reference's maskPaths binds the first directory mask
# onto the others, so they share one tmpfs inode. The installed runc package
# (observed: 1.4.0-0ubuntu1) mounts one tmpfs each; its result is logged.
shared_mask='same /data/dir /data/dir2 yes|same /data/dir /data/dir3 yes'
readonly_lines='read /data/ro/keep ok 5:keep\n|write /data/ro/keep EROFS|create /data/ro/new EROFS|mkdir /data/ro/newdir EROFS'
readonly_lines="$readonly_lines|write /data/ro/child/keep EROFS|create /data/ro/child/new EROFS|write /data/rofile EROFS|read /data/rofile ok 7:rofile\\n"
readonly_lines="$readonly_lines|flags /data/ro/mnt rw nosuid nodev|create /data/ro/mnt/new ok|write /data/ro/mnt/new ok"
skipped='read /host-target ENOENT|stat /data/escape ENOENT|stat /data/ro-escape ENOENT|create /scratch/new ok'
skipped="$skipped|read /proc/version ok 0:|stat /proc/version chr 1:3|same /proc/version /dev/null yes|$kcore_line"
shared_checks() {
    impl=$1 rt=$2
    for mode in foreground detached created; do
        for who in root user; do
            if [ "$who" = root ]; then id='id 0 0'; else id='id 1000 1000'; fi
            for kind in controls controls-ro; do
                tag=$kind-$who-$mode-$impl
                observe "$rt" "$tag" "$kind-$who" "$mode"
                expect "$results/$tag.stdout" "$tag" "$id|$masked|$masked_dirs|$readonly_lines|$skipped"
                if [ "$kind" = controls ]; then
                    expect "$results/$tag.stdout" "$tag" "write /data/other ok|create /data/rw-new ok"
                    check_host "$tag" yes
                else
                    expect "$results/$tag.stdout" "$tag" "write /data/other EROFS|create /data/rw-new EROFS"
                    check_host "$tag" no
                fi
            done
        done
    done
    for mode in foreground detached created; do
        for who in root user; do
            if [ "$who" = root ]; then id='id 0 0'; else id='id 1000 1000'; fi
            # readonlyPaths ["/"] and root.readonly: child mounts stay writable
            # in both; the root's own result is compared with runc below.
            for kind in rootpath rootflag; do
                tag=$kind-$who-$mode-$impl
                observe "$rt" "$tag" "$kind-$who" "$mode"
                expect "$results/$tag.stdout" "$tag" "$id|read /data/ro/keep ok 5:keep\n|create /scratch/new ok|create /data/ro/mnt/new ok|flags /scratch rw nosuid nodev|flags /data/ro/mnt rw nosuid nodev"
                check_host_common "$tag"
            done
            expect "$results/rootflag-$who-$mode-$impl.stdout" "rootflag-$who-$mode-$impl" "write /data/other EROFS|create /data/rw-new EROFS|mkdir /data/rw-dir EROFS"
            # All paths missing: nothing is masked or read-only, with or without /proc.
            for kind in missing missing-noproc; do
                tag=$kind-$who-$mode-$impl
                observe "$rt" "$tag" "$kind-$who" "$mode"
                expect "$results/$tag.stdout" "$tag" "$id|read /data/secret ok 7:secret\n|write /data/other ok|create /data/rw-new ok|stat /data/missing ENOENT"
                check_host "$tag" yes
            done
            # Read-only paths alone without /proc: strictly the same under runc.
            tag=noproc-readonly-$who-$mode-$impl
            observe "$rt" "$tag" "noproc-readonly-$who" "$mode"
            expect "$results/$tag.stdout" "$tag" "$id|read /data/ro/keep ok 5:keep\n|write /data/ro/keep EROFS|create /data/ro/new EROFS|write /data/rofile EROFS"
            expect "$results/$tag.stdout" "$tag" "flags /data/ro ro nosuid nodev|create /data/ro/mnt/new ok|write /data/other ok|create /data/rw-new ok|stat /proc/self ENOENT"
            check_host "$tag" yes
            # Without /proc, files and directories are still really masked by
            # this runtime. runc runs the same controls with /proc added (its
            # own /proc-less run is checked by runc_noproc_masks).
            if [ "$impl" = runc ]; then name=noproc-withproc proc_line='stat /proc/self dir'; else name=noproc proc_line='stat /proc/self ENOENT'; fi
            tag=$name-$who-$mode-$impl
            observe "$rt" "$tag" "$name-$who" "$mode"
            expect "$results/$tag.stdout" "$tag" "$id|read /data/secret ok 0:|stat /data/secret chr 1:3|same /data/secret /dev/null yes|list /data/dir 0|create /data/dir/new EROFS"
            expect "$results/$tag.stdout" "$tag" "write /data/ro/keep EROFS|write /data/rofile EROFS|flags /data/ro ro nosuid nodev|create /data/ro/mnt/new ok|write /data/other ok|create /data/rw-new ok|$proc_line"
            check_host "$tag" yes
        done
    done
    echo "$impl: masked files and shared directory masks, read-only, nested and repeated paths, readonlyPaths [/], no /proc, all-missing paths, writable child mounts, skipped paths, and host isolation ok"
}


# runc_noproc_masks WHO MODE: runc's maskPaths mounts each target through
# /proc/thread-self/fd/N, so without a /proc mount the installed runc fails on
# the first existing mask, /data/secret, with that exact ENOENT shape (the
# descriptor number varies). Readonly paths before it are applied and
# discarded with the namespace. Any other failure fails this script, and a
# runc that succeeds must produce exactly this runtime's record.
runc_noproc_masks() {
    nm_tag=noproc-$1-$2-runc
    case "$2" in foreground) nm_command=run ;; created) nm_command=create ;; esac
    reset_rootfs
    if $theirs $nm_command --bundle "$bundles/noproc-$1" "$nm_tag" < /dev/null > "$results/$nm_tag.stdout" 2> "$results/$nm_tag.stderr"; then
        if [ "$2" = created ]; then
            step "$nm_tag" $theirs start "$nm_tag"
            wait_status "$theirs" "$nm_tag" stopped
            step "$nm_tag" $theirs delete "$nm_tag"
        fi
        no_process_left "$nm_tag"
        if ! cmp -s "$results/noproc-$1-$2-swift.stdout" "$results/$nm_tag.stdout"; then
            diff "$results/$nm_tag.stdout" "$results/noproc-$1-$2-swift.stdout" >&2 || :
            fail "$nm_tag: runc now masks without /proc but differs (diff: runc -> swift)"
        fi
        check_host "$nm_tag" yes
        echo "runc ($runc_version) masks without /proc ($1, $2): supported and identical"
        return 0
    else
        nm_status=$?
    fi
    not_timeout "$nm_tag" "runc $nm_command" "$nm_status"
    # runc's text log may escape the quotes around the target ("\"), so the
    # brackets accept only quote and backslash characters there.
    nm_error='can'"'"'t mask path [\"]*/data/secret[\"]*: mount dst=/data/secret, dstFd=/proc/thread-self/fd/[0-9][0-9]*, flags=MS_BIND: no such file or directory'
    grep -q -- "$nm_error" "$results/$nm_tag.stderr" || { dump "$nm_tag"; fail "$nm_tag: unexpected runc failure (status $nm_status)"; }
    if $theirs state "$nm_tag" > /dev/null 2>&1; then dump "$nm_tag"; fail "$nm_tag: failed $nm_command left state"; fi
    [ ! -s "$results/$nm_tag.stdout" ] || { dump "$nm_tag"; fail "$nm_tag: the workload ran"; }
    no_process_left "$nm_tag"
    check_host "$nm_tag" no
    echo "runc ($runc_version) without /proc ($1, $2): expected mask failure on /data/secret (status $nm_status)"
}

shared_checks swift "$ours"
# This runtime keeps the rootfs mount's flags on every read-only remount,
# and shares one directory mask as the runc reference does.
for record in "$results"/controls-*-swift.stdout; do
    tag=${record##*/}
    expect "$record" "${tag%.stdout}" "flags /data/ro ro nosuid nodev|flags /data/ro/child ro nosuid nodev|$shared_mask"
done
if [ "$compare" = 1 ]; then
    runc_version=$(runc --version | head -n 1)
    shared_checks runc "$theirs"
    for who in root user; do
        for mode in foreground created; do runc_noproc_masks "$who" "$mode"; done
    done
    # runc's readonlyPath keeps the flags statfs reports, but with
    # root.readonly its setReadonly may first drop nosuid/nodev from "/", which
    # the read-only path binds then inherit. Those lines are recorded; every
    # other probe line must match byte for byte.
    echo "runc read-only path flags under root.readonly: $(grep '^flags /data/ro ' "$results/controls-ro-root-foreground-runc.stdout")"
    echo "runc directory mask sharing ($runc_version): $(grep '^same /data/dir ' "$results/controls-root-foreground-runc.stdout" | tr '\n' ' ')"
    # The reference deduplicates repeated masked paths; the installed runc
    # may mount /data/secret again. Detect that from runc's own counts, log
    # them, and exclude only that line; a count other than 1 or 2 still fails.
    echo "runc masked mount counts ($runc_version): $(grep -E '^(/data/secret|/data/dir[23]?|/proc/version|/proc/kcore) ' "$results/controls-root-created-runc.mountcounts" | tr '\n' ' ')"
    for record in $(cd "$results" && ls -- *-swift.stdout *-swift.mountcounts); do
        theirs_record=$(echo "$record" | sed 's/-swift\./-runc./')
        # noproc is compared with runc's /proc-mounted twin, except /proc's own visibility.
        case "$record" in noproc-root-* | noproc-user-*) theirs_record=$(echo "$theirs_record" | sed 's/^noproc-/noproc-withproc-/') ;; esac
        test -e "$results/$theirs_record" || fail "$record has no runc record"
        case "$record" in
        controls-*.mountcounts)
            if grep -qx '/data/secret 2' "$results/$theirs_record"; then filter='^/data/secret ' ; else filter='^$'; fi ;;
        *.mountcounts) filter='^$' ;;
        noproc-root-*.stdout | noproc-user-*.stdout) filter='^stat /proc/self \|^same /data/dir ' ;;
        controls-ro-*) filter='^flags /data/ro\(/child\)\{0,1\} \|^same /data/dir ' ;;
        # runc's setReadonly may drop nosuid/nodev from "/" (see readonly-integration.sh).
        rootflag-*) filter='^flags / ' ;;
        *) filter='^same /data/dir ' ;;
        esac
        grep -v -- "$filter" "$results/$record" > "$results/$record.compared"
        grep -v -- "$filter" "$results/$theirs_record" > "$results/$theirs_record.compared"
        if ! cmp -s "$results/$record.compared" "$results/$theirs_record.compared"; then
            diff "$results/$theirs_record.compared" "$results/$record.compared" >&2 || :
            fail "$record differs from runc (diff: runc -> swift)"
        fi
    done
fi
for who in root user; do
    for mode in foreground detached created; do
        if cmp -s "$results/rootpath-$who-$mode-swift.stdout" "$results/rootflag-$who-$mode-swift.stdout"; then same=yes; else same=no; fi
        echo "readonlyPaths [/] matches root.readonly ($who, $mode): $same"
    done
done

# expect_failure IMPL RT NAME MODE MESSAGE: setup fails without a hang,
# with MESSAGE (when given), leaving no state, process, mount, or host change.
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
    [ ! -s "$results/$failure_tag.stdout" ] || { dump "$failure_tag"; fail "$failure_tag: the workload ran"; }
    no_process_left "$failure_tag"
    # Nothing ran, so /data/other and /data/rw-new are untouched.
    check_host "$failure_tag" no
}
for mode in foreground created; do
    expect_failure swift "$ours" fail-mask-notdir "$mode" "resolve linux.maskedPaths entry in the container (symlinks stay within the root; magic links are refused) /data/secret/x: Not a directory (errno 20)"
    expect_failure swift "$ours" fail-readonly-notdir "$mode" "resolve linux.readonlyPaths entry in the container (symlinks stay within the root; magic links are refused) /data/secret/x: Not a directory (errno 20)"
    if [ "$compare" = 1 ]; then
        expect_failure runc "$theirs" fail-mask-notdir "$mode" ""
        expect_failure runc "$theirs" fail-readonly-notdir "$mode" ""
    fi
    expect_failure swift "$ours" fail-magic "$mode" "/dev/stdout: Too many levels of symbolic links (errno 40)"
    printf 'not a device\n' > "$expected/not-a-device"
    cp "$expected/not-a-device" "$rootfs/dev/null"
    expect_failure swift "$ours" fail-devnull "$mode" "open the container's /dev/null for linux.maskedPaths (it must be the 1:3 character device): No such device (errno 19)"
    cmp -s "$expected/not-a-device" "$rootfs/dev/null" || fail "fail-devnull-$mode: the rootfs /dev/null changed"
    rm -f "$rootfs/dev/null"
    expect_failure swift "$ours" fail-devnull "$mode" "open the container's /dev/null for linux.maskedPaths (it must be the 1:3 character device): No such file or directory (errno 2)"
    expect_failure swift "$ours" fail-magic-readonly "$mode" "/dev/stdout: Too many levels of symbolic links (errno 40)"
    # A mask on "/" either stays hidden beneath the container root (the
    # verification fails) or covers the workload (the program is missing).
    expect_failure swift "$ours" mask-root "$mode" ""
    grep -qF -e "verify linux.maskedPaths entry shows its mask" -e "exec workload: No such file or directory" \
        "$results/mask-root-$mode-swift.stderr" || { dump "mask-root-$mode-swift"; fail "mask-root-$mode-swift: unexpected error"; }
    if [ "$compare" = 1 ] && [ "$mode" = foreground ]; then
        reset_rootfs
        if $theirs run --bundle "$bundles/mask-root" "mask-root-$mode-runc" < /dev/null > "$results/mask-root-$mode-runc.stdout" 2> "$results/mask-root-$mode-runc.stderr"; then
            mask_root_status=0
        else
            mask_root_status=$?
        fi
        not_timeout "mask-root-$mode-runc" "runc run" "$mask_root_status"
        $theirs delete --force "mask-root-$mode-runc" > /dev/null 2>&1 || :
        no_process_left "mask-root-$mode-runc"
        check_host_common "mask-root-$mode-runc"
        echo "runc maskedPaths [/]: status $mask_root_status: $(tail -n 1 "$results/mask-root-$mode-runc.stderr")"
    fi
    expect_failure swift "$ours" fail-dotdot "$mode" "linux.readonlyPaths[0] must not contain . or .."
    expect_failure swift "$ours" fail-unknown "$mode" "unsupported field(s): linux.maskPaths"
done

test -z "$(ls -A "$state_root")" || { ls -A "$state_root" >&2; fail "state left behind"; }
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Path control integration checks passed (comparison: $comparison): files masked by the verified 1:3 /dev/null, directories by one shared read-only empty tmpfs, EROFS for read-only, nested and repeated read-only paths with nosuid/nodev kept, readonlyPaths [/] compared with runc, no /proc mount, writable child tmpfs and unrelated paths, root.readonly combined, missing/duplicate/below-mask/climbing-symlink paths skipped, magic links, invisible masks and invalid /dev/null refused, root and uid 1000, foreground/detached/create-start, host contents and mount table unchanged, setup failures leave nothing."
