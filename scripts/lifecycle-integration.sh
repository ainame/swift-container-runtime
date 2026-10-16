#!/bin/sh
# Persistent OCI lifecycle checks: create, start, state, kill, delete, list,
# and foreground/detached run. Run as root inside a disposable Linux VM.
# Requires a statically linked BusyBox (BUSYBOX, default /bin/busybox).
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/swift-container-runtime}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
# After pivot_root a created init's exe path may render relative to a
# detached mount, so executables are compared by device and inode.
runtime_file=$(stat -L -c %d:%i "$runtime")
exe_of() { stat -L -c %d:%i "/proc/$1/exe" 2>/dev/null; }
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-auto}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
state_root=$scratch/state
runc_root=$scratch/runc-state
# Every runtime command is bounded; a hang fails the check with status 124.
ours="timeout -k 2 30 $runtime --root $state_root"
theirs="timeout -k 2 30 runc --root $runc_root"

cleanup() {
    # Never leave containers or processes behind, even after a failed check.
    for id in $($ours list -q 2>/dev/null); do $ours delete --force "$id" >/dev/null 2>&1 || :; done
    if [ "$compare" = 1 ]; then
        for id in $($theirs list -q 2>/dev/null); do $theirs delete --force "$id" >/dev/null 2>&1 || :; done
    fi
    [ -z "${victim:-}" ] || kill "$victim" 2>/dev/null || :
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
    echo "lifecycle-integration: $*" >&2
    exit 1
}

if ldd "$busybox" >/dev/null 2>&1; then
    fail "BusyBox at $busybox must be statically linked"
fi
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

# Shared rootfs: a static BusyBox with relative applet links. Workloads
# report through /out, which is $rootfs/out on the host.
rootfs=$scratch/rootfs
out=$rootfs/out
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$rootfs/scripts" "$out"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
echo inside-rootfs > "$rootfs/marker"

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
  {"destination": "/dev/pts", "type": "devpts", "source": "devpts", "options": ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5"]}
]'

# write_config DIR ARGS_JSON: the rootfs path is absolute, so bundles hold
# only config.json and can be renamed or removed independently.
write_config() {
    mkdir -p "$1"
    cat > "$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": {"uid": 0, "gid": 0}, "args": $2, "env": ["PATH=/bin"], "cwd": "/"},
  "hostname": "lifebox",
  "mounts": $mounts,
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]},
  "annotations": {"org.example.test": "lifecycle"}
}
EOF
}
bundles=$scratch/bundles
# make_bundle NAME < SCRIPT: runs /bin/sh /scripts/NAME.sh.
make_bundle() {
    cat > "$rootfs/scripts/$1.sh"
    write_config "$bundles/$1" "[\"/bin/sh\", \"/scripts/$1.sh\"]"
}

make_bundle loop <<'EOF'
echo started >> /out/loop.starts
trap 'echo term > /out/loop.term; exit 7' TERM
while :; do sleep 1 & wait $!; done
EOF
make_bundle quick <<'EOF'
echo done > /out/quick.done
EOF
make_bundle tree <<'EOF'
sleep 1000 &
sleep 1000 &
echo ready > /out/tree.ready
wait
EOF
make_bundle exit42 <<'EOF'
exit 42
EOF
make_bundle hello <<'EOF'
echo hello-detached
exec sleep 1000
EOF

field() { # FIELD < STATE_JSON: works for both runtimes' pretty-printed JSON.
    sed -n "s/^ *\"$1\" *: *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p"
}
status_of() {
    # State probes have their own tight bound inside the polling deadline.
    case "$1" in
        "$ours") timeout -k 0.1 0.5 "$runtime" --root "$state_root" state "$2" ;;
        *) timeout -k 0.1 0.5 runc --root "$runc_root" state "$2" ;;
    esac 2>/dev/null | field status
}
pid_of() { $1 state "$2" | field pid; }
bundle_of() { $1 state "$2" | field bundle; }

# alive PID: exists and has not exited (zombies count as exited, because a
# detached init's reaper may be a PID 1 that never reaps).
alive() {
    stat_line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    state=${stat_line##*) }
    case "${state%% *}" in Z | X | x | '') return 1 ;; esac
}
dead() { if alive "$1"; then fail "process $1 is still running"; fi; }
wait_until() { # DESCRIPTION COMMAND...: polls for up to 10 seconds.
    description=$1
    shift
    deadline=$(($(date +%s) + 10))
    until "$@"; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for $description"
        sleep 0.05
    done
}
has_status() { test "$(status_of "$1" "$2")" = "$3"; }
wait_status() { wait_until "$2 to become $3" has_status "$1" "$2" "$3"; }
not_alive() { ! alive "$1"; }
wait_dead() { wait_until "process $1 to exit" not_alive "$1"; }
# expect_failure MESSAGE COMMAND...: the command must fail; a non-empty
# MESSAGE must appear in its stderr.
expect_failure() {
    message=$1
    shift
    if "$@" > "$scratch/stdout" 2> "$scratch/stderr"; then
        fail "expected failure: $*"
    else
        failure_status=$?
    fi
    case "$failure_status" in
        124|137|143) fail "command timed out or was killed instead of reporting an expected failure: $*" ;;
    esac
    if [ -n "$message" ] && ! grep -qF -- "$message" "$scratch/stderr"; then
        cat "$scratch/stderr" >&2
        fail "expected '$message' from: $*"
    fi
}
# Host PIDs in the PID namespace of PID $1.
namespace_members() {
    namespace=$(readlink "/proc/$1/ns/pid")
    for entry in /proc/[0-9]*; do
        if [ "$(readlink "$entry/ns/pid" 2>/dev/null)" = "$namespace" ]; then echo "${entry#/proc/}"; fi
    done
}
# Live processes still running this runtime's executable: launchers and
# created inits that have not executed a workload.
runtime_processes() {
    for entry in /proc/[0-9]*; do
        if [ "$(exe_of "${entry#/proc/}")" = "$runtime_file" ] && alive "${entry#/proc/}"; then
            echo "${entry#/proc/}"
        fi
    done
}
no_runtime_processes() {
    leftover=$(runtime_processes)
    [ -z "$leftover" ] || fail "leftover runtime processes: $leftover"
}
reset_out() { rm -rf "$out" && mkdir -p "$out"; }

shared_checks() {
    tag=$1 rt=$2
    reset_out

    # create prepares the init but does not run the workload.
    $rt create --bundle "$bundles/loop" "loop-$tag" < /dev/null > "$scratch/loop-$tag.log" 2>&1
    test "$(status_of "$rt" "loop-$tag")" = created
    pid=$(pid_of "$rt" "loop-$tag")
    test "$pid" -gt 1
    alive "$pid"
    $rt kill "loop-$tag" 0
    test ! -e "$out/loop.starts"
    # The init is PID 1 of its own PID namespace, inside the prepared rootfs,
    # with proc, /dev, and the hostname already set up.
    test "$(awk '/^NSpid:/ { print $NF }' "/proc/$pid/status")" = 1
    test "$(readlink "/proc/$pid/ns/pid")" != "$(readlink /proc/self/ns/pid)"
    test "$(cat "/proc/$pid/root/marker")" = inside-rootfs
    test -e "/proc/$pid/root/proc/1/stat"
    test -c "/proc/$pid/root/dev/null"
    test "$(nsenter --uts --target "$pid" hostname)" = lifebox
    test "$(bundle_of "$rt" "loop-$tag")" = "$bundles/loop"
    $rt state "loop-$tag" | grep -q '"org.example.test" *: *"lifecycle"'

    # start runs it exactly once: created -> running -> stopped.
    $rt start "loop-$tag"
    wait_until "loop-$tag to run" test -e "$out/loop.starts"
    test "$(status_of "$rt" "loop-$tag")" = running
    test "$(pid_of "$rt" "loop-$tag")" = "$pid"
    expect_failure "" $rt start "loop-$tag"
    test "$(wc -l < "$out/loop.starts")" = 1
    # A running container is not deleted without --force.
    expect_failure "" $rt delete "loop-$tag"
    test "$(status_of "$rt" "loop-$tag")" = running
    # TERM reaches the workload's handler.
    $rt kill "loop-$tag" TERM
    wait_status "$rt" "loop-$tag" stopped
    test "$(cat "$out/loop.term")" = term
    test "$(pid_of "$rt" "loop-$tag")" = 0
    dead "$pid"
    expect_failure "" $rt kill "loop-$tag" 0
    expect_failure "" $rt kill "loop-$tag" KILL
    expect_failure "" $rt start "loop-$tag"
    $rt delete "loop-$tag"
    expect_failure "" $rt state "loop-$tag"
    expect_failure "" $rt delete "loop-$tag"
    $rt delete --force "loop-$tag"

    # KILL stops a created container before its workload ever runs.
    reset_out
    $rt create --bundle "$bundles/loop" "created-kill-$tag" < /dev/null > /dev/null 2>&1
    pid=$(pid_of "$rt" "created-kill-$tag")
    $rt kill "created-kill-$tag" KILL
    wait_status "$rt" "created-kill-$tag" stopped
    dead "$pid"
    test ! -e "$out/loop.starts"
    $rt delete "created-kill-$tag"

    # Duplicate IDs fail and leave the first container intact; deleting a
    # created container kills its waiting init.
    $rt create --bundle "$bundles/loop" "dup-$tag" < /dev/null > /dev/null 2>&1
    pid=$(pid_of "$rt" "dup-$tag")
    expect_failure "" $rt create --bundle "$bundles/quick" "dup-$tag"
    test "$(status_of "$rt" "dup-$tag")" = created
    test "$(pid_of "$rt" "dup-$tag")" = "$pid"
    $rt delete "dup-$tag"
    dead "$pid"
    test ! -e "$out/loop.starts"

    # State reflects a workload that exits by itself.
    $rt create --bundle "$bundles/quick" "quick-$tag" < /dev/null > /dev/null 2>&1
    pid=$(pid_of "$rt" "quick-$tag")
    $rt start "quick-$tag"
    wait_status "$rt" "quick-$tag" stopped
    test "$(cat "$out/quick.done")" = "done"
    dead "$pid"
    $rt delete "quick-$tag"

    # delete --force leaves no process of the container's PID namespace.
    $rt create --bundle "$bundles/tree" "tree-$tag" < /dev/null > /dev/null 2>&1
    pid=$(pid_of "$rt" "tree-$tag")
    $rt start "tree-$tag"
    wait_until "tree-$tag children" test -e "$out/tree.ready"
    members=$(namespace_members "$pid")
    test "$(echo "$members" | wc -w)" -ge 3
    $rt delete --force "tree-$tag"
    for member in $members; do dead "$member"; done
    expect_failure "" $rt state "tree-$tag"

    # A detached run returns once started and keeps the state. The workload
    # inherits run's stdio.
    reset_out
    $rt run --detach --bundle "$bundles/hello" "detached-$tag" < /dev/null > "$scratch/detached-$tag.log" 2>&1
    test "$(status_of "$rt" "detached-$tag")" = running
    wait_until "detached-$tag output" grep -q hello-detached "$scratch/detached-$tag.log"
    pid=$(pid_of "$rt" "detached-$tag")
    $rt kill "detached-$tag" KILL
    wait_status "$rt" "detached-$tag" stopped
    dead "$pid"
    $rt delete "detached-$tag"

    # The bundle is not needed after create: rename it, or remove it.
    reset_out
    cp -R "$bundles/loop" "$bundles/moving"
    $rt create --bundle "$bundles/moving" "moved-$tag" < /dev/null > /dev/null 2>&1
    mv "$bundles/moving" "$bundles/moved"
    $rt start "moved-$tag"
    wait_status "$rt" "moved-$tag" running
    test "$(bundle_of "$rt" "moved-$tag")" = "$bundles/moving"
    $rt kill "moved-$tag" KILL
    wait_status "$rt" "moved-$tag" stopped
    $rt delete "moved-$tag"
    rm -rf "$bundles/moved"
    cp -R "$bundles/loop" "$bundles/removing"
    $rt create --bundle "$bundles/removing" "removed-$tag" < /dev/null > /dev/null 2>&1
    rm -rf "$bundles/removing"
    $rt start "removed-$tag"
    wait_status "$rt" "removed-$tag" running
    $rt delete --force "removed-$tag"
    expect_failure "" $rt state "removed-$tag"

    # A foreground run returns the workload status and removes its state.
    set +e
    $rt run --bundle "$bundles/exit42" "foreground-$tag" < /dev/null
    status=$?
    set -e
    test "$status" = 42
    expect_failure "" $rt state "foreground-$tag"
    test -z "$($rt list -q)"
    echo "$tag: create/start/state/kill/delete/run lifecycle ok"
}

source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swiftc -strict-memory-safety -warnings-as-errors -I "$source_root/Sources/LinuxAPI" \
    "$source_root/scripts/fixtures/start-client.swift" -o "$scratch/start-client"

shared_checks swift "$ours"
no_runtime_processes
test "$(stat -c %a "$state_root")" = 700
if [ "$compare" = 1 ]; then
    shared_checks runc "$theirs"
fi

# Runtime-specific behavior: exact messages, races, handshake failures,
# identity checks, and descriptor hygiene.
reset_out
$ours create --bundle "$bundles/loop" box < /dev/null > /dev/null 2>&1
pid=$(pid_of "$ours" box)
# Before start, the init is still this runtime's executable.
test "$(exe_of "$pid")" = "$runtime_file"
$ours state box > "$scratch/state.json"
test "$(field ociVersion < "$scratch/state.json")" = 1.0.2
test "$(field id < "$scratch/state.json")" = box
test "$(field rootfs < "$scratch/state.json")" = "$rootfs"
field created < "$scratch/state.json" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'
expect_failure "container box already exists" $ours create --bundle "$bundles/loop" box
expect_failure "container nothing does not exist" $ours state nothing
expect_failure "container nothing does not exist" $ours start nothing
expect_failure "container nothing does not exist" $ours kill nothing
expect_failure "container nothing does not exist" $ours delete nothing
$ours delete --force nothing

# A vanished start peer must not consume the created container. Stop init
# while queuing a complete request so the peer closes before init can inspect it.
$ours create --bundle "$bundles/loop" disconnected < /dev/null > /dev/null 2>&1
"$scratch/start-client" "$state_root/disconnected/start.sock"
test "$(status_of "$ours" disconnected)" = created
test ! -e "$out/loop.starts"
$ours kill disconnected STOP
"$scratch/start-client" "$state_root/disconnected/start.sock" --send-request
$ours kill disconnected CONT
test "$(status_of "$ours" disconnected)" = created
test ! -e "$out/loop.starts"
$ours start disconnected
wait_until "disconnected peer retry to run" test -e "$out/loop.starts"
test "$(wc -l < "$out/loop.starts")" = 1
$ours delete --force disconnected
reset_out

# Concurrent starts: exactly one succeeds and the workload runs once.
for n in 1 2 3 4; do
    $ours start box > /dev/null 2> "$scratch/start-$n.err" &
    eval "start_$n=\$!"
done
successes=0
for n in 1 2 3 4; do
    eval "job=\$start_$n"
    if wait "$job"; then
        successes=$((successes + 1))
    else
        grep -qF "cannot start container box in the running state" "$scratch/start-$n.err" \
            || { cat "$scratch/start-$n.err" >&2; fail "unexpected concurrent start failure"; }
    fi
done
test "$successes" = 1
wait_until "box to run" test -e "$out/loop.starts"
sleep 0.5
test "$(wc -l < "$out/loop.starts")" = 1
test "$(exe_of "$pid")" != "$runtime_file"
expect_failure "cannot start container box in the running state" $ours start box
expect_failure "cannot delete container box in the running state (use --force)" $ours delete box
expect_failure "unknown signal" $ours kill box NOPE

# list: runc's table columns, quiet IDs, and a JSON array.
$ours create --bundle "$bundles/loop" waiting < /dev/null > /dev/null 2>&1
$ours list > "$scratch/list"
head -n 1 "$scratch/list" | grep -Eq '^ID +PID +STATUS +BUNDLE +CREATED +OWNER$'
grep -Eq "^box +$pid +running +$bundles/loop +[0-9T:.-]+Z +root\$" "$scratch/list"
grep -Eq "^waiting +[0-9]+ +created +$bundles/loop +[0-9T:.-]+Z +root\$" "$scratch/list"
test "$($ours list -q | tr '\n' ' ')" = "box waiting "
$ours list --format json > "$scratch/list.json"
grep -q '^\[{' "$scratch/list.json"
grep -q '"id":"waiting"' "$scratch/list.json"
grep -q '"status":"running"' "$scratch/list.json"
$ours kill box TERM
wait_status "$ours" box stopped
expect_failure "cannot kill container box in the stopped state" $ours kill box KILL
expect_failure "cannot start container box in the stopped state" $ours start box
$ours delete box
$ours delete waiting
test -z "$(ls -A "$state_root")"

# Concurrent creates with one ID: exactly one wins.
for n in 1 2 3 4; do
    $ours create --bundle "$bundles/loop" race < /dev/null > /dev/null 2> "$scratch/create-$n.err" &
    eval "create_$n=\$!"
done
successes=0
for n in 1 2 3 4; do
    eval "job=\$create_$n"
    if wait "$job"; then
        successes=$((successes + 1))
    else
        grep -qF "container race already exists" "$scratch/create-$n.err" \
            || { cat "$scratch/create-$n.err" >&2; fail "unexpected concurrent create failure"; }
    fi
done
test "$successes" = 1
test "$(status_of "$ours" race)" = created
test "$(runtime_processes | wc -l)" = 1
$ours delete race
no_runtime_processes

# A relative bundle path is stored canonical and absolute.
(cd "$bundles" && $ours create --bundle ./loop/../loop relative < /dev/null > /dev/null 2>&1)
test "$(bundle_of "$ours" relative)" = "$bundles/loop"
$ours delete relative

# A missing executable fails create (as runc does) and leaves nothing.
write_config "$bundles/missing" '["/does/not/exist"]'
expect_failure "exec workload: No such file or directory" $ours create --bundle "$bundles/missing" missing
expect_failure "container missing does not exist" $ours state missing
set +e
$ours run --detach --bundle "$bundles/missing" missing-detached < /dev/null > /dev/null 2> "$scratch/stderr"
status=$?
set -e
test "$status" = 125
grep -qF "exec workload: No such file or directory" "$scratch/stderr"
test -z "$(ls -A "$state_root")"
no_runtime_processes

# An exec failure at start is reported by start (unlike runc, which cannot
# see it) and leaves a stopped container that deletes cleanly.
reset_out
printf '#!/bin/sh\necho ran > /out/vanish.ran\n' > "$rootfs/scripts/vanish"
chmod 755 "$rootfs/scripts/vanish"
write_config "$bundles/vanish" '["/scripts/vanish"]'
$ours create --bundle "$bundles/vanish" vanish < /dev/null > /dev/null 2>&1
pid=$(pid_of "$ours" vanish)
rm "$rootfs/scripts/vanish"
expect_failure "exec workload: No such file or directory" $ours start vanish
wait_status "$ours" vanish stopped
dead "$pid"
test ! -e "$out/vanish.ran"
$ours delete vanish
no_runtime_processes

# Inherited and runtime descriptors never reach the workload: fd 9 is a
# host directory; the lock, state directory, and start socket are internal.
cat > "$rootfs/scripts/fds.sh" <<'EOF'
set -e
test ! -e /proc/$$/fd/9
exec /bin/ls -l /proc/self/fd
EOF
write_config "$bundles/fds" '["/bin/sh", "/scripts/fds.sh"]'
$ours create --bundle "$bundles/fds" fds < /dev/null > "$scratch/fds.out" 2>&1 9< "$scratch"
$ours start fds
wait_status "$ours" fds stopped
awk '
    $(NF - 1) == "->" && $(NF - 2) ~ /^[0-9]+$/ {
        fd = $(NF - 2); target = $NF
        if (fd + 0 > 2 && target != "/proc/1/fd") { print "leaked descriptor: " $0; bad = 1 }
        entries++
    }
    END { if (entries < 3) { print "unexpected descriptor listing"; bad = 1 }; exit bad }
' "$scratch/fds.out" >&2
$ours delete fds

# A foreground run is visible to other commands while it runs; kill from
# another process reaches it, and its state is removed afterwards.
reset_out
$ours run --bundle "$bundles/loop" foreground-live < /dev/null > /dev/null 2>&1 &
job=$!
wait_until "foreground-live to run" test -e "$out/loop.starts"
test "$(status_of "$ours" foreground-live)" = running
expect_failure "cannot delete container foreground-live in the running state" $ours delete foreground-live
$ours kill foreground-live TERM
set +e
wait "$job"
status=$?
set -e
test "$status" = 7
expect_failure "container foreground-live does not exist" $ours state foreground-live

# Killing the foreground runtime still kills its container (parent-death
# signal chain); the state then reads stopped and deletes.
reset_out
"$runtime" --root "$state_root" run --bundle "$bundles/loop" orphan < /dev/null > /dev/null 2>&1 &
job=$!
wait_until "orphan to run" test -e "$out/loop.starts"
pid=$(pid_of "$ours" orphan)
kill -KILL "$job"
wait "$job" 2>/dev/null || :
wait_dead "$pid"
wait_status "$ours" orphan stopped
$ours delete orphan

# Stale or tampered state never signals an unrelated process.
$ours run --detach --bundle "$bundles/loop" stale < /dev/null > /dev/null 2>&1
pid=$(pid_of "$ours" stale)
$ours kill stale KILL
wait_status "$ours" stale stopped
record=$state_root/stale/state.json
init_start=$(sed -n 's/.*"startTime":\([0-9]*\).*/\1/p' "$record")
test -n "$init_start"
sleep 1000 &
victim=$!
victim_start=$(awk '{ print $22 }' "/proc/$victim/stat")
retarget() { sed -E -i "s/\"pid\":[0-9-]+/\"pid\":$1/; s/\"startTime\":[0-9]+/\"startTime\":$2/; s/\"pidNamespace\":(true|false)/\"pidNamespace\":${3:-true}/" "$record"; }
# Disable the namespace guard so this proves start-time verification itself.
retarget "$victim" "$((victim_start + 1))" false
test "$(status_of "$ours" stale)" = stopped
expect_failure "cannot kill container stale in the stopped state" $ours kill stale KILL
# A forged matching identity still names a process outside the container's
# own PID namespace.
retarget "$victim" "$victim_start"
test "$(status_of "$ours" stale)" = stopped
expect_failure "cannot kill container stale in the stopped state" $ours kill stale KILL
# This shell, and PID 1, are never targets.
retarget "$$" "$(awk '{ print $22 }' "/proc/$$/stat")"
expect_failure "cannot kill container stale in the stopped state" $ours kill stale KILL
retarget 1 "$init_start"
expect_failure "state of container stale is corrupt: invalid init PID 1" $ours kill stale KILL
expect_failure "state of container stale is corrupt" $ours state stale
$ours list > /dev/null 2> "$scratch/stderr"
grep -qF "state of container stale is corrupt" "$scratch/stderr"
retarget "$victim" "$init_start"
$ours delete --force stale
alive "$victim"
kill "$victim"
victim=
dead "$pid"

test -z "$(ls -A "$state_root")"
no_runtime_processes

comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Lifecycle integration checks passed (comparison: $comparison): create without exec, PID 1 and prepared rootfs, start once (also concurrently), state transitions, kill TERM/KILL, delete and --force cleanup, duplicate IDs (also concurrently), detached and foreground run, bundle rename/removal, create/start failure cleanup, descriptor isolation, parent-death cleanup, PID-reuse and tampered-state protection."
