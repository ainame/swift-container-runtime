#!/bin/sh
# process.rlimits checks, compared with runc: the limits a created init holds
# when create returns (/proc/PID/limits) and the workload's own getrlimit
# values, for an absent list and for configured root and non-root lists with
# hard limits, infinity, and repeated types, in foreground run, detached run,
# and create/start; real RLIMIT_NOFILE, RLIMIT_FSIZE, and RLIMIT_CPU
# enforcement; in-order application where an earlier entry fails; invalid and
# ungrantable limits leaving no state or process; and tiny RLIMIT_NOFILE and
# RLIMIT_AS outcomes. The probe is scripts/fixtures/rlimit-probe.c, linked
# statically into a static BusyBox rootfs.
# Run as root inside a disposable Linux VM. Requires CC (default clang) able
# to link statically, util-linux prlimit and setpriv, and BusyBox (BUSYBOX).
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/srunc}
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
ours="timeout -k 2 60 $runtime --root $state_root"
theirs="timeout -k 2 60 runc --root $runc_root"

cleanup() {
    for id in $($ours list -q 2>/dev/null); do $ours delete --force "$id" >/dev/null 2>&1 || :; done
    if [ "$compare" = 1 ]; then
        for id in $($theirs list -q 2>/dev/null); do $theirs delete --force "$id" >/dev/null 2>&1 || :; done
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
    echo "rlimits-integration: $*" >&2
    exit 1
}

if ldd "$busybox" >/dev/null 2>&1; then fail "BusyBox at $busybox must be statically linked"; fi
command -v prlimit >/dev/null || fail "prlimit (util-linux) is required"
command -v setpriv >/dev/null || fail "setpriv (util-linux) is required"
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac
nr_open=$(cat /proc/sys/fs/nr_open)

# Rootfs: static BusyBox plus the static probe. /out is world-writable.
rootfs=$scratch/rootfs
out=$rootfs/out
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$out" "$results"
chmod 1777 "$out"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
"$cc" -static -O2 -o "$rootfs/bin/rlimit-probe" "$here/fixtures/rlimit-probe.c" \
    || fail "cannot build the static probe with $cc"
if ldd "$rootfs/bin/rlimit-probe" >/dev/null 2>&1; then fail "the probe is not statically linked"; fi

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}
]'
bundles=$scratch/bundles
# write_config NAME USER_JSON RLIMITS_FIELD ARGS_JSON
# RLIMITS_FIELD is empty or ', "rlimits": [...]'.
write_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": $2$3, "args": $4, "env": ["PATH=/bin"], "cwd": "/"},
  "hostname": "rlimitbox",
  "mounts": $mounts,
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}
}
EOF
}
infinity=18446744073709551615
root='{"uid": 0, "gid": 0}'
user='{"uid": 1000, "gid": 1000}'
limits='["/bin/rlimit-probe", "limits"]'
# A repeated RLIMIT_NOFILE (lowered, then raised above the caller's hard
# 512, which needs CAP_SYS_RESOURCE), raised hard limits to infinity from
# the caller's RLIMIT_CORE 0:0 and RLIMIT_MEMLOCK 65536:65536, and
# RLIMIT_NPROC, which the kernel checks at the later setuid.
configured=', "rlimits": [
  {"type": "RLIMIT_NOFILE", "soft": 16, "hard": 16},
  {"type": "RLIMIT_NOFILE", "soft": 32, "hard": 1024},
  {"type": "RLIMIT_FSIZE", "soft": 4096, "hard": 8192},
  {"type": "RLIMIT_CORE", "soft": 0, "hard": '$infinity'},
  {"type": "RLIMIT_MEMLOCK", "soft": '$infinity', "hard": '$infinity'},
  {"type": "RLIMIT_NPROC", "soft": 1024, "hard": 2048},
  {"type": "RLIMIT_CPU", "soft": 600, "hard": 900}]'
configured_lines="RLIMIT_NOFILE 32 1024|RLIMIT_FSIZE 4096 8192|RLIMIT_CORE 0 unlimited|RLIMIT_MEMLOCK unlimited unlimited|RLIMIT_NPROC 1024 2048|RLIMIT_CPU 600 900"
configured_proc="Max open files 32 1024 files|Max file size 4096 8192 bytes|Max core file size 0 unlimited bytes|Max locked memory unlimited unlimited bytes|Max processes 1024 2048 processes|Max cpu time 600 900 seconds"
write_config absent-root "$root" "" "$limits"
write_config absent-user "$user" "" "$limits"
write_config configured-root "$root" "$configured" "$limits"
write_config configured-user "$user" "$configured" "$limits"
write_config nofile "$user" ', "rlimits": [{"type": "RLIMIT_NOFILE", "soft": 16, "hard": 16}]' '["/bin/rlimit-probe", "nofile"]'
write_config fsize "$user" ', "rlimits": [{"type": "RLIMIT_FSIZE", "soft": 4096, "hard": 8192}]' \
    '["/bin/rlimit-probe", "fsize", "/out/fsize.data", "10000"]'
write_config cpu "$user" ', "rlimits": [{"type": "RLIMIT_CPU", "soft": 1, "hard": 4}]' '["/bin/rlimit-probe", "cpu", "20"]'
# Failures. Each must fail setup under both runtimes and leave nothing.
write_config dup-infinity "$root" ', "rlimits": [{"type": "RLIMIT_NOFILE", "soft": '$infinity', "hard": '$infinity'},
  {"type": "RLIMIT_NOFILE", "soft": 32, "hard": 64}]' "$limits"
write_config dup-raise "$root" ', "rlimits": [{"type": "RLIMIT_NOFILE", "soft": 16, "hard": 16},
  {"type": "RLIMIT_NOFILE", "soft": 32, "hard": 64}]' "$limits"
write_config single-raise "$root" ', "rlimits": [{"type": "RLIMIT_NOFILE", "soft": 32, "hard": 64}]' "$limits"
write_config above-nr-open "$root" ', "rlimits": [{"type": "RLIMIT_NOFILE", "soft": 32, "hard": '$((nr_open + 1))'}]' "$limits"
write_config soft-above-hard "$root" ', "rlimits": [{"type": "RLIMIT_FSIZE", "soft": 2, "hard": 1}]' "$limits"
write_config unknown-type "$root" ', "rlimits": [{"type": "RLIMIT_NOPE", "soft": 1, "hard": 1}]' "$limits"
# Runtime-sensitive: limits so low that the runtime's own remaining setup
# or start handshake may need more. Outcomes are recorded for both.
write_config tiny-nofile "$user" ', "rlimits": [{"type": "RLIMIT_NOFILE", "soft": 3, "hard": 3}]' '["/bin/rlimit-probe", "nofile"]'
write_config tiny-as "$user" ', "rlimits": [{"type": "RLIMIT_AS", "soft": 1073741824, "hard": 1073741824}]' \
    '["/bin/rlimit-probe", "as", "1536", "1"]'
write_config unlimited-as "$user" "" '["/bin/rlimit-probe", "as", "1536", "1"]'
write_config tiny-nofile-loop "$user" ', "rlimits": [{"type": "RLIMIT_NOFILE", "soft": 3, "hard": 3}]' '["/bin/sleep", "1000"]'

field() { sed -n "s/^ *\"$1\" *: *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p"; }
status_of() { $1 state "$2" 2>/dev/null | field status; }
pid_of() { $1 state "$2" | field pid; }
alive() {
    stat_line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    state=${stat_line##*) }
    case "${state%% *}" in Z | X | x | '') return 1 ;; esac
}
wait_until() { # DESCRIPTION COMMAND...: polls for up to 30 seconds.
    description=$1
    shift
    deadline=$(($(date +%s) + 30))
    until "$@"; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for $description"
        sleep 0.05
    done
}
has_status() { test "$(status_of "$1" "$2")" = "$3"; }
wait_status() { wait_until "$2 to become $3" has_status "$1" "$2" "$3"; }
not_alive() { ! alive "$1"; }
wait_dead() { wait_until "process $1 to exit" not_alive "$1"; }
proc_limits() { awk 'NR > 1 { $1 = $1; print }' "/proc/$1/limits"; }

# The caller's limits are fixed, so inherited values are known and the
# configured hard limits are raises: NOFILE 256:512, CORE 0:0, MEMLOCK
# 65536:65536, the rest unlimited where the kernel allows it.
as_caller() {
    prlimit --nofile=256:512 --core=0:0 --memlock=65536:65536 --fsize=unlimited:unlimited \
        --cpu=unlimited:unlimited --as=unlimited:unlimited "$@"
}
# Root without CAP_SYS_RESOURCE in any set, so no hard limit can be raised.
without_sys_resource() {
    as_caller setpriv --bounding-set -sys_resource --inh-caps -sys_resource --ambient-caps -sys_resource "$@"
}
as_caller "$rootfs/bin/rlimit-probe" limits > "$results/caller.limits" || fail "probe failed on the host"
without_sys_resource sh -c 'grep CapEff /proc/self/status' > "$results/no-sys-resource.caps" \
    || fail "cannot launch a caller without CAP_SYS_RESOURCE"
mask=$(awk '{ print $2 }' "$results/no-sys-resource.caps")
[ -n "$mask" ] && [ $((0x$mask & 0x1000000)) = 0 ] || fail "fixture caller still holds CAP_SYS_RESOURCE ($mask)"

dump() {
    for kind in stdout stderr init outcome; do
        if [ -e "$results/$1.$kind" ]; then
            echo "--- $1.$kind" >&2
            cat "$results/$1.$kind" >&2
        fi
    done
}
step() { # TAG COMMAND...: must succeed, else dump TAG.
    step_tag=$1
    shift
    "$@" || { dump "$step_tag"; fail "$step_tag: command failed: $*"; }
}
reset_out() { rm -f "$out/fsize.data"; }
# No process may remain from a bundle: its init carries the bundle path in
# its command line until it executes the workload.
rootfs_identity=$(stat -L -c '%d:%i' "$rootfs")
# leftovers NAME: prints each process that is a launcher or not-yet-executed
# init of bundle NAME (its command line has --bundle), or whose root is the
# test rootfs, which an init or workload that already executed still has.
leftovers() {
    for dir in /proc/[0-9]*; do
        arguments=$(tr '\0' ' ' < "$dir/cmdline" 2>/dev/null) || continue
        case "$arguments" in
        *"--bundle $bundles/$1 "*) echo "${dir#/proc/} (bundle command line: $arguments)"; continue ;;
        esac
        identity=$(stat -L -c '%d:%i' "$dir/root" 2>/dev/null) || continue
        [ "$identity" != "$rootfs_identity" ] || echo "${dir#/proc/} (root is the test rootfs: $arguments)"
    done
    return 0
}
# no_process_of NAME: nothing from NAME remains; exiting processes get a
# short grace period to be reaped.
no_process_of() {
    deadline=$(($(date +%s) + 10))
    while :; do
        remaining=$(leftovers "$1")
        [ -n "$remaining" ] || return 0
        [ "$(date +%s)" -lt "$deadline" ] || fail "$1: processes remain: $remaining"
        sleep 0.05
    done
}
# sample_created_init RT TAG: writes TAG.init from the live created init's
# /proc/PID/limits. Returns 1 only if state shows the init already stopped;
# a created container whose limits cannot be read fails.
sample_created_init() {
    sample_status=$(status_of "$1" "$2")
    case "$sample_status" in
    created)
        sample_pid=$(pid_of "$1" "$2")
        [ -n "$sample_pid" ] && [ "$sample_pid" != 0 ] || { dump "$2"; fail "$2: created state has no init PID"; }
        proc_limits "$sample_pid" > "$results/$2.init" && return 0
        [ "$(status_of "$1" "$2")" = stopped ] && return 1
        dump "$2"
        fail "$2: cannot read the live created init's limits"
        ;;
    stopped) return 1 ;;
    *) dump "$2"; fail "$2: status after create is '$sample_status'" ;;
    esac
}
settled() { settled_status=$(status_of "$1" "$2"); [ "$settled_status" != created ] && [ "$settled_status" != running ]; }

# observe RT TAG BUNDLE MODE: runs a probe bundle; TAG.stdout holds its
# record. For create/start, TAG.init holds the created init's
# /proc/PID/limits, read after create has returned successfully.
observe() {
    rt=$1 tag=$2 name=$3 mode=$4
    reset_out
    case "$mode" in
    foreground)
        step "$tag" as_caller $rt run --bundle "$bundles/$name" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        ;;
    detached)
        step "$tag" as_caller $rt run --detach --bundle "$bundles/$name" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        wait_status "$rt" "$tag" stopped
        step "$tag" $rt delete "$tag"
        ;;
    created)
        step "$tag" as_caller $rt create --bundle "$bundles/$name" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        created_status=$(status_of "$rt" "$tag")
        [ "$created_status" = created ] || { dump "$tag"; fail "$tag: status after create is '$created_status'"; }
        pid=$(pid_of "$rt" "$tag")
        proc_limits "$pid" > "$results/$tag.init" || { dump "$tag"; fail "$tag: cannot read /proc/$pid/limits"; }
        [ ! -s "$results/$tag.stdout" ] || { dump "$tag"; fail "$tag: workload ran before start"; }
        step "$tag" $rt start "$tag"
        wait_status "$rt" "$tag" stopped
        step "$tag" $rt delete "$tag"
        ;;
    esac
    test -s "$results/$tag.stdout" || { dump "$tag"; fail "$tag: no probe record"; }
}
# expect FILE TAG LINES: each |-separated line occurs exactly in FILE.
expect() {
    file=$1 tag=$2 lines=$3
    old_ifs=$IFS
    IFS='|'
    for line in $lines; do
        grep -qxF -- "$line" "$file" || { IFS=$old_ifs; dump "$tag"; fail "$tag: expected '$line' in ${file##*/}"; }
    done
    IFS=$old_ifs
}
# Unconfigured resources keep the caller's values.
expect_inherited() {
    tag=$1 configured_names=$2
    while read -r name soft hard; do
        case "|$configured_names|" in *"|$name|"*) continue ;; esac
        expect "$results/$tag.stdout" "$tag" "$name $soft $hard"
    done < "$results/caller.limits"
}

shared_checks() {
    impl=$1 rt=$2
    for mode in foreground detached created; do
        for who in root user; do
            # Absent: every limit is the caller's.
            tag=absent-$who-$mode-$impl
            observe "$rt" "$tag" "absent-$who" "$mode"
            cmp -s "$results/caller.limits" "$results/$tag.stdout" \
                || { diff "$results/caller.limits" "$results/$tag.stdout" >&2 || :; fail "$tag: limits differ from the caller's"; }

            # Configured: every entry in order, so the second RLIMIT_NOFILE
            # is in force; unconfigured resources stay inherited.
            tag=configured-$who-$mode-$impl
            observe "$rt" "$tag" "configured-$who" "$mode"
            expect "$results/$tag.stdout" "$tag" "$configured_lines"
            expect_inherited "$tag" "RLIMIT_NOFILE|RLIMIT_FSIZE|RLIMIT_CORE|RLIMIT_MEMLOCK|RLIMIT_NPROC|RLIMIT_CPU"
        done
        # Enforcement as uid 1000: fds 0-2 are open, so 13 more fit below 16.
        tag=nofile-$mode-$impl
        observe "$rt" "$tag" nofile "$mode"
        expect "$results/$tag.stdout" "$tag" "nofile opened=13 errno=EMFILE"
    done
    # A created init already holds the configured limits when create returns.
    expect "$results/configured-root-created-$impl.init" "configured-root-created-$impl" "$configured_proc"
    expect "$results/configured-user-created-$impl.init" "configured-user-created-$impl" "$configured_proc"
    expect "$results/nofile-created-$impl.init" "nofile-created-$impl" "Max open files 16 16 files"

    for mode in foreground created; do
        tag=fsize-$mode-$impl
        observe "$rt" "$tag" fsize "$mode"
        expect "$results/$tag.stdout" "$tag" "fsize first=4096 second=EFBIG size=4096"
    done
    # SIGXCPU at the 1-second soft limit. The probe itself requires 0.8-2.0
    # seconds of process CPU time when the signal arrives and prints only a
    # stable marker; an out-of-range time or its 20 s wall-clock guard
    # expiring makes it exit 2, which fails the run step with its record.
    tag=cpu-foreground-$impl
    observe "$rt" "$tag" cpu foreground
    expect "$results/$tag.stdout" "$tag" "cpu sigxcpu in-range"
    echo "$impl: absent, configured root/non-root, repeated, infinity, created-init, NOFILE, FSIZE, and CPU limits ok"
}

shared_checks swift "$ours"
# nofile_omitted RECORD: true when the bundle behind a created-init record
# (BUNDLE-created-IMPL.init) has no RLIMIT_NOFILE entry, even if it
# configures other rlimits.
nofile_omitted() {
    bundle=${1%-created-*.init}
    ! grep -q '"RLIMIT_NOFILE"' "$bundles/$bundle/config.json"
}
# This runtime's created init keeps the caller's RLIMIT_NOFILE whenever the
# config omits it, exactly as its workload does.
for record in $(cd "$results" && ls -- *-created-swift.init); do
    if nofile_omitted "$record"; then
        expect "$results/$record" "${record%.init}" "Max open files 256 512 files"
    fi
done
nofile_note=
if [ "$compare" = 1 ]; then
    shared_checks runc "$theirs"
    for record in $(cd "$results" && ls -- *-swift.stdout *-swift.init); do
        theirs_record=$(echo "$record" | sed 's/-swift\./-runc./')
        ours_file=$results/$record theirs_file=$results/$theirs_record
        case "$record" in
        *-created-swift.init)
            if nofile_omitted "$record"; then
                # With RLIMIT_NOFILE omitted (other rlimits may still be
                # configured), runc's Go runtime raises its own soft
                # RLIMIT_NOFILE during bootstrap and restores the inherited
                # value at execve (init_linux.go maybeClearRlimitNofileCache),
                # so only a waiting runc init shows the raised soft value.
                # The workloads, compared too, see the same inherited limit;
                # every other line, configured limits included, must match.
                grep -v '^Max open files ' "$results/$record" > "$results/$record.compared"
                grep -v '^Max open files ' "$results/$theirs_record" > "$results/$theirs_record.compared"
                ours_file=$results/$record.compared theirs_file=$results/$theirs_record.compared
                nofile_note=", omitted NOFILE of waiting inits not compared (runc's Go bootstrap raises it until execve)"
                runc_value=$(grep '^Max open files ' "$results/$theirs_record") || runc_value=missing
                echo "runc ${theirs_record%.init} (NOFILE omitted; Go bootstrap value, not compared): $runc_value"
            fi
            ;;
        esac
        if ! cmp -s "$ours_file" "$theirs_file"; then
            diff "$theirs_file" "$ours_file" >&2 || :
            fail "$record differs from runc (diff: runc -> swift)"
        fi
    done
fi

# not_timeout TAG COMMAND STATUS: a status from the timeout wrapper (124, or
# 137/143 after KILL/TERM) is a hang, never a setup failure or outcome.
not_timeout() {
    case "$3" in
    124 | 137 | 143) dump "$1"; fail "$1: $2 timed out or was killed (status $3)" ;;
    esac
}
# expect_failure IMPL RT NAME MODE [MESSAGE] [CALLER...]: setup fails, no
# state or process remains, and nothing ran. create must fail synchronously.
expect_failure() {
    impl=$1 rt=$2 name=$3 mode=$4 message=$5
    shift 5
    tag=$name-$mode-$impl
    case "$mode" in foreground) command=run ;; created) command=create ;; esac
    if "$@" $rt $command --bundle "$bundles/$name" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"; then
        dump "$tag"
        fail "$tag: $command succeeded"
    else
        status=$?
    fi
    not_timeout "$tag" "$command" "$status"
    [ -z "$message" ] || grep -qF -- "$message" "$results/$tag.stderr" || { dump "$tag"; fail "$tag: expected error '$message'"; }
    if $rt state "$tag" > /dev/null 2>&1; then dump "$tag"; fail "$tag: failed $command left state"; fi
    [ ! -s "$results/$tag.stdout" ] || { dump "$tag"; fail "$tag: workload ran"; }
    no_process_of "$name"
}
failure_checks() {
    impl=$1 rt=$2
    for mode in foreground created; do
        # The first entry is refused (above fs.nr_open); the later valid one
        # of the same type does not rescue it.
        msg=; [ "$impl" = swift ] && msg='set process.rlimits[0] RLIMIT_NOFILE soft unlimited hard unlimited'
        expect_failure "$impl" "$rt" dup-infinity "$mode" "$msg" as_caller
        # Lowering then raising needs CAP_SYS_RESOURCE for the second step,
        # while the same final entry alone is grantable (checked below).
        msg=; [ "$impl" = swift ] && msg='set process.rlimits[1] RLIMIT_NOFILE soft 32 hard 64'
        expect_failure "$impl" "$rt" dup-raise "$mode" "$msg" without_sys_resource
        msg=; [ "$impl" = swift ] && msg="set process.rlimits[0] RLIMIT_NOFILE soft 32 hard $((nr_open + 1))"
        expect_failure "$impl" "$rt" above-nr-open "$mode" "$msg" as_caller
        msg=; [ "$impl" = swift ] && msg='process.rlimits[0] RLIMIT_FSIZE soft limit 2 exceeds hard limit 1'
        expect_failure "$impl" "$rt" soft-above-hard "$mode" "$msg" as_caller
        msg=; [ "$impl" = swift ] && msg='process.rlimits[0].type RLIMIT_NOPE is not a Linux rlimit'
        expect_failure "$impl" "$rt" unknown-type "$mode" "$msg" as_caller
    done
    tag=single-raise-$impl
    step "$tag" without_sys_resource $rt run --bundle "$bundles/single-raise" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    expect "$results/$tag.stdout" "$tag" "RLIMIT_NOFILE 32 64"
    echo "$impl: in-order failures, ungrantable, invalid, and unknown limits fail setup and leave nothing"
}
failure_checks swift "$ours"
[ "$compare" = 1 ] && failure_checks runc "$theirs"

# Tiny limits are applied at the same point as in runc, so each runtime's
# own remaining setup and start handshake run under them. Whether that
# bootstrap fits in 3 descriptors or 1 GiB of address space depends on the
# runtime's implementation (Swift init and its start socket versus runc's Go
# init and exec FIFO), not on OCI limit semantics, so the success/failure
# outcomes are recorded and shown rather than required to match. Strict
# for both runtimes: no step may hang (timeout statuses fail), a created
# init holds the configured limit as soon as create returns, a workload
# that ran observes exactly the limit, a failed start leaves a stopped
# container that plain delete removes, and no state or process remains.
outcome() { # IMPL RT NAME MODE PROC_LINE: writes NAME-MODE-IMPL.outcome
    impl=$1 rt=$2 name=$3 mode=$4 proc_line=$5
    tag=$name-$mode-$impl
    record=$results/$tag.outcome
    case "$mode" in
    foreground)
        if as_caller $rt run --bundle "$bundles/$name" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        then status=0; else status=$?; fi
        not_timeout "$tag" run "$status"
        echo "run=$status" > "$record"
        ;;
    created)
        if as_caller $rt create --bundle "$bundles/$name" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        then status=0; else status=$?; fi
        not_timeout "$tag" create "$status"
        echo "create=$status" > "$record"
        if [ "$status" = 0 ]; then
            # A live created init must hold the configured limit. An init
            # whose own bootstrap died right after readiness is recorded as
            # such, once state confirms it stopped; it is not sampled.
            if sample_created_init "$rt" "$tag"; then
                [ -z "$proc_line" ] || expect "$results/$tag.init" "$tag" "$proc_line"
                if $rt start "$tag" >> "$results/$tag.stderr" 2>&1; then status=0; else status=$?; fi
                not_timeout "$tag" start "$status"
                echo "start=$status" >> "$record"
            else
                echo "init=stopped-before-sampling" >> "$record"
            fi
            # A start the init cannot serve must end it promptly.
            wait_until "$tag to stop" settled "$rt" "$tag"
            final_status=$(status_of "$rt" "$tag")
            [ "$final_status" = stopped ] || { dump "$tag"; fail "$tag: status after start is '$final_status'"; }
            step "$tag" $rt delete "$tag"
        fi
        ;;
    esac
    if $rt state "$tag" > /dev/null 2>&1; then dump "$tag"; fail "$tag: state left behind"; fi
    no_process_of "$name"
    cat "$results/$tag.stdout" >> "$record"
}
tiny_checks() {
    impl=$1 rt=$2
    for mode in foreground created; do
        outcome "$impl" "$rt" tiny-nofile "$mode" "Max open files 3 3 files"
        outcome "$impl" "$rt" tiny-as "$mode" "Max address space 1073741824 1073741824 bytes"
        outcome "$impl" "$rt" unlimited-as "$mode" ""
    done
    # The control proves the 1536 MiB PROT_NONE reservation is refused by
    # RLIMIT_AS only: the workload reports the caller's unlimited value and
    # the same mmap succeeds.
    expect "$results/unlimited-as-foreground-$impl.outcome" "unlimited-as-foreground-$impl" \
        "run=0|as limit=unlimited:unlimited big=ok small=ok"
    for mode in foreground created; do
        # A workload that ran observed exactly the limit.
        if grep -q '^nofile' "$results/tiny-nofile-$mode-$impl.outcome"; then
            expect "$results/tiny-nofile-$mode-$impl.outcome" "tiny-nofile-$mode-$impl" "nofile opened=0 errno=EMFILE"
        fi
        if grep -q '^as' "$results/tiny-as-$mode-$impl.outcome"; then
            expect "$results/tiny-as-$mode-$impl.outcome" "tiny-as-$mode-$impl" "as limit=1073741824:1073741824 big=ENOMEM small=ok"
        fi
    done
}
show_outcomes() { # IMPL: the recorded bootstrap outcomes, for the log.
    for record in "$results"/tiny-*-"$1".outcome; do
        label=${record##*/}
        printf '%s %s: %s\n' "$1" "${label%.outcome}" "$(tr '\n' ' ' < "$record")"
        sed -n '1,3s/^/    stderr: /p' "${record%.outcome}.stderr"
    done
}
tiny_checks swift "$ours"
# Under RLIMIT_NOFILE 3 this runtime's created init has no descriptor left
# for the start connection, so create itself fails with that diagnosis and
# leaves nothing (checked by outcome), instead of an init that exits later.
expect "$results/tiny-nofile-created-swift.outcome" tiny-nofile-created-swift "create=1"
grep -qF 'reserve a descriptor for the start connection' "$results/tiny-nofile-created-swift.stderr" \
    || { dump tiny-nofile-created-swift; fail "tiny-nofile-created-swift: expected the start-descriptor diagnosis"; }
show_outcomes swift
tiny_note=
if [ "$compare" = 1 ]; then
    tiny_checks runc "$theirs"
    show_outcomes runc
    tiny_note=", tiny NOFILE/AS limits held and enforced under both (bootstrap outcomes recorded, not required to match)"
fi

# Foreground parent-death cleanup still works under a tiny RLIMIT_NOFILE.
"$runtime" --root "$state_root" run --bundle "$bundles/tiny-nofile-loop" orphan < /dev/null > /dev/null 2>&1 &
job=$!
running_sleep() { pid=$(pid_of "$ours" orphan 2>/dev/null) && test "$(cat "/proc/$pid/comm" 2>/dev/null)" = sleep; }
wait_until "orphan to run" running_sleep
pid=$(pid_of "$ours" orphan)
proc_limits "$pid" > "$results/orphan.limits" || fail "cannot read the orphan's limits"
expect "$results/orphan.limits" orphan "Max open files 3 3 files"
kill -KILL "$job"
wait "$job" 2>/dev/null || :
wait_dead "$pid"
wait_status "$ours" orphan stopped
$ours delete orphan

test -z "$(ls -A "$state_root")" || { ls -A "$state_root" >&2; fail "state left behind"; }
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Rlimit integration checks passed (comparison: $comparison): absent and configured root/non-root limits in foreground, detached, and create/start; created init limits$nofile_note; repeated types in order; hard raises and infinity; NOFILE, FSIZE, and CPU enforcement; earlier refused entries not bypassed; ungrantable, invalid, and unknown limits leave nothing$tiny_note; parent-death cleanup under a tiny NOFILE."
