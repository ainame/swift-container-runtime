#!/bin/sh
# cgroup v2 CPU checks for linux.resources.cpu (shares, quota, period, burst,
# idle), compared with runc: a created init's group already holds cpu.weight,
# cpu.max, cpu.max.burst, and cpu.idle when create returns, for root and
# uid 1000 in foreground run, detached run, and create/start; absent, zero,
# negative, default-period, minimum and maximum values read back as runc
# writes them; idle and burst 0 are real writes and shares 0 is none; an idle
# group refuses shares; a burst the current quota refuses is retried after
# cpu.max only when a quota is configured; values the kernel refuses, an
# unavailable controller, and a threaded subtree fail setup under both; and
# quota enforcement is proved with real CPU work through the kernel's cpu.stat
# throttling counters against an unthrottled control. This runtime alone is
# also checked for: only the cpu controller is enabled for CPU-only groups,
# realtime fields are rejected, and an unrelated group is never
# changed. The probe is scripts/fixtures/cpu-probe.c, linked statically into a
# static BusyBox rootfs.
#
# Run as root inside a disposable Linux VM with cgroup v2 at /sys/fs/cgroup.
# Every test cgroup lives below /sct-cpu-<PID> (removed at exit). The cpu
# controller must already be enabled in the root's cgroup.subtree_control:
# the caller delegates it, since a namespace root can enable it only once no
# process (including the caller's own shell) remains in it. scripts/test-linux.sh
# moves its top-level shell into /runner first; CI uses the host cgroup
# namespace, whose root systemd has already delegated. This script moves no
# process other than its own sleeps and kills nothing outside /sct-cpu-<PID>.
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/swift-container-runtime}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
busybox=${BUSYBOX:-/bin/busybox}
cc=${CC:-clang}
compare=${RUNC_COMPARE:-auto}
cg=/sys/fs/cgroup
fixture=${CGROUP_FIXTURE_NAME:-sct-cpu-$$}
fix=$cg/$fixture
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
state_root=$scratch/state
runc_root=$scratch/runc-state
results=$scratch/results
ours="timeout -k 2 60 $runtime --root $state_root"
theirs="timeout -k 2 60 runc --root $runc_root"
fixture_pids=

# Diagnostics go to fd 3, the script's original stderr: a step's own stderr
# is redirected into its result file, which dump reads.
exec 3>&2
warn() { echo "cpu-integration: warning: $*" >&3; }
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
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
    echo "cpu-integration: $*" >&3
    exit 1
}

[ "$(id -u)" = 0 ] || fail "must run as root"
[ "$(stat -f -c %T "$cg")" = cgroup2fs ] || fail "$cg is not a cgroup v2 mount"
if ldd "$busybox" >/dev/null 2>&1; then fail "BusyBox at $busybox must be statically linked"; fi
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

grep -qw cpu "$cg/cgroup.subtree_control" \
    || fail "the cpu controller is not enabled in $cg/cgroup.subtree_control; the caller must delegate it (see the header)"
# The fixture root delegates cpu so that its own supplied groups have the CPU
# files; below it, the runtimes must enable cpu themselves.
mkdir "$fix"
echo +cpu > "$fix/cgroup.subtree_control"
# cpu.max.burst needs Linux 5.14 and cpu.idle 5.15. Without them, requests
# for them must fail under both runtimes instead of being skipped.
mkdir "$fix/features"
has_burst=0 has_idle=0
[ ! -e "$fix/features/cpu.max.burst" ] || has_burst=1
[ ! -e "$fix/features/cpu.idle" ] || has_idle=1
rmdir "$fix/features"
echo "kernel $(uname -r): cpu.max.burst $([ "$has_burst" = 1 ] && echo present || echo missing), cpu.idle $([ "$has_idle" = 1 ] && echo present || echo missing)"

# Rootfs: static BusyBox plus the static probe.
rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$results"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
"$cc" -static -O2 -o "$rootfs/bin/cpu-probe" "$here/fixtures/cpu-probe.c" \
    || fail "cannot build the static probe with $cc"
if ldd "$rootfs/bin/cpu-probe" >/dev/null 2>&1; then fail "the probe is not statically linked"; fi

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}
]'
namespaces='[{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]'
bundles=$scratch/bundles
# write_config NAME USER_JSON LINUX_FIELDS ARGS_JSON
write_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": $2, "args": $4, "env": ["PATH=/bin"], "cwd": "/"},
  "hostname": "cpubox",
  "mounts": $mounts,
  "linux": {"namespaces": $namespaces$3}
}
EOF
}
# cgroup_fields PATH CPU_JSON
cgroup_fields() { printf ', "cgroupsPath": "%s", "resources": {"cpu": %s}' "$1" "$2"; }
root='{"uid": 0, "gid": 0}'
user='{"uid": 1000, "gid": 1000}'
membership='["/bin/sh", "-c", "cat /proc/self/cgroup; id -u"]'
true_args='["/bin/true"]'

# The reference: every field, with a non-default value where the kernel has it.
reference='"shares": 512, "quota": 50000, "period": 200000'
reference_values='cpu.weight 59|cpu.max 50000 200000'
if [ "$has_burst" = 1 ]; then reference="$reference, \"burst\": 10000" reference_values="$reference_values|cpu.max.burst 10000"; fi
if [ "$has_idle" = 1 ]; then reference="$reference, \"idle\": 0" reference_values="$reference_values|cpu.idle 0"; fi
reference="{$reference}"
# Defaults of a group whose CPU files nobody wrote.
default_values='cpu.weight 100|cpu.max max 100000'
[ "$has_burst" = 0 ] || default_values="$default_values|cpu.max.burst 0"
[ "$has_idle" = 0 ] || default_values="$default_values|cpu.idle 0"

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
unpopulated() { grep -qx 'populated 0' "$1/cgroup.events"; }
# cpu_values PATH: the CPU files of cgroup PATH.
cpu_values() {
    for file in cpu.weight cpu.max cpu.max.burst cpu.idle; do
        if [ -e "$cg$1/$file" ]; then echo "$file $(cat "$cg$1/$file")"; else echo "$file absent"; fi
    done
}
# stat_of FILE KEY: KEY's value in a saved cpu.stat; empty when missing.
stat_of() { sed -n "s/^$2 //p" "$1"; }
# spawn_sleeper DIR: a fixture-owned sleep moved into cgroup DIR; sets sleeper.
spawn_sleeper() {
    sleep 1000 < /dev/null > /dev/null 2>&1 &
    sleeper=$!
    fixture_pids="$fixture_pids $sleeper"
    echo "$sleeper" > "$1/cgroup.procs" || fail "cannot move fixture sleep $sleeper into $1"
}
stop_sleeper() { kill -KILL "$1" 2>/dev/null || :; wait "$1" 2>/dev/null || :; }

dump() {
    for kind in stdout stderr member values cpustat; do
        if [ -e "$results/$1.$kind" ]; then
            echo "--- $1.$kind" >&3
            cat "$results/$1.$kind" >&3
        fi
    done
}
# not_timeout TAG COMMAND STATUS: a status from the timeout wrapper (124, or
# 137/143 after KILL/TERM) is a hang, never an expected failure.
not_timeout() {
    case "$3" in
    124 | 137 | 143) dump "$1"; fail "$1: $2 timed out or was killed (status $3)" ;;
    esac
}
# step TAG COMMAND...: must exit 0; a timeout is reported as one.
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
member_of() { # TAG PID PATH
    sed -n '/^0::/p' "/proc/$2/cgroup" > "$results/$1.member" || { dump "$1"; fail "$1: cannot read /proc/$2/cgroup"; }
    expect "$results/$1.member" "$1" "0::$3"
}

# observe RT TAG MODE PATH: runs bundle TAG, whose cgroup is PATH, to
# completion. For create/start, the waiting init's membership (TAG.member)
# and CPU files (TAG.values) are read after create has returned. Afterwards
# the cgroup and every process are gone.
observe() {
    rt=$1 tag=$2 mode=$3 path=$4
    observe_values=${5:-cpu_values}
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
        "$observe_values" "$path" > "$results/$tag.values"
        [ ! -s "$results/$tag.stdout" ] || { dump "$tag"; fail "$tag: workload ran before start"; }
        step "$tag" $rt start "$tag"
        wait_status "$rt" "$tag" stopped
        step "$tag" $rt delete "$tag"
        ;;
    esac
    gone "$tag" "$path"
    no_process_of "$tag"
}

# expect_failure RT NAME MODE MESSAGE: setup fails without a timeout, with
# MESSAGE (if any) in stderr, leaving no state, output, or process.
expect_failure() {
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

# value_case IMPL NAME CPU_JSON EXPECTED: create/start as root, recording the
# created group's CPU files in NAME-IMPL.values; EXPECTED holds for both.
value_case() {
    tag=$2-$1
    write_config "$tag" "$root" "$(cgroup_fields "$base/$tag" "$3")" "$true_args"
    observe "$rt" "$tag" created "$base/$tag"
    expect "$results/$tag.values" "$tag" "$4"
}
# failure_case IMPL NAME CPU_JSON MESSAGE: run and create both fail; MESSAGE
# is checked for this runtime, which must also remove its new cgroup.
failure_case() {
    tag=$2-$1
    write_config "$tag" "$root" "$(cgroup_fields "$base/$tag" "$3")" "$true_args"
    message=
    [ "$1" != swift ] || message=$4
    for mode in foreground created; do expect_failure "$rt" "$tag" "$mode" "$message"; done
    [ "$1" != swift ] || gone "$tag" "$base/$tag"
}
# outcome_case IMPL NAME CPU_JSON: extreme values the kernel judges. The
# outcome ("ok" and the CPU files, or "failed") is recorded in
# NAME-IMPL.values and must equal runc's.
outcome_case() {
    tag=$2-$1
    path=$base/$tag
    write_config "$tag" "$root" "$(cgroup_fields "$path" "$3")" "$true_args"
    if $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"; then
        { echo ok; cpu_values "$path"; } > "$results/$tag.values"
        step "$tag" $rt start "$tag"
        wait_status "$rt" "$tag" stopped
        step "$tag" $rt delete "$tag"
    else
        status=$?
        not_timeout "$tag" create "$status"
        echo failed > "$results/$tag.values"
        if $rt state "$tag" > /dev/null 2>&1; then dump "$tag"; fail "$tag: failed create left state"; fi
    fi
    [ "$1" != swift ] || gone "$tag" "$path"
    no_process_of "$tag"
    echo "$tag: $(tr '\n' ' ' < "$results/$tag.values")"
}

# Supplied groups: an existing empty cgroup with preset CPU files. This
# runtime keeps it at delete and after a failure; runc removes it.
# supplied PATH: creates it below the fixture root.
supplied() { mkdir "$cg$1"; }
# release_supplied IMPL PATH: after the container is gone, the group is
# empty (and still present for this runtime); then it is removed.
release_supplied() {
    if [ -d "$cg$2" ]; then
        unpopulated "$cg$2" || fail "$2: the supplied cgroup still has processes"
        rmdir "$cg$2"
    else
        [ "$1" = runc ] || fail "$2: the supplied cgroup was removed"
    fi
}

# throttle_check RT TAG MODE CPU_JSON THROTTLED: as uid 1000, the probe
# spends burn_ms of CPU time, and the group's cpu.stat is read once the burn
# is over: from foreground and detached runs while the probe waits for its
# release file, and from create/start after the container stopped (its
# group stays until delete). THROTTLED 1 requires the kernel's bandwidth
# counters to show throttling and the burn to have taken at least twice its
# CPU time; 0 is the unthrottled control, which proves the probe does the CPU
# work (usage_usec) without throttling. Elapsed time is only bounded above.
burn_ms=300
burn_reported() { grep -qE '^(burned|burn timeout|clock error)' "$results/$1.stdout" 2>/dev/null; }
wait_burn() { # TAG [RUNNER_PID]
    deadline=$(($(date +%s) + 50))
    until burn_reported "$1"; do
        if [ -n "${2:-}" ] && ! kill -0 "$2" 2>/dev/null; then
            burn_reported "$1" && break
            dump "$1"
            fail "$1: the container exited before the probe reported its burn"
        fi
        [ "$(date +%s)" -lt "$deadline" ] || { dump "$1"; fail "$1: timed out waiting for the probe's burn"; }
        sleep 0.05
    done
}
throttle_check() {
    rt=$1 tag=$2 mode=$3 limits=$4 throttled=$5
    path=$base/$tag
    release=/tmp/release-$tag
    write_config "$tag" "$user" "$(cgroup_fields "$path" "$limits")" '["/bin/cpu-probe", "burn", "'$burn_ms'", "'$release'"]'
    started=$(date +%s)
    case "$mode" in
    foreground)
        $rt run --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr" &
        runner=$!
        wait_burn "$tag" "$runner"
        cat "$cg$path/cpu.stat" > "$results/$tag.cpustat"
        : > "$rootfs$release"
        if wait "$runner"; then status=0; else status=$?; fi
        not_timeout "$tag" run "$status"
        [ "$status" = 0 ] || { dump "$tag"; fail "$tag: run failed with status $status"; }
        ;;
    detached)
        step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        wait_burn "$tag"
        cat "$cg$path/cpu.stat" > "$results/$tag.cpustat"
        : > "$rootfs$release"
        wait_status "$rt" "$tag" stopped
        step "$tag" $rt delete "$tag"
        ;;
    created)
        : > "$rootfs$release"
        step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        cpu_values "$path" > "$results/$tag.values"
        step "$tag" $rt start "$tag"
        wait_status "$rt" "$tag" stopped
        cat "$cg$path/cpu.stat" > "$results/$tag.cpustat"
        step "$tag" $rt delete "$tag"
        ;;
    esac
    elapsed=$(($(date +%s) - started))
    gone "$tag" "$path"
    no_process_of "$tag"
    [ "$elapsed" -lt 55 ] || { dump "$tag"; fail "$tag: took ${elapsed}s, indistinguishable from a timeout"; }
    line=$(grep '^burned ' "$results/$tag.stdout") || { dump "$tag"; fail "$tag: the probe did not complete its burn"; }
    grep -qx released "$results/$tag.stdout" || { dump "$tag"; fail "$tag: the probe was not released"; }
    cpu_us=$(echo "$line" | sed 's/.* cpu_us=\([0-9]*\) .*/\1/')
    wall_us=$(echo "$line" | sed 's/.* wall_us=\([0-9]*\) .*/\1/')
    usage=$(stat_of "$results/$tag.cpustat" usage_usec)
    periods=$(stat_of "$results/$tag.cpustat" nr_periods)
    throttles=$(stat_of "$results/$tag.cpustat" nr_throttled)
    throttled_us=$(stat_of "$results/$tag.cpustat" throttled_usec)
    [ -n "$usage" ] && [ -n "$periods" ] && [ -n "$throttles" ] && [ -n "$throttled_us" ] \
        || { dump "$tag"; fail "$tag: cpu.stat lacks the cpu controller's counters"; }
    # The work was really done: by the probe's clock and by the group's.
    [ "$cpu_us" -ge $((burn_ms * 1000)) ] || { dump "$tag"; fail "$tag: the probe used only ${cpu_us}us of CPU"; }
    [ "$usage" -ge $((burn_ms * 900)) ] || { dump "$tag"; fail "$tag: the group's usage_usec is only $usage"; }
    if [ "$throttled" = 1 ]; then
        [ "$periods" -ge 2 ] && [ "$throttles" -ge 2 ] && [ "$throttled_us" -gt 0 ] \
            || { dump "$tag"; fail "$tag: cpu.stat shows no throttling (nr_periods $periods, nr_throttled $throttles, throttled_usec $throttled_us)"; }
        # 20% of a CPU allows at most 0.2 * wall + one quota of CPU time.
        [ "$wall_us" -ge $((cpu_us * 2)) ] || { dump "$tag"; fail "$tag: ${cpu_us}us of CPU took only ${wall_us}us under a 20% quota"; }
    else
        [ "$throttles" = 0 ] && [ "$throttled_us" = 0 ] \
            || { dump "$tag"; fail "$tag: the unlimited control was throttled (nr_throttled $throttles)"; }
    fi
    echo "$tag: cpu_us=$cpu_us wall_us=$wall_us usage_usec=$usage nr_periods=$periods nr_throttled=$throttles throttled_usec=$throttled_us"
}

# Related resource fixtures reuse the lifecycle/error/cleanup helpers above.
# Sourcing in library mode sets up only a disposable rootfs and cgroup tree.
if [ "${CGROUP_FIXTURE_LIBRARY:-0}" = 1 ]; then return 0; fi

# An unrelated group with its own CPU settings and process, checked at the end.
mkdir "$fix/bystander"
echo 50 > "$fix/bystander/cpu.weight"
echo "30000 100000" > "$fix/bystander/cpu.max"
spawn_sleeper "$fix/bystander"
bystander=$sleeper

shared_checks() {
    impl=$1 rt=$2
    base=/$fixture/$impl
    for mode in foreground detached created; do
        # Membership and CPU files for root and uid 1000.
        for who in root user; do
            tag=member-$who-$mode-$impl
            case "$who" in root) who_json=$root uid=0 ;; user) who_json=$user uid=1000 ;; esac
            write_config "$tag" "$who_json" "$(cgroup_fields "$base/$tag" "$reference")" "$membership"
            observe "$rt" "$tag" "$mode" "$base/$tag"
            expect "$results/$tag.stdout" "$tag" "0::$base/$tag|$uid"
        done
        # Quota enforcement and its unthrottled control.
        throttle_check "$rt" "throttle-$mode-$impl" "$mode" '{"quota": 20000, "period": 100000}' 1
        throttle_check "$rt" "control-$mode-$impl" "$mode" '{"shares": 1024}' 0
    done
    # Every value is written before create returns.
    for who in root user; do
        expect "$results/member-$who-created-$impl.values" "member-$who-created-$impl" "$reference_values"
    done
    expect "$results/throttle-created-$impl.values" "throttle-created-$impl" "cpu.max 20000 100000"

    # Absent and zero values write nothing; $base already has cpu enabled,
    # so the files exist with their defaults.
    value_case "$impl" absent '{}' "$default_values"
    value_case "$impl" zero '{"shares": 0, "quota": 0, "period": 0}' "$default_values"
    # shares -> weight: runc's quadratic conversion, clamped at both ends.
    value_case "$impl" shares-2 '{"shares": 2}' "cpu.weight 1"
    value_case "$impl" shares-3 '{"shares": 3}' "cpu.weight 2"
    value_case "$impl" shares-1024 '{"shares": 1024}' "cpu.weight 100"
    value_case "$impl" shares-2048 '{"shares": 2048}' "cpu.weight 174"
    value_case "$impl" shares-262143 '{"shares": 262143}' "cpu.weight 10000"
    value_case "$impl" shares-262144 '{"shares": 262144}' "cpu.weight 10000"
    value_case "$impl" shares-max '{"shares": 18446744073709551615}' "cpu.weight 10000"
    # Quota and period: default period, unlimited, negative, and the
    # kernel's minimum and maximum.
    value_case "$impl" quota '{"quota": 30000}' "cpu.max 30000 100000"
    value_case "$impl" period '{"period": 50000}' "cpu.max max 50000"
    value_case "$impl" unlimited '{"quota": -1}' "cpu.max max 100000"
    value_case "$impl" negative '{"quota": -12345, "period": 250000}' "cpu.max max 250000"
    value_case "$impl" minimum '{"quota": 1000, "period": 1000}' "cpu.max 1000 1000"
    value_case "$impl" maximum '{"quota": 1000000, "period": 1000000}' "cpu.max 1000000 1000000"
    # Values the kernel refuses.
    failure_case "$impl" short-period '{"quota": 50000, "period": 999}' "cpu.max to 50000 999"
    failure_case "$impl" long-period '{"period": 1000001}' "cpu.max to max 1000001"
    failure_case "$impl" short-quota '{"quota": 999}' "cpu.max to 999 100000"
    # Extremes are passed through as runc passes them; the kernel decides.
    outcome_case "$impl" huge-quota '{"quota": 9223372036854775807, "period": 18446744073709551615}'
    outcome_case "$impl" huge-period '{"period": 18446744073709551615}'

    if [ "$has_burst" = 1 ]; then
        # The burst is written before cpu.max, against the group's current
        # (unlimited) quota; then cpu.max must admit it.
        value_case "$impl" burst '{"burst": 20000, "quota": 50000}' "cpu.max 50000 100000|cpu.max.burst 20000"
        value_case "$impl" burst-zero '{"burst": 0}' "cpu.max.burst 0|cpu.max max 100000"
        failure_case "$impl" burst-over-quota '{"burst": 80000, "quota": 50000}' "cpu.max to 50000 100000"
        outcome_case "$impl" huge-burst '{"burst": 18446744073709551615}'

        # A burst above a supplied group's current quota is refused (EINVAL)
        # and retried after cpu.max only with a configured quota.
        tag=retry-$impl
        path=/$fixture/$tag
        supplied "$path"
        echo "10000 100000" > "$cg$path/cpu.max"
        write_config "$tag" "$root" "$(cgroup_fields "$path" '{"burst": 20000, "quota": 50000}')" "$true_args"
        step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        cpu_values "$path" > "$results/$tag.values"
        step "$tag" $rt delete --force "$tag"
        expect "$results/$tag.values" "$tag" "cpu.max 50000 100000|cpu.max.burst 20000"
        release_supplied "$impl" "$path"
        for variant in absent zero; do
            tag=no-retry-$variant-$impl
            path=/$fixture/$tag
            supplied "$path"
            echo "10000 100000" > "$cg$path/cpu.max"
            case "$variant" in
            absent) limits='{"burst": 20000}' ;;
            zero) limits='{"burst": 20000, "quota": 0, "period": 100000}' ;;
            esac
            write_config "$tag" "$root" "$(cgroup_fields "$path" "$limits")" "$true_args"
            message=
            [ "$impl" != swift ] || message="cpu.max.burst to 20000"
            expect_failure "$rt" "$tag" created "$message"
            if [ -d "$cg$path" ]; then
                cpu_values "$path" > "$results/$tag.after"
                expect "$results/$tag.after" "$tag" "cpu.max 10000 100000|cpu.max.burst 0"
            fi
            release_supplied "$impl" "$path"
        done

        # burst 0 is a real write; shares 0 writes no weight.
        tag=zero-writes-$impl
        path=/$fixture/$tag
        supplied "$path"
        echo 50 > "$cg$path/cpu.weight"
        echo 5000 > "$cg$path/cpu.max.burst"
        write_config "$tag" "$root" "$(cgroup_fields "$path" '{"shares": 0, "burst": 0}')" "$true_args"
        step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        cpu_values "$path" > "$results/$tag.values"
        step "$tag" $rt delete --force "$tag"
        expect "$results/$tag.values" "$tag" "cpu.weight 50|cpu.max.burst 0"
        release_supplied "$impl" "$path"
    else
        failure_case "$impl" burst-missing '{"burst": 0}' "cpu.max.burst to 0"
    fi

    if [ "$has_idle" = 1 ]; then
        value_case "$impl" idle '{"idle": 1}' "cpu.idle 1"
        value_case "$impl" idle-shares '{"idle": 0, "shares": 1024}' "cpu.idle 0|cpu.weight 100"
        # An idle group refuses a weight: idle is written first.
        failure_case "$impl" idle-then-shares '{"idle": 1, "shares": 1024}' "cpu.weight to 100"
        failure_case "$impl" idle-two '{"idle": 2}' "cpu.idle to 2"
        failure_case "$impl" idle-negative '{"idle": -1}' "cpu.idle to -1"
        outcome_case "$impl" idle-min '{"idle": -9223372036854775808}'
        # idle 0 is a real write.
        tag=idle-zero-$impl
        path=/$fixture/$tag
        supplied "$path"
        echo 1 > "$cg$path/cpu.idle"
        write_config "$tag" "$root" "$(cgroup_fields "$path" '{"idle": 0}')" "$true_args"
        step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        cpu_values "$path" > "$results/$tag.values"
        step "$tag" $rt delete --force "$tag"
        expect "$results/$tag.values" "$tag" "cpu.idle 0"
        release_supplied "$impl" "$path"
    else
        failure_case "$impl" idle-missing '{"idle": 0}' "cpu.idle to 0"
    fi

    # A child of a populated domain is invalid here. Type checking refuses
    # it before controller enablement can reach cgroup.subtree_control.
    busy=/$fixture/busy-$impl
    mkdir "$cg$busy"
    spawn_sleeper "$cg$busy"
    tag=unavailable-$impl
    write_config "$tag" "$root" "$(cgroup_fields "$busy/ctr" '{"quota": 50000}')" "$true_args"
    message=
    [ "$impl" != swift ] || message="with domain controllers -- it is in an invalid state"
    expect_failure "$rt" "$tag" created "$message"
    [ "$impl" != swift ] || gone "$tag" "$busy/ctr"
    grep -qx "$sleeper" "$cg$busy/cgroup.procs" || fail "$tag: the populated parent's process was disturbed"
    stop_sleeper "$sleeper"
    wait_until "$busy to empty" unpopulated "$cg$busy"
    [ ! -d "$cg$busy/ctr" ] || rmdir "$cg$busy/ctr"
    rmdir "$cg$busy"

    # Below a threaded root, a new cgroup is "domain invalid" and the root
    # "domain threaded"; runc counts CPU settings as domain controllers and
    # refuses both.
    threaded=/$fixture/threaded-$impl
    mkdir "$cg$threaded" "$cg$threaded/anchor"
    echo threaded > "$cg$threaded/anchor/cgroup.type"
    mkdir "$cg$threaded/cpu"
    [ "$(cat "$cg$threaded/cpu/cgroup.type")" = "domain invalid" ] || fail "fixture: $threaded/cpu is not domain invalid"
    tag=thread-cpu-$impl
    write_config "$tag" "$user" "$(cgroup_fields "$threaded/cpu" '{"shares": 1024}')" "$true_args"
    message=
    [ "$impl" != swift ] || message="with domain controllers -- it is in"
    expect_failure "$rt" "$tag" foreground "$message"
    [ ! -d "$cg$threaded/cpu" ] || unpopulated "$cg$threaded/cpu" || fail "$tag: $threaded/cpu has processes"
    echo "$impl: membership, values, conversions, burst retry, idle, refused values, controller and threaded failures, and quota enforcement ok"
}

# compare_records: every record of this runtime equals runc's exactly.
compare_records() {
    for record in $(cd "$results" && ls -- *-swift.values); do
        theirs_record=$(echo "$record" | sed 's/-swift\./-runc./')
        [ -e "$results/$theirs_record" ] || fail "$theirs_record: missing"
        cmp -s "$results/$record" "$results/$theirs_record" && continue
        diff "$results/$theirs_record" "$results/$record" >&3 || :
        fail "$record differs from runc (diff: runc -> swift)"
    done
}

shared_checks swift "$ours"
# CPU-only groups need the cpu controller alone: memory and pids stay off.
[ "$(cat "$cg/$fixture/swift/cgroup.subtree_control")" = cpu ] \
    || fail "swift: $fixture/swift enables '$(cat "$cg/$fixture/swift/cgroup.subtree_control")', not only cpu"
if [ "$compare" = 1 ]; then
    shared_checks runc "$theirs"
    compare_records
fi

# This runtime only: realtime fields are rejected, leaving nothing.
base=/$fixture/swift
for unsupported in '"realtimeRuntime": 950000' '"realtimePeriod": 1000000'; do
    name=$(echo "$unsupported" | sed 's/^"\([A-Za-z]*\)".*/\1/')
    tag=unsupported-$name-swift
    write_config "$tag" "$root" "$(cgroup_fields "$base/$tag" "{\"shares\": 1024, $unsupported}")" "$true_args"
    expect_failure "$ours" "$tag" created "unsupported field(s): linux.resources.cpu.$name"
    gone "$tag" "$base/$tag"
done
echo "swift: only the cpu controller enabled; realtime fields rejected"

# The unrelated group is unchanged.
[ "$(cat "$fix/bystander/cpu.weight")" = 50 ] || fail "bystander: cpu.weight changed"
[ "$(cat "$fix/bystander/cpu.max")" = "30000 100000" ] || fail "bystander: cpu.max changed"
alive "$bystander" && grep -qx "$bystander" "$fix/bystander/cgroup.procs" || fail "bystander: its process was disturbed"

test -z "$(ls -A "$state_root")" || { ls -A "$state_root" >&3; fail "state left behind"; }
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "CPU integration checks passed (comparison: $comparison): cpu.weight/cpu.max/cpu.max.burst/cpu.idle at create for root and uid 1000 in foreground, detached, and create/start; absent, zero, shares, quota, period, unlimited, minimum and maximum values; burst order and retry; idle and shares; refused values, unavailable controller, and threaded subtree; quota throttling proved by cpu.stat against an unthrottled control; realtime fields rejected; unrelated group unchanged."
