#!/bin/sh
# Process credential checks: process.user uid/gid/additionalGids/umask and
# process.noNewPrivileges, observed from inside the real workload in
# foreground run, detached run, and create/start, compared with runc.
# Run as root inside a disposable Linux VM. Requires a statically linked
# BusyBox (BUSYBOX, default /bin/busybox) and util-linux setpriv.
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/swift-container-runtime}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-auto}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
state_root=$scratch/state
runc_root=$scratch/runc-state
results=$scratch/results
ours="timeout -k 2 30 $runtime --root $state_root"
theirs="timeout -k 2 30 runc --root $runc_root"

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
    echo "credentials-integration: $*" >&2
    exit 1
}

if ldd "$busybox" >/dev/null 2>&1; then
    fail "BusyBox at $busybox must be statically linked"
fi
command -v setpriv >/dev/null || fail "setpriv (util-linux) is required"
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

# Rootfs: static BusyBox. /out is world-writable so non-root workloads can
# report; /secret is readable only through group 2000; /bin/busybox-suid is
# a setuid-root copy for the no_new_privs check.
rootfs=$scratch/rootfs
out=$rootfs/out
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$rootfs/scripts" "$out" "$results"
chmod 1777 "$out"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
echo group-secret > "$rootfs/secret"
chown 0:2000 "$rootfs/secret"
chmod 0640 "$rootfs/secret"
# BusyBox runs as the multiplexer when argv[0]'s basename starts with
# "busybox"; confirm that this copy dispatches its first argument.
cp "$busybox" "$rootfs/bin/busybox-suid"
chmod 4755 "$rootfs/bin/busybox-suid"
test "$("$rootfs/bin/busybox-suid" echo dispatched)" = dispatched \
    || fail "busybox-suid does not dispatch applets"

# The probe records what the kernel reports for the workload itself (the
# shell is PID 1), the owner and mode of a file it creates, whether group
# membership grants /secret, the effective uid gained through a setuid-root
# executable, and whether it can reopen its stdout.
cat > "$rootfs/scripts/probe.sh" <<'EOF'
{
    while IFS= read -r line; do
        case "$line" in Uid:* | Gid:* | Groups:* | NoNewPrivs:* | Umask:* | Cap*) echo "$line" ;; esac
    done < /proc/$$/status
    if cat /secret > /dev/null 2>&1; then echo secret=readable; else echo secret=denied; fi
    echo "suid-euid=$(/bin/busybox-suid cat /proc/self/status | awk '/^Uid:/ { print $3 }')"
} > /out/probe.tmp
: > /out/probe.file
echo via-dev-stdout >> /dev/stdout
mv /out/probe.tmp /out/probe.status
EOF
cat > "$rootfs/scripts/loop.sh" <<'EOF'
echo started > /out/loop.started
while :; do sleep 1 & wait $!; done
EOF
cat > "$rootfs/scripts/fds.sh" <<'EOF'
set -e
test ! -e /proc/$$/fd/9
exec /bin/ls -l /proc/self/fd
EOF
printf '#!/bin/sh\necho ran > /out/rootonly.ran\n' > "$rootfs/scripts/rootonly"
chmod 0700 "$rootfs/scripts/rootonly"

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
  {"destination": "/dev/pts", "type": "devpts", "source": "devpts", "options": ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5"]}
]'
bundles=$scratch/bundles
# write_config NAME USER_JSON NO_NEW_PRIVILEGES ARGS_JSON
write_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": $2, "noNewPrivileges": $3, "args": $4, "env": ["PATH=/bin"], "cwd": "/"},
  "hostname": "credbox",
  "mounts": $mounts,
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}
}
EOF
}
probe='["/bin/sh", "/scripts/probe.sh"]'
# A: everything configured. B: a plain non-root user (no groups field, no
# umask). C: root with an explicitly empty group list.
write_config user-all '{"uid": 1000, "gid": 1000, "additionalGids": [3000, 2000], "umask": 63}' true "$probe"
write_config user-plain '{"uid": 1000, "gid": 1000}' false "$probe"
write_config root-nogroups '{"uid": 0, "gid": 0, "additionalGids": []}' false "$probe"
write_config user-loop '{"uid": 1000, "gid": 1000, "additionalGids": [2000]}' true '["/bin/sh", "/scripts/loop.sh"]'
write_config exec-loop '{"uid": 1000, "gid": 1000, "additionalGids": [2000]}' false '["/bin/sh", "/scripts/loop.sh"]'
write_config user-fds '{"uid": 1000, "gid": 1000}' true '["/bin/sh", "/scripts/fds.sh"]'
write_config user-rootonly '{"uid": 1000, "gid": 1000}' false '["/scripts/rootonly"]'
write_config root-rootonly '{"uid": 0, "gid": 0}' false '["/scripts/rootonly"]'

field() { sed -n "s/^ *\"$1\" *: *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p"; }
status_of() { $1 state "$2" 2>/dev/null | field status; }
pid_of() { $1 state "$2" | field pid; }
alive() {
    stat_line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    state=${stat_line##*) }
    case "${state%% *}" in Z | X | x | '') return 1 ;; esac
}
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
# Credential lines of /proc/PID/status, whitespace-normalized.
identity_of() { awk '/^(Uid|Gid|Groups|NoNewPrivs|Umask):/ { $1 = $1; print }' "/proc/$1/status"; }

# The caller has supplementary groups and umask 0077, so the checks show
# that neither leaks into the workload.
as_caller() { setpriv --groups 4242,4343 -- sh -c 'umask 0077; exec "$@"' sh "$@"; }

# dump TAG: everything recorded for TAG, printed before a failure.
dump() {
    for kind in stderr stdout status init file; do
        if [ -e "$results/$1.$kind" ]; then
            echo "--- $1.$kind" >&2
            cat "$results/$1.$kind" >&2
        fi
    done
}
# runtime_step TAG COMMAND...: the command must succeed; otherwise dump TAG.
runtime_step() {
    step_tag=$1
    shift
    if ! "$@"; then
        dump "$step_tag"
        fail "$step_tag: command failed: $*"
    fi
}

# observe RT TAG BUNDLE MODE: runs the probe and keeps its record as
# $results/TAG.status (normalized), TAG.file (owner:group:mode), and
# TAG.stdout. For create/start, TAG.init holds the created init's credentials.
# Stdout and stderr are regular files, which both runtimes chown to the
# workload uid, so the probe can reopen /dev/stdout.
observe() {
    rt=$1 tag=$2 name=$3 mode=$4
    rm -f "$out/probe.status" "$out/probe.file"
    case "$mode" in
    foreground)
        runtime_step "$tag" as_caller $rt run --bundle "$bundles/$name" "$tag" \
            < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        ;;
    detached)
        runtime_step "$tag" as_caller $rt run --detach --bundle "$bundles/$name" "$tag" \
            < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        wait_status "$rt" "$tag" stopped
        runtime_step "$tag" $rt delete "$tag"
        ;;
    created)
        # create returns once the init is waiting for start, with its
        # credentials already in force.
        runtime_step "$tag" as_caller $rt create --bundle "$bundles/$name" "$tag" \
            < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        created_status=$(status_of "$rt" "$tag")
        [ "$created_status" = created ] || { dump "$tag"; fail "$tag: status after create is '$created_status'"; }
        pid=$(pid_of "$rt" "$tag")
        identity_of "$pid" > "$results/$tag.init"
        echo "init exe: $(readlink "/proc/$pid/exe" 2>&1)" >> "$results/$tag.init.raw"
        cat "/proc/$pid/status" >> "$results/$tag.init.raw" 2>&1 || :
        [ ! -e "$out/probe.status" ] || { dump "$tag"; fail "$tag: workload ran before start"; }
        runtime_step "$tag" $rt start "$tag"
        wait_status "$rt" "$tag" stopped
        runtime_step "$tag" $rt delete "$tag"
        ;;
    esac
    test -e "$out/probe.status" || { dump "$tag"; fail "$tag did not run the probe"; }
    awk '{ $1 = $1; print }' "$out/probe.status" > "$results/$tag.status"
    stat -c %u:%g:%a "$out/probe.file" > "$results/$tag.file"
}

# expect TAG LINE...: each line occurs in the probe record.
expect() {
    tag=$1
    shift
    for line in "$@"; do
        grep -qxF -- "$line" "$results/$tag.status" || { dump "$tag"; fail "$tag: expected '$line'"; }
    done
}
# expect_init TAG LINE...: each line occurs in the created init's credentials.
expect_init() {
    tag=$1
    shift
    for line in "$@"; do
        grep -qxF -- "$line" "$results/$tag.init" || {
            dump "$tag"
            echo "--- $tag.init.raw" >&2
            cat "$results/$tag.init.raw" >&2
            fail "$tag: created init lacks '$line'"
        }
    done
}
# Compared fields. These configs have no process.capabilities, so runc and
# this runtime both leave the inherited sets (root keeps them; for non-root,
# setuid clears permitted, effective, and ambient but not bounding or
# inheritable), and the Cap lines must match too.
# capabilities-integration.sh covers configured sets.
implemented_fields() {
    grep -E '^(Uid|Gid|Groups|NoNewPrivs|Umask|Cap[A-Za-z]+):|^secret=|^suid-euid=' "$1"
}

# exec_identity RT ID [OPTION...]: credential lines the exec process sees
# for itself. The command must succeed.
exec_identity() {
    exec_rt=$1 exec_id=$2
    shift 2
    $exec_rt exec "$@" "$exec_id" /bin/awk '/^(Uid|Gid|Groups|NoNewPrivs):/ { $1 = $1; print }' /proc/self/status \
        < /dev/null 2> "$results/exec.err" || { cat "$results/exec.err" >&2; fail "exec $* failed"; }
}
# exec_fails RT ID EXEC_ARGUMENT...: the exec must fail with no stdout and
# must not time out or be killed. ID names the container for the reader.
exec_fails() {
    exec_rt=$1 exec_id=$2
    shift 2
    set +e
    $exec_rt exec "$@" < /dev/null > "$results/exec.out" 2> "$results/exec.err"
    exec_status=$?
    set -e
    case "$exec_status" in
    0) fail "exec $* succeeded" ;;
    124 | 137 | 143) fail "exec $* timed out or was killed (status $exec_status)" ;;
    esac
    test ! -s "$results/exec.out" || fail "failed exec $* printed: $(cat "$results/exec.out")"
}

# same LABEL EXPECTED ACTUAL: fails with both values and the last exec's
# stderr when they differ.
same() {
    [ "$2" = "$3" ] && return 0
    printf '%s\n--- expected\n%s\n--- actual\n%s\n--- exec stderr\n' "$1" "$2" "$3" >&2
    cat "$results/exec.err" >&2 2>/dev/null || :
    fail "$1: unexpected exec identity"
}

# exec_checks IMPL RT: --additional-gids appends to the configured groups,
# --no-new-privs sets the flag, absent flags keep the process settings,
# --process ignores both, and nothing changes the init.
exec_checks() {
    impl=$1 rt=$2
    id=exec-$impl
    rm -f "$out/loop.started"
    runtime_step "$id" $rt run --detach --bundle "$bundles/exec-loop" "$id" < /dev/null > /dev/null 2>&1
    wait_until "$id to run" test -e "$out/loop.started"
    pid=$(pid_of "$rt" "$id")
    identity_of "$pid" > "$results/$id.before"
    expected="Uid: 1000 1000 1000 1000
Gid: 1000 1000 1000 1000
Groups: 2000
NoNewPrivs: 0"
    same "$impl: exec without overrides" "$expected" "$(exec_identity "$rt" "$id")"
    expected="Uid: 1000 1000 1000 1000
Gid: 1000 1000 1000 1000
Groups: 2000 3000 4000
NoNewPrivs: 1"
    # runc refuses mixing -g and --additional-gids in one invocation, so
    # each spelling is repeated on its own.
    same "$impl: exec with appended -g groups and no_new_privs" "$expected" "$(exec_identity "$rt" "$id" -g 4000 -g 3000 --no-new-privs)"
    same "$impl: exec with appended --additional-gids groups and no_new_privs" "$expected" "$(exec_identity "$rt" "$id" --additional-gids 4000 --additional-gids 3000 --no-new-privs)"
    # runc 1.4.0-0ubuntu1 appends a single supplied group twice (-g 3000 or
    # --additional-gids 3000, with or without -u, gives "2000 3000 3000"),
    # while two distinct groups are appended once each. Compare the user
    # override with two groups; check the single-group case strictly for ours.
    expected="Uid: 0 0 0 0
Gid: 5 5 5 5
Groups: 2000 3000 4000
NoNewPrivs: 1"
    same "$impl: exec with numeric user, groups, and no_new_privs" "$expected" "$(exec_identity "$rt" "$id" -u 0:5 -g 3000 -g 4000 --no-new-privs)"
    if [ "$impl" = swift ]; then
        expected="Uid: 0 0 0 0
Gid: 5 5 5 5
Groups: 2000 3000
NoNewPrivs: 1"
        same "$impl: exec with numeric user and one group" "$expected" "$(exec_identity "$rt" "$id" -u 0:5 -g 3000 --no-new-privs)"
    fi
    # A process file is authoritative: its own empty group list and unset
    # no_new_privs win over the flags.
    cat > "$scratch/exec-process-$impl.json" <<'EOF'
{"terminal": false, "user": {"uid": 1000, "gid": 1000}, "cwd": "/", "env": ["PATH=/bin"],
 "args": ["/bin/awk", "/^(Groups|NoNewPrivs):/ { $1 = $1; print }", "/proc/self/status"]}
EOF
    expected="Groups:
NoNewPrivs: 0"
    same "$impl: --process did not override the group and no_new_privs flags" "$expected" "$($rt exec -p "$scratch/exec-process-$impl.json" -g 3000 --no-new-privs "$id" < /dev/null 2> "$results/exec.err")"
    # A failed exec with overrides runs nothing and leaves the init alone.
    exec_fails "$rt" "$id" -g 3000 --no-new-privs "$id" /does/not/exist
    test "$(status_of "$rt" "$id")" = running || fail "$impl: failed exec stopped the init"
    identity_of "$pid" | cmp -s - "$results/$id.before" || fail "$impl: exec changed the init's credentials"
    runtime_step "$id" $rt delete --force "$id"
}

shared_checks() {
    impl=$1 rt=$2
    for mode in foreground detached created; do
        tag=all-$mode-$impl
        observe "$rt" "$tag" user-all "$mode"
        expect "$tag" "Uid: 1000 1000 1000 1000" "Gid: 1000 1000 1000 1000" "Groups: 2000 3000" \
            "NoNewPrivs: 1" "Umask: 0077" "CapPrm: 0000000000000000" "CapEff: 0000000000000000" \
            "CapAmb: 0000000000000000" secret=readable suid-euid=1000
        test "$(cat "$results/$tag.file")" = 1000:1000:600 || { dump "$tag"; fail "$tag: created file owner/mode"; }
        test "$(cat "$results/$tag.stdout")" = via-dev-stdout || { dump "$tag"; fail "$tag: /dev/stdout reopen"; }

        tag=plain-$mode-$impl
        observe "$rt" "$tag" user-plain "$mode"
        # Groups are cleared and the umask is runc's default, not the caller's.
        expect "$tag" "Uid: 1000 1000 1000 1000" "Gid: 1000 1000 1000 1000" "Groups:" \
            "NoNewPrivs: 0" "Umask: 0022" "CapEff: 0000000000000000" secret=denied
        # Without no_new_privs the setuid bit may or may not take effect here
        # (nosuid mount, BusyBox privilege drop), but the probe must report one.
        grep -qxE 'suid-euid=(0|1000)' "$results/$tag.status" \
            || { dump "$tag"; fail "$tag: no effective uid from busybox-suid"; }
        test "$(cat "$results/$tag.file")" = 1000:1000:644 || { dump "$tag"; fail "$tag: created file owner/mode"; }

        tag=root-$mode-$impl
        observe "$rt" "$tag" root-nogroups "$mode"
        expect "$tag" "Uid: 0 0 0 0" "Gid: 0 0 0 0" "Groups:" "NoNewPrivs: 0" "Umask: 0022" secret=readable suid-euid=0
        test "$(cat "$results/$tag.file")" = 0:0:644 || { dump "$tag"; fail "$tag: created file owner/mode"; }
    done
    # The waiting inits already hold every implemented setting.
    expect_init "all-created-$impl" "Uid: 1000 1000 1000 1000" "Gid: 1000 1000 1000 1000" \
        "Groups: 2000 3000" "NoNewPrivs: 1" "Umask: 0077"
    expect_init "plain-created-$impl" "Uid: 1000 1000 1000 1000" "Gid: 1000 1000 1000 1000" \
        "Groups:" "NoNewPrivs: 0" "Umask: 0022"
    expect_init "root-created-$impl" "Uid: 0 0 0 0" "Gid: 0 0 0 0" "Groups:" "NoNewPrivs: 0" "Umask: 0022"

    # A root-only executable is not "found" for a non-root user: create and
    # run fail before readiness, leave no state, and never run it.
    rm -f "$out/rootonly.ran"
    if $rt create --bundle "$bundles/user-rootonly" "rootonly-$impl" < /dev/null > /dev/null 2> "$results/rootonly-$impl.err"; then
        fail "$impl: non-root create of a root-only executable succeeded"
    fi
    if $rt state "rootonly-$impl" > /dev/null 2>&1; then fail "$impl: failed create left state"; fi
    if $rt run --bundle "$bundles/user-rootonly" "rootonly-run-$impl" < /dev/null > /dev/null 2>> "$results/rootonly-$impl.err"; then
        fail "$impl: non-root run of a root-only executable succeeded"
    fi
    test ! -e "$out/rootonly.ran"
    $rt run --bundle "$bundles/root-rootonly" "rootonly-root-$impl" < /dev/null > /dev/null 2>&1
    test "$(cat "$out/rootonly.ran")" = ran
    exec_checks "$impl" "$rt"
    echo "$impl: uid/gid, additionalGids, umask, no_new_privs, stdio, executable lookup, exec overrides ok"
}

shared_checks swift "$ours"
if [ "$compare" = 1 ]; then
    shared_checks runc "$theirs"
    # The workloads saw identical credentials, umask, no_new_privs, group
    # access, setuid result, and inherited capability sets under both
    # runtimes.
    for mode in foreground detached created; do
        for config in all plain root; do
            implemented_fields "$results/$config-$mode-swift.status" > "$results/$config-$mode-swift.compared"
            implemented_fields "$results/$config-$mode-runc.status" > "$results/$config-$mode-runc.compared"
            if ! cmp -s "$results/$config-$mode-swift.compared" "$results/$config-$mode-runc.compared"; then
                diff "$results/$config-$mode-runc.compared" "$results/$config-$mode-swift.compared" >&2 || :
                fail "$config $mode credentials differ from runc (diff: runc -> swift)"
            fi
            if ! cmp -s "$results/$config-$mode-swift.file" "$results/$config-$mode-runc.file"; then
                diff "$results/$config-$mode-runc.file" "$results/$config-$mode-swift.file" >&2 || :
                fail "$config $mode created file differs from runc"
            fi
        done
    done
    # The created inits' identity files hold only the implemented fields.
    for config in all plain root; do
        if ! cmp -s "$results/$config-created-swift.init" "$results/$config-created-runc.init"; then
            diff "$results/$config-created-runc.init" "$results/$config-created-swift.init" >&2 || :
            fail "$config created init credentials differ from runc"
        fi
    done
fi
if grep -qxF suid-euid=0 "$results/plain-foreground-swift.status"; then
    nnp_note="setuid elevation observed without it and blocked with it"
else
    nnp_note="setuid elevation not observable here (nosuid mount or BusyBox privilege drop); the NoNewPrivs flag was checked"
fi

# Exact diagnostics for denied or missing executables.
grep -qF "exec workload: Permission denied" "$results/rootonly-swift.err" \
    || { cat "$results/rootonly-swift.err" >&2; fail "missing actionable permission error"; }
test "$(grep -c "exec workload: Permission denied" "$results/rootonly-swift.err")" = 2

# A non-root foreground run still dies with the runtime: the parent-death
# signal that setuid cleared was armed again.
rm -f "$out/loop.started"
"$runtime" --root "$state_root" run --bundle "$bundles/user-loop" orphan < /dev/null > /dev/null 2>&1 &
job=$!
wait_until "orphan to run" test -e "$out/loop.started"
pid=$(pid_of "$ours" orphan)
identity_of "$pid" | grep -qxF "Uid: 1000 1000 1000 1000"
kill -KILL "$job"
wait "$job" 2>/dev/null || :
wait_dead "$pid"
wait_status "$ours" orphan stopped
$ours delete orphan

# A detached non-root container outlives the command that started it.
rm -f "$out/loop.started"
$ours run --detach --bundle "$bundles/user-loop" independent < /dev/null > /dev/null 2>&1
wait_until "independent to run" test -e "$out/loop.started"
pid=$(pid_of "$ours" independent)
sleep 0.5
alive "$pid"
test "$(status_of "$ours" independent)" = running
identity_of "$pid" | grep -qxF "NoNewPrivs: 1"
$ours delete --force independent

# No runtime descriptor reaches a non-root workload, in either mode.
check_fds() {
    awk '
        $(NF - 1) == "->" && $(NF - 2) ~ /^[0-9]+$/ {
            fd = $(NF - 2); target = $NF
            if (fd + 0 > 2 && target != "/proc/1/fd") { print "leaked descriptor: " $0; bad = 1 }
            entries++
        }
        END { if (entries < 3) { print "unexpected descriptor listing"; bad = 1 }; exit bad }
    ' "$1" >&2
}
$ours run --bundle "$bundles/user-fds" fds-run < /dev/null 9< "$scratch" > "$results/fds-run" 2>&1
check_fds "$results/fds-run"
$ours create --bundle "$bundles/user-fds" fds-created < /dev/null 9< "$scratch" > "$results/fds-created" 2>&1
$ours start fds-created
wait_status "$ours" fds-created stopped
check_fds "$results/fds-created"
$ours delete fds-created

# Invalid group values fail before any process starts.
$ours run --detach --bundle "$bundles/exec-loop" exec-invalid < /dev/null > /dev/null 2>&1
for value in 4294967295 -1 4294967296 x; do
    exec_fails "$ours" exec-invalid -g "$value" exec-invalid /bin/true
done
exec_fails "$ours" exec-invalid -g 4294967295 exec-invalid /bin/true
grep -qF "'unchanged'" "$results/exec.err" || fail "unexpected diagnostic: $(cat "$results/exec.err")"
test "$(status_of "$ours" exec-invalid)" = running
$ours delete --force exec-invalid

test -z "$(ls -A "$state_root")"
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Credential integration checks passed (comparison: $comparison): uid/gid, additionalGids (also cleared), umask (default 0022), no_new_privs ($nnp_note), permitted/effective/ambient capabilities dropped for non-root and inherited sets matching runc, stdio reopen, credentials before start, root-only executable lookup, non-root parent-death cleanup, detached lifetime, descriptor isolation, exec --additional-gids/--no-new-privs/--user and --process precedence."
