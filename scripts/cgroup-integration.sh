#!/bin/sh
# cgroup v2 checks for linux.cgroupsPath and the implemented resources
# (memory limit/reservation/swap, pids limit), compared with runc: a created
# init is already a member of its cgroup with every limit written when create
# returns; root and uid 1000 workloads see their own cgroup in foreground run,
# detached run, and create/start; pids.max is enforced (fork fails with
# EAGAIN) and memory.max OOM-kills (proved by memory.events oom_kill, never by
# a timeout); runc's pids 0 and swap conversions; invalid values leave
# nothing; concurrent containers keep their own groups; descendants are
# killed and every created cgroup is removed; "domain invalid" cgroups below a
# threaded root take pids but refuse memory. This runtime alone is also
# checked for: a recreated cgroup at the same path and a cgroup recorded under
# another boot ID are left untouched, a supplied cgroup is emptied and kept,
# a non-empty supplied cgroup is refused, of two containers created at once in
# one supplied cgroup exactly one wins, unsupported resources are rejected,
# failed setup removes its cgroup, and an unrelated group is never changed.
# The probe is scripts/fixtures/cgroup-probe.c, linked statically into a
# static BusyBox rootfs.
#
# Run as root inside a disposable Linux VM with cgroup v2 at /sys/fs/cgroup.
# Every test cgroup lives below /sct-<PID> (removed at exit). The memory and
# pids controllers must already be enabled in the root's cgroup.subtree_control:
# the caller delegates them, since a namespace root can enable them only once
# no process (including the caller's own shell) remains in it. scripts/test-linux.sh
# moves its top-level shell into /runner first; CI uses the host cgroup
# namespace, whose root systemd has already delegated. This script moves no
# process other than its own sleeps and kills nothing outside /sct-<PID>.
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/srunc}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
busybox=${BUSYBOX:-/bin/busybox}
cc=${CC:-clang}
compare=${RUNC_COMPARE:-auto}
cg=/sys/fs/cgroup
fixture=sct-$$
fix=$cg/$fixture
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
state_root=$scratch/state
runc_root=$scratch/runc-state
results=$scratch/results
ours="timeout -k 2 60 $runtime --root $state_root"
theirs="timeout -k 2 60 runc --root $runc_root"
fixture_pids=
default_existed=1
[ -d "$cg/swift-container-runtime" ] || default_existed=0

# Diagnostics go to fd 3, the script's original stderr: a step's own stderr
# is redirected into its result file, which dump reads.
exec 3>&2
warn() { echo "cgroup-integration: warning: $*" >&3; }
cleanup() {
    for id in $($ours list -q 2>/dev/null); do $ours delete --force "$id" >/dev/null 2>&1 || :; done
    if [ "$compare" = 1 ]; then
        for id in $($theirs list -q 2>/dev/null); do $theirs delete --force "$id" >/dev/null 2>&1 || :; done
    fi
    for pid in $fixture_pids; do kill -KILL "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; done
    # Only this fixture's own subtree is emptied and removed.
    if [ -d "$fix" ]; then
        echo 1 > "$fix/cgroup.kill" 2>/dev/null || :
        sleep 0.2
        find "$fix" -depth -type d -exec rmdir {} \; 2>/dev/null || :
        [ ! -d "$fix" ] || warn "could not remove $fix"
    fi
    if [ "$default_existed" = 0 ] && [ -d "$cg/swift-container-runtime" ]; then
        rmdir "$cg/swift-container-runtime" 2>/dev/null || warn "could not remove $cg/swift-container-runtime"
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
    echo "cgroup-integration: $*" >&3
    exit 1
}

[ "$(id -u)" = 0 ] || fail "must run as root"
[ "$(stat -f -c %T "$cg")" = cgroup2fs ] || fail "$cg is not a cgroup v2 mount"
if ldd "$busybox" >/dev/null 2>&1; then fail "BusyBox at $busybox must be statically linked"; fi
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

for controller in memory pids; do
    grep -qw "$controller" "$cg/cgroup.subtree_control" \
        || fail "the $controller controller is not enabled in $cg/cgroup.subtree_control; the caller must delegate it (see the header)"
done
# The fixture root delegates pids only; the runtimes must enable memory here.
mkdir "$fix"
echo +pids > "$fix/cgroup.subtree_control"

# Rootfs: static BusyBox plus the static probe.
rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$results"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
"$cc" -static -O2 -o "$rootfs/bin/cgroup-probe" "$here/fixtures/cgroup-probe.c" \
    || fail "cannot build the static probe with $cc"
if ldd "$rootfs/bin/cgroup-probe" >/dev/null 2>&1; then fail "the probe is not statically linked"; fi

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}
]'
# Without a PID namespace there is no proc mount: this runtime refuses one in
# the host's PID namespace, and the holder needs none.
dev_mounts='[
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}
]'
pid_namespaces='[{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]'
host_pid_namespaces='[{"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]'
bundles=$scratch/bundles
# write_config NAME USER_JSON LINUX_FIELDS ARGS_JSON [NAMESPACES_JSON [MOUNTS_JSON]]
# LINUX_FIELDS is empty or ', "cgroupsPath": ..., "resources": ...'.
write_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": $2, "args": $4, "env": ["PATH=/bin"], "cwd": "/"},
  "hostname": "cgroupbox",
  "mounts": ${6:-$mounts},
  "linux": {"namespaces": ${5:-$pid_namespaces}$3}
}
EOF
}
# cgroup_fields PATH [RESOURCES_JSON]
cgroup_fields() {
    if [ -n "${2:-}" ]; then
        printf ', "cgroupsPath": "%s", "resources": %s' "$1" "$2"
    else
        printf ', "cgroupsPath": "%s"' "$1"
    fi
}
root='{"uid": 0, "gid": 0}'
user='{"uid": 1000, "gid": 1000}'
# runc's VM reference: memory+swap 96 MiB over a 64 MiB limit is 32 MiB swap.
reference='{"memory": {"limit": 67108864, "reservation": 16777216, "swap": 100663296}, "pids": {"limit": 16}}'
reference_values="memory.max 67108864|memory.low 16777216|memory.swap.max 33554432|pids.max 16"
pids16='{"pids": {"limit": 16}}'
# 32 MiB with memory+swap equal to it: swap.max 0, so 256 MiB cannot fit.
oom_limit='{"memory": {"limit": 33554432, "swap": 33554432}}'
membership='["/bin/sh", "-c", "cat /proc/self/cgroup; id -u"]'
fork_probe='["/bin/cgroup-probe", "fork", "64"]'
holder='["/bin/sh", "-c", "/bin/sleep 1000 & exec /bin/sleep 999"]'

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
unpopulated() { grep -qx 'populated 0' "$1/cgroup.events"; }
procs_count() { test "$(wc -l < "$1/cgroup.procs")" -eq "$2"; }
try_rmdir() { rmdir "$1" 2>/dev/null; }
oom_kills() { sed -n 's/^oom_kill //p' "$1/memory.events"; }
# cgroup_values PATH: the implemented limit files of cgroup PATH.
cgroup_values() {
    for file in memory.max memory.low memory.swap.max pids.max; do
        if [ -e "$cg$1/$file" ]; then echo "$file $(cat "$cg$1/$file")"; else echo "$file absent"; fi
    done
}
# spawn_sleeper DIR: a fixture-owned sleep moved into cgroup DIR; sets sleeper.
spawn_sleeper() {
    sleep 1000 < /dev/null > /dev/null 2>&1 &
    sleeper=$!
    fixture_pids="$fixture_pids $sleeper"
    echo "$sleeper" > "$1/cgroup.procs" || fail "cannot move fixture sleep $sleeper into $1"
}
stop_sleeper() { kill -KILL "$1" 2>/dev/null || :; wait "$1" 2>/dev/null || :; }

dump() {
    for kind in stdout stderr member values; do
        if [ -e "$results/$1.$kind" ]; then
            echo "--- $1.$kind" >&3
            cat "$results/$1.$kind" >&3
        fi
    done
}
# step TAG COMMAND...: must exit 0; its status is captured directly, and a
# timeout is reported as one.
step() {
    step_tag=$1
    shift
    if "$@"; then return 0; else step_status=$?; fi
    not_timeout "$step_tag" "$*" "$step_status"
    dump "$step_tag"
    fail "$step_tag: command failed with status $step_status: $*"
}
rootfs_identity=$(stat -L -c '%d:%i' "$rootfs")
# leftovers NAME: launchers or not-yet-executed inits of bundle NAME, and
# any process whose root is the test rootfs.
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
no_process_of() {
    deadline=$(($(date +%s) + 10))
    while :; do
        remaining=$(leftovers "$1")
        [ -n "$remaining" ] || return 0
        [ "$(date +%s)" -lt "$deadline" ] || fail "$1: processes remain: $remaining"
        sleep 0.05
    done
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
gone() { # TAG PATH: the container's cgroup no longer exists.
    [ ! -e "$cg$2" ] || { dump "$1"; fail "$1: cgroup $2 remains after the container was removed"; }
}
# member_of TAG PID PATH: PID's cgroup v2 membership, recorded in TAG.member.
member_of() {
    sed -n '/^0::/p' "/proc/$2/cgroup" > "$results/$1.member" || { dump "$1"; fail "$1: cannot read /proc/$2/cgroup"; }
    expect "$results/$1.member" "$1" "0::$3"
}
# not_timeout TAG COMMAND STATUS: a status from the timeout wrapper (124, or
# 137/143 after KILL/TERM) is a hang, never an expected failure.
not_timeout() {
    case "$3" in
    124 | 137 | 143) dump "$1"; fail "$1: $2 timed out or was killed (status $3)" ;;
    esac
}

# observe RT TAG MODE PATH: runs bundle TAG, whose cgroup is PATH, to
# completion. For create/start, the waiting init's membership (TAG.member)
# and limits (TAG.values) are read after create has returned. Afterwards the
# cgroup and every process are gone.
observe() {
    rt=$1 tag=$2 mode=$3 path=$4
    case "$mode" in
    foreground)
        step "$tag" $rt run --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        ;;
    detached)
        step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        wait_status "$rt" "$tag" stopped
        step "$tag" $rt delete "$tag"
        ;;
    created)
        step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        created_status=$(status_of "$rt" "$tag")
        [ "$created_status" = created ] || { dump "$tag"; fail "$tag: status after create is '$created_status'"; }
        member_of "$tag" "$(pid_of "$rt" "$tag")" "$path"
        cgroup_values "$path" > "$results/$tag.values"
        [ ! -s "$results/$tag.stdout" ] || { dump "$tag"; fail "$tag: workload ran before start"; }
        step "$tag" $rt start "$tag"
        wait_status "$rt" "$tag" stopped
        step "$tag" $rt delete "$tag"
        ;;
    esac
    gone "$tag" "$path"
    no_process_of "$tag"
}

# oom_check RT TAG MODE: a workload allocating past memory.max is OOM-killed.
# The kill is proved by oom_kill in the parent's hierarchical memory.events
# (and, while the cgroup exists, its own), never inferred from a status, and
# a run that took long enough to be a timeout fails.
oom_check() {
    rt=$1 tag=$2 mode=$3
    parent=$base/$tag
    path=$parent/ctr
    write_config "$tag" "$user" "$(cgroup_fields "$path" "$oom_limit")" '["/bin/cgroup-probe", "alloc", "256"]'
    started=$(date +%s)
    case "$mode" in
    foreground)
        if $rt run --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"; then
            dump "$tag"
            fail "$tag: run succeeded despite memory.max"
        else
            status=$?
        fi
        [ "$status" != 124 ] || { dump "$tag"; fail "$tag: run timed out"; }
        ;;
    detached | created)
        if [ "$mode" = detached ]; then
            step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        else
            step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            baseline=$(oom_kills "$cg$path")
            [ "$baseline" = 0 ] || { dump "$tag"; fail "$tag: new cgroup starts with oom_kill $baseline"; }
            step "$tag" $rt start "$tag"
        fi
        wait_status "$rt" "$tag" stopped
        own=$(oom_kills "$cg$path")
        [ "$own" -gt 0 ] || { dump "$tag"; fail "$tag: no oom_kill in $path/memory.events"; }
        step "$tag" $rt delete "$tag"
        ;;
    esac
    elapsed=$(($(date +%s) - started))
    [ "$elapsed" -lt 45 ] || { dump "$tag"; fail "$tag: took ${elapsed}s, indistinguishable from a timeout"; }
    kills=$(oom_kills "$cg$parent")
    [ "$kills" -gt 0 ] || { dump "$tag"; fail "$tag: no oom_kill recorded in $parent/memory.events"; }
    grep -q '^allocated ' "$results/$tag.stdout" || { dump "$tag"; fail "$tag: the probe never allocated"; }
    if grep -qx 'done' "$results/$tag.stdout"; then dump "$tag"; fail "$tag: 256 MiB fit below a 32 MiB limit"; fi
    if grep -q '^mmap failed' "$results/$tag.stdout"; then dump "$tag"; fail "$tag: mmap failed instead of an OOM kill"; fi
    gone "$tag" "$path"
    no_process_of "$tag"
}

# expect_failure RT NAME MODE MESSAGE: setup fails without a timeout, with
# MESSAGE (if any) in stderr, leaving no state, output, or process.
expect_failure() {
    # Its own names, so the caller's tag and mode survive.
    failing_rt=$1 failing=$2 failing_mode=$3 message=$4
    attempt=$failing-$failing_mode
    case "$failing_mode" in foreground) command=run ;; created) command=create ;; esac
    if $failing_rt $command --bundle "$bundles/$failing" "$attempt" < /dev/null > "$results/$attempt.stdout" 2> "$results/$attempt.stderr"; then
        dump "$attempt"
        fail "$attempt: $command succeeded"
    else
        status=$?
    fi
    not_timeout "$attempt" "$command" "$status"
    [ -z "$message" ] || grep -qF -- "$message" "$results/$attempt.stderr" || { dump "$attempt"; fail "$attempt: expected error '$message'"; }
    if $failing_rt state "$attempt" > /dev/null 2>&1; then dump "$attempt"; fail "$attempt: failed $command left state"; fi
    [ ! -s "$results/$attempt.stdout" ] || { dump "$attempt"; fail "$attempt: workload ran"; }
    no_process_of "$failing"
}

# An unrelated group with its own limit and process, checked at the end.
mkdir "$fix/bystander"
echo 7 > "$fix/bystander/pids.max"
spawn_sleeper "$fix/bystander"
bystander=$sleeper

shared_checks() {
    impl=$1 rt=$2
    base=/$fixture/$impl
    for mode in foreground detached created; do
        # Membership and limits for root and uid 1000.
        for who in root user; do
            tag=member-$who-$mode-$impl
            case "$who" in root) who_json=$root uid=0 ;; user) who_json=$user uid=1000 ;; esac
            write_config "$tag" "$who_json" "$(cgroup_fields "$base/$tag" "$reference")" "$membership"
            observe "$rt" "$tag" "$mode" "$base/$tag"
            expect "$results/$tag.stdout" "$tag" "0::$base/$tag|$uid"
        done
        # pids.max 16: the probe plus 15 children, then EAGAIN.
        tag=fork-$mode-$impl
        write_config "$tag" "$user" "$(cgroup_fields "$base/$tag" "$pids16")" "$fork_probe"
        observe "$rt" "$tag" "$mode" "$base/$tag"
        expect "$results/$tag.stdout" "$tag" "forked 15 errno EAGAIN"
        oom_check "$rt" "oom-$mode-$impl" "$mode"
    done
    # Every limit is written before create returns.
    expect "$results/member-root-created-$impl.values" "member-root-created-$impl" "$reference_values"
    expect "$results/member-user-created-$impl.values" "member-user-created-$impl" "$reference_values"
    expect "$results/fork-created-$impl.values" "fork-created-$impl" "pids.max 16"

    # pids 0, negative pids, and unlimited memory.
    tag=pids-zero-$impl
    write_config "$tag" "$root" "$(cgroup_fields "$base/$tag" '{"pids": {"limit": 0}}')" '["/bin/true"]'
    observe "$rt" "$tag" created "$base/$tag"
    tag=unlimited-$impl
    write_config "$tag" "$root" "$(cgroup_fields "$base/$tag" '{"memory": {"limit": -1}, "pids": {"limit": -1}}')" '["/bin/true"]'
    observe "$rt" "$tag" created "$base/$tag"
    expect "$results/$tag.values" "$tag" "memory.max max|memory.swap.max max|pids.max max"

    # Descendants without a PID namespace survive the init; delete kills them.
    tag=orphans-$impl
    path=$base/$tag
    write_config "$tag" "$root" "$(cgroup_fields "$path" "$pids16")" "$holder" "$host_pid_namespaces" "$dev_mounts"
    step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    step "$tag" $rt start "$tag"
    wait_until "$tag to hold two processes" procs_count "$cg$path" 2
    init=$(pid_of "$rt" "$tag")
    child=$(grep -vx "$init" "$cg$path/cgroup.procs")
    kill -KILL "$init"
    wait_dead "$init"
    wait_status "$rt" "$tag" stopped
    alive "$child" || { dump "$tag"; fail "$tag: the descendant died with the init"; }
    step "$tag" $rt delete "$tag"
    wait_dead "$child"
    gone "$tag" "$path"
    no_process_of "$tag"
    # With a PID namespace, force delete of a running container.
    tag=tree-$impl
    path=$base/$tag
    write_config "$tag" "$root" "$(cgroup_fields "$path" "$pids16")" "$holder"
    step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    wait_until "$tag to hold two processes" procs_count "$cg$path" 2
    step "$tag" $rt delete --force "$tag"
    gone "$tag" "$path"
    no_process_of "$tag"

    # Concurrent containers keep their own cgroups and limits.
    for limit in 8 12; do
        tag=multi-$limit-$impl
        write_config "$tag" "$root" "$(cgroup_fields "$base/$tag" '{"pids": {"limit": '$limit'}}')" '["/bin/sleep", "1000"]'
        step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    done
    for limit in 8 12; do
        tag=multi-$limit-$impl
        member_of "$tag" "$(pid_of "$rt" "$tag")" "$base/$tag"
        cgroup_values "$base/$tag" > "$results/$tag.values"
        expect "$results/$tag.values" "$tag" "pids.max $limit"
        procs_count "$cg$base/$tag" 1 || { dump "$tag"; fail "$tag: cgroup holds other processes"; }
    done
    for limit in 8 12; do
        step "multi-$limit-$impl" $rt delete --force "multi-$limit-$impl"
        gone "multi-$limit-$impl" "$base/multi-$limit-$impl"
    done

    # Below a threaded root, a new cgroup is "domain invalid": pids (a
    # threaded controller) turns it threaded, memory must fail.
    threaded=/$fixture/threaded-$impl
    mkdir "$cg$threaded" "$cg$threaded/anchor"
    echo threaded > "$cg$threaded/anchor/cgroup.type"
    mkdir "$cg$threaded/pids" "$cg$threaded/mem"
    for leaf in pids mem; do
        [ "$(cat "$cg$threaded/$leaf/cgroup.type")" = "domain invalid" ] || fail "fixture: $threaded/$leaf is not domain invalid"
    done
    tag=thread-pids-$impl
    write_config "$tag" "$user" "$(cgroup_fields "$threaded/pids" "$pids16")" "$fork_probe"
    step "$tag" $rt run --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    expect "$results/$tag.stdout" "$tag" "forked 15 errno EAGAIN"
    no_process_of "$tag"
    tag=thread-mem-$impl
    write_config "$tag" "$user" "$(cgroup_fields "$threaded/mem" "$oom_limit")" '["/bin/true"]'
    message=
    [ "$impl" = swift ] && message="cgroup"
    expect_failure "$rt" "$tag" foreground "$message"
    [ "$impl" = swift ] && { grep -qE 'invalid state|mode|cgroup controller memory' "$results/$tag-foreground.stderr" \
        || { dump "$tag-foreground"; fail "$tag: expected a threaded-subtree error"; }; }
    [ ! -d "$cg$threaded/mem" ] || unpopulated "$cg$threaded/mem" || fail "$tag: $threaded/mem has processes"

    # Invalid memory+swap below the limit: nothing is created.
    tag=bad-swap-$impl
    write_config "$tag" "$root" "$(cgroup_fields "$base/$tag" '{"memory": {"limit": 33554432, "swap": 16777216}}')" '["/bin/true"]'
    message=
    [ "$impl" = swift ] && message="memory+swap limit should be >= memory limit"
    for mode in foreground created; do expect_failure "$rt" "$tag" "$mode" "$message"; done
    [ "$impl" = runc ] || gone "$tag" "$base/$tag"
    echo "$impl: membership, limits, pids and OOM enforcement, conversions, descendants, concurrency, threaded subtree, and invalid values ok"
}

shared_checks swift "$ours"
expect "$results/pids-zero-swift.values" pids-zero-swift "pids.max 1"
expect "$results/thread-pids-swift.stdout" thread-pids-swift "forked 15 errno EAGAIN"
[ "$(cat "$cg/$fixture/threaded-swift/pids/cgroup.type")" = threaded ] || fail "thread-pids-swift: the supplied cgroup is not threaded"
if [ "$compare" = 1 ]; then
    shared_checks runc "$theirs"
    for record in $(cd "$results" && ls -- *-swift.values); do
        theirs_record=$(echo "$record" | sed 's/-swift\./-runc./')
        # Strict, pids 0 included: runc's cgroup library writes pids.max 1.
        if ! cmp -s "$results/$record" "$results/$theirs_record"; then
            diff "$results/$theirs_record" "$results/$record" >&3 || :
            fail "$record differs from runc (diff: runc -> swift)"
        fi
    done
fi

# This runtime only: unsupported resources and failed setup leave nothing.
base=/$fixture/swift
tag=cpu-realtime-swift
write_config "$tag" "$root" "$(cgroup_fields "$base/$tag" '{"cpu": {"shares": 1024, "realtimeRuntime": 950000}}')" '["/bin/true"]'
expect_failure "$ours" "$tag" created "linux.resources.cpu.realtimeRuntime"
gone "$tag" "$base/$tag"
tag=missing-exec-swift
write_config "$tag" "$root" "$(cgroup_fields "$base/$tag" "$pids16")" '["/bin/does-not-exist"]'
expect_failure "$ours" "$tag" foreground ""
gone "$tag" "$base/$tag"

# The default cgroup is /swift-container-runtime/<id>, removed at delete.
tag=default-swift
write_config "$tag" "$root" "" '["/bin/true"]'
observe "$ours" "$tag" created "/swift-container-runtime/$tag"

# No resources, inside ancestors whose controllers the other runtime enabled.
tag=plain-swift
if [ "$compare" = 1 ]; then path=/$fixture/runc/$tag; else path=$base/$tag; fi
write_config "$tag" "$root" "$(cgroup_fields "$path")" "$membership"
observe "$ours" "$tag" created "$path"
expect "$results/$tag.stdout" "$tag" "0::$path|0"

# A supplied cgroup is emptied and kept; a non-empty one is refused.
tag=supplied-swift
path=/$fixture/supplied
mkdir "$cg$path"
write_config "$tag" "$root" "$(cgroup_fields "$path" "$pids16")" "$holder"
step "$tag" $ours run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
wait_until "$tag to hold two processes" procs_count "$cg$path" 2
step "$tag" $ours delete --force "$tag"
[ -d "$cg$path" ] || fail "$tag: the supplied cgroup was removed"
unpopulated "$cg$path" || fail "$tag: the supplied cgroup still has processes"
no_process_of "$tag"
spawn_sleeper "$cg$path"
busy=$sleeper
tag=busy-swift
write_config "$tag" "$root" "$(cgroup_fields "$path" "$pids16")" '["/bin/true"]'
expect_failure "$ours" "$tag" created "is not empty: it already has processes"
alive "$busy" && grep -qx "$busy" "$cg$path/cgroup.procs" || fail "$tag: the supplied cgroup's process was disturbed"
stop_sleeper "$busy"
wait_until "$path to empty" unpopulated "$cg$path"
rmdir "$cg$path"

# Two containers created at once in one supplied cgroup, with different
# limits: exactly one is accepted, and the loser neither changes the winner's
# limit nor touches its init. Repeated, since either may reach the lock first.
path=/$fixture/contended
mkdir "$cg$path"
write_config race-a-swift "$root" "$(cgroup_fields "$path" '{"pids": {"limit": 8}}')" '["/bin/sleep", "1000"]'
write_config race-b-swift "$root" "$(cgroup_fields "$path" '{"pids": {"limit": 12}}')" '["/bin/sleep", "1000"]'
for round in 1 2 3 4 5 6 7 8; do
    tag=race-$round-swift
    $ours create --bundle "$bundles/race-a-swift" "$tag-a" < /dev/null > "$results/$tag-a.stdout" 2> "$results/$tag-a.stderr" &
    racer_a=$!
    $ours create --bundle "$bundles/race-b-swift" "$tag-b" < /dev/null > "$results/$tag-b.stdout" 2> "$results/$tag-b.stderr" &
    racer_b=$!
    if wait "$racer_a"; then status_a=0; else status_a=$?; fi
    if wait "$racer_b"; then status_b=0; else status_b=$?; fi
    not_timeout "$tag-a" create "$status_a"
    not_timeout "$tag-b" create "$status_b"
    if [ "$status_a" = 0 ] && [ "$status_b" != 0 ]; then
        winner=$tag-a loser=$tag-b limit=8
    elif [ "$status_b" = 0 ] && [ "$status_a" != 0 ]; then
        winner=$tag-b loser=$tag-a limit=12
    else
        dump "$tag-a"
        dump "$tag-b"
        fail "$tag: create statuses $status_a and $status_b, expected exactly one success"
    fi
    grep -qF -e "is being set up by another container" -e "is not empty: it already has processes" "$results/$loser.stderr" \
        || { dump "$loser"; fail "$loser: expected the contended-cgroup error"; }
    if $ours state "$loser" > /dev/null 2>&1; then dump "$loser"; fail "$loser: failed create left state"; fi
    winner_init=$(pid_of "$ours" "$winner")
    [ "$(status_of "$ours" "$winner")" = created ] || { dump "$winner"; fail "$winner: the winner is not created"; }
    alive "$winner_init" || { dump "$winner"; fail "$winner: the winner's init died"; }
    [ "$(cat "$cg$path/cgroup.procs")" = "$winner_init" ] || { cat "$cg$path/cgroup.procs" >&3; fail "$tag: the cgroup does not hold exactly the winner's init"; }
    [ "$(cat "$cg$path/pids.max")" = "$limit" ] || fail "$tag: pids.max is $(cat "$cg$path/pids.max"), not the winner's $limit"
    step "$winner" $ours delete --force "$winner"
    [ -d "$cg$path" ] || fail "$tag: the supplied cgroup was removed"
    wait_until "$path to empty" unpopulated "$cg$path"
    [ -z "$(find "$cg$path" -mindepth 1 -type d)" ] || fail "$tag: child cgroups remain in $path"
    no_process_of race-a-swift
    no_process_of race-b-swift
done
rmdir "$cg$path"

# A cgroup recreated at the recorded path is another generation: left alone.
tag=crossgen-swift
path=$base/$tag
write_config "$tag" "$root" "$(cgroup_fields "$path" "$pids16")" '["/bin/sleep", "1000"]'
step "$tag" $ours create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
init=$(pid_of "$ours" "$tag")
kill -KILL "$init"
wait_dead "$init"
wait_status "$ours" "$tag" stopped
wait_until "$path to empty" unpopulated "$cg$path"
wait_until "$path to be removable" try_rmdir "$cg$path"
mkdir "$cg$path"
spawn_sleeper "$cg$path"
step "$tag" $ours delete "$tag" 2> "$results/$tag.stderr"
grep -qF "is no longer the container's cgroup; left untouched" "$results/$tag.stderr" \
    || { dump "$tag"; fail "$tag: expected the replaced-cgroup warning"; }
alive "$sleeper" && grep -qx "$sleeper" "$cg$path/cgroup.procs" || fail "$tag: the new generation's process was disturbed"
stop_sleeper "$sleeper"
wait_until "$path to empty" unpopulated "$cg$path"
rmdir "$cg$path"

# A record from another boot never touches the group now at its path.
tag=stale-boot-swift
path=$base/$tag
write_config "$tag" "$root" "$(cgroup_fields "$path" "$pids16")" '["/bin/sleep", "1000"]'
step "$tag" $ours create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
init=$(pid_of "$ours" "$tag")
kill -KILL "$init"
wait_dead "$init"
wait_status "$ours" "$tag" stopped
spawn_sleeper "$cg$path"
fake_boot=00000000-0000-4000-8000-000000000000
[ "$(cat /proc/sys/kernel/random/boot_id)" != "$fake_boot" ] || fail "the fake boot ID is the real one"
record=$state_root/$tag/state.json
sed 's/"cgroup":{"bootID":"[^"]*"/"cgroup":{"bootID":"'$fake_boot'"/' "$record" > "$results/$tag.state"
grep -qF "\"cgroup\":{\"bootID\":\"$fake_boot\"" "$results/$tag.state" || fail "$tag: cannot rewrite the recorded cgroup boot ID"
cat "$results/$tag.state" > "$record"
step "$tag" $ours delete "$tag" 2> "$results/$tag.stderr"
grep -qF "was recorded before a reboot; left untouched" "$results/$tag.stderr" \
    || { dump "$tag"; fail "$tag: expected the stale-boot warning"; }
alive "$sleeper" && grep -qx "$sleeper" "$cg$path/cgroup.procs" || fail "$tag: the live group's process was disturbed"
[ "$(cat "$cg$path/pids.max")" = 16 ] || fail "$tag: the live group's pids.max changed"
stop_sleeper "$sleeper"
wait_until "$path to empty" unpopulated "$cg$path"
rmdir "$cg$path"
echo "swift: unsupported resources, failed setup, default path, supplied, contended, replaced, and stale-boot cgroups ok"

# The unrelated group is unchanged.
[ "$(cat "$fix/bystander/pids.max")" = 7 ] || fail "bystander: pids.max changed"
alive "$bystander" && grep -qx "$bystander" "$fix/bystander/cgroup.procs" || fail "bystander: its process was disturbed"

test -z "$(ls -A "$state_root")" || { ls -A "$state_root" >&3; fail "state left behind"; }
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Cgroup integration checks passed (comparison: $comparison): membership and memory/swap/pids limits at create for root and uid 1000 in foreground, detached, and create/start; pids EAGAIN and oom_kill enforcement; pids 0 and -1 and unlimited memory conversions; descendant cleanup with and without a PID namespace; concurrent containers; threaded subtree; invalid, unsupported, and failed setups leave nothing; default, supplied, busy, contended, replaced, and stale-boot cgroups; unrelated group unchanged."
