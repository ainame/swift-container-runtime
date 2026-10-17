#!/bin/sh
# process.capabilities checks: the five sets as /proc/<pid>/status reports
# them for the real workload (and for a created init waiting for start), and
# operations each capability allows or denies, for an absent object, an
# explicitly empty one, and configured root and non-root sets, in foreground
# run, detached run, and create/start, compared with runc.
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
    echo "capabilities-integration: $*" >&2
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
last_cap=$(cat /proc/sys/kernel/cap_last_cap)

# Rootfs: static BusyBox. /out is world-writable so every workload can
# report; /private belongs to an unrelated uid with mode 0600, so reading
# it needs CAP_DAC_OVERRIDE.
rootfs=$scratch/rootfs
out=$rootfs/out
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$rootfs/scripts" "$out" "$results"
chmod 1777 "$out"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
echo private > "$rootfs/private"
chown 4321:4321 "$rootfs/private"
chmod 0600 "$rootfs/private"

# The probe records the workload's own capability sets (the shell is PID 1)
# and the outcome of one operation per representative capability:
# CAP_CHOWN (give away a file it created), CAP_SYS_ADMIN (sethostname in
# its UTS namespace), and CAP_DAC_OVERRIDE (read /private).
cat > "$rootfs/scripts/probe.sh" <<'EOF'
{
    while IFS= read -r line; do
        case "$line" in Uid:* | NoNewPrivs:* | Cap*) echo "$line" ;; esac
    done < /proc/$$/status
    : > /out/chown.target
    if chown 1234 /out/chown.target 2>/dev/null; then echo chown=allowed; else echo chown=denied; fi
    if hostname changed 2>/dev/null; then echo sethostname=allowed; else echo sethostname=denied; fi
    if cat /private > /dev/null 2>&1; then echo dac-override=allowed; else echo dac-override=denied; fi
} > /out/probe.tmp
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

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}
]'
bundles=$scratch/bundles
# write_config NAME USER_JSON NO_NEW_PRIVILEGES CAPABILITIES_FIELD ARGS_JSON
# CAPABILITIES_FIELD is empty or ', "capabilities": {...}'.
write_config() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": $2, "noNewPrivileges": $3$4, "args": $5, "env": ["PATH=/bin"], "cwd": "/"},
  "hostname": "capbox",
  "mounts": $mounts,
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}
}
EOF
}
root='{"uid": 0, "gid": 0}'
user='{"uid": 1000, "gid": 1000}'
probe='["/bin/sh", "/scripts/probe.sh"]'
loop='["/bin/sh", "/scripts/loop.sh"]'
empty=', "capabilities": {}'
# Root: bounding CHOWN, KILL, NET_BIND_SERVICE, SYS_ADMIN; permitted CHOWN,
# KILL; effective CHOWN; inheritable KILL.
root_caps=', "capabilities": {"bounding": ["CAP_CHOWN", "CAP_KILL", "CAP_NET_BIND_SERVICE", "CAP_SYS_ADMIN"],
  "permitted": ["CAP_CHOWN", "CAP_KILL"], "effective": ["CAP_CHOWN"], "inheritable": ["CAP_KILL"]}'
# Non-root: only the ambient CHOWN survives exec; DAC_OVERRIDE and
# SYS_ADMIN are permitted and effective in the init but not in the workload.
user_caps=', "capabilities": {"bounding": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_KILL", "CAP_SYS_ADMIN"],
  "permitted": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_SYS_ADMIN"], "effective": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_SYS_ADMIN"],
  "inheritable": ["CAP_CHOWN", "CAP_DAC_OVERRIDE"], "ambient": ["CAP_CHOWN"]}'
# Non-root keeping the caller's inheritable CAP_NET_RAW although bounding
# excludes it: capset(2) accepts an already inheritable bit, and the ambient
# raise makes it effective after exec.
inherited_caps=', "capabilities": {"bounding": ["CAP_CHOWN"], "permitted": ["CAP_NET_RAW"], "effective": ["CAP_NET_RAW"],
  "inheritable": ["CAP_NET_RAW"], "ambient": ["CAP_NET_RAW"]}'
# Root asking for an inheritable CAP_KILL that is neither in bounding nor
# inherited: the kernel refuses it at capset.
ungrantable_caps=', "capabilities": {"bounding": ["CAP_CHOWN"], "permitted": ["CAP_KILL"], "inheritable": ["CAP_KILL"]}'
write_config default-root "$root" false "" "$probe"
write_config inherited-user "$user" false "$inherited_caps" "$probe"
write_config ungrantable "$root" false "$ungrantable_caps" "$probe"
write_config empty-root "$root" false "$empty" "$probe"
write_config configured-root "$root" false "$root_caps" "$probe"
write_config configured-user "$user" true "$user_caps" "$probe"
write_config empty-root-loop "$root" false "$empty" "$loop"
write_config empty-user-loop "$user" false "$empty" "$loop"
write_config empty-root-fds "$root" false "$empty" '["/bin/sh", "/scripts/fds.sh"]'
write_config unknown-name "$root" false ', "capabilities": {"bounding": ["CAP_NOPE"]}' "$probe"
write_config ambient-not-inheritable "$root" false \
    ', "capabilities": {"bounding": ["CAP_CHOWN"], "permitted": ["CAP_CHOWN"], "ambient": ["CAP_CHOWN"]}' "$probe"
# Only kernel range acceptance matters here; the workload just marks that it ran.
write_config beyond-kernel "$root" false ', "capabilities": {"bounding": ["CAP_CHECKPOINT_RESTORE"]}' \
    '["/bin/touch", "/out/probe.status"]'

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
# Capability, uid, and no_new_privs lines of /proc/PID/status, normalized.
capabilities_of() { awk '/^(Uid|NoNewPrivs|Cap[A-Za-z]+):/ { $1 = $1; print }' "/proc/$1/status"; }

# The caller holds exactly CAP_NET_RAW (bit 13) as its inheritable and
# ambient sets, which an absent object passes on and an explicit one clears.
# Both are reset first: the VM's own shell may already carry other bits.
as_caller() { setpriv --inh-caps -all,+net_raw --ambient-caps -all,+net_raw -- "$@"; }

# dump TAG: everything recorded for TAG, printed before a failure.
dump() {
    for kind in stderr stdout status init init.raw; do
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

# observe RT TAG BUNDLE MODE: runs the probe and keeps its normalized record
# as $results/TAG.status. For create/start, TAG.init holds the created
# init's sets, which are final before the workload is executed.
observe() {
    rt=$1 tag=$2 name=$3 mode=$4
    reset_probe
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
        runtime_step "$tag" as_caller $rt create --bundle "$bundles/$name" "$tag" \
            < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        created_status=$(status_of "$rt" "$tag")
        [ "$created_status" = created ] || { dump "$tag"; fail "$tag: status after create is '$created_status'"; }
        pid=$(pid_of "$rt" "$tag")
        capabilities_of "$pid" > "$results/$tag.init"
        cat "/proc/$pid/status" > "$results/$tag.init.raw" 2>&1 || :
        [ ! -e "$out/probe.status" ] || { dump "$tag"; fail "$tag: workload ran before start"; }
        runtime_step "$tag" $rt start "$tag"
        wait_status "$rt" "$tag" stopped
        runtime_step "$tag" $rt delete "$tag"
        ;;
    esac
    test -e "$out/probe.status" || { dump "$tag"; fail "$tag did not run the probe"; }
    awk '{ $1 = $1; print }' "$out/probe.status" > "$results/$tag.status"
}

# expect TAG LINE...: each line occurs in the probe record.
expect() {
    tag=$1
    shift
    for line in "$@"; do
        grep -qxF -- "$line" "$results/$tag.status" || { dump "$tag"; fail "$tag: expected '$line'"; }
    done
}
# expect_init TAG LINE...: each line occurs in the created init's record.
expect_init() {
    tag=$1
    shift
    for line in "$@"; do
        grep -qxF -- "$line" "$results/$tag.init" || { dump "$tag"; fail "$tag: created init lacks '$line'"; }
    done
}
zero=0000000000000000
# Removes every probe artifact (as root, so ownership by an earlier
# workload uid does not matter) before an independent run.
reset_probe() { rm -f "$out/probe.status" "$out/probe.tmp" "$out/chown.target"; }

shared_checks() {
    impl=$1 rt=$2
    for mode in foreground detached created; do
        # Absent: the inherited sets stay, including the caller's
        # inheritable CAP_NET_RAW; root keeps its privileges.
        tag=default-$mode-$impl
        observe "$rt" "$tag" default-root "$mode"
        expect "$tag" "Uid: 0 0 0 0" "CapInh: 0000000000002000" chown=allowed sethostname=allowed dac-override=allowed

        # {}: every set is empty, the bounding set included, and the
        # inherited inheritable and ambient capabilities are gone.
        tag=empty-$mode-$impl
        observe "$rt" "$tag" empty-root "$mode"
        expect "$tag" "Uid: 0 0 0 0" "CapInh: $zero" "CapPrm: $zero" "CapEff: $zero" "CapBnd: $zero" "CapAmb: $zero" \
            chown=denied sethostname=denied dac-override=denied

        # Configured root: exec gives root the bounding set (plus
        # inheritable) as permitted and effective, as Linux does for uid 0.
        tag=root-$mode-$impl
        observe "$rt" "$tag" configured-root "$mode"
        expect "$tag" "Uid: 0 0 0 0" "CapInh: 0000000000000020" "CapPrm: 0000000000200421" "CapEff: 0000000000200421" \
            "CapBnd: 0000000000200421" "CapAmb: $zero" chown=allowed sethostname=allowed dac-override=denied

        # Configured non-root: only the ambient capability is permitted and
        # effective after exec, even with no_new_privs.
        tag=user-$mode-$impl
        observe "$rt" "$tag" configured-user "$mode"
        expect "$tag" "Uid: 1000 1000 1000 1000" "NoNewPrivs: 1" "CapInh: 0000000000000003" "CapPrm: 0000000000000001" \
            "CapEff: 0000000000000001" "CapBnd: 0000000000200023" "CapAmb: 0000000000000001" \
            chown=allowed sethostname=denied dac-override=denied

        # Inherited inheritable bit outside the configured bounding set.
        tag=inherited-$mode-$impl
        observe "$rt" "$tag" inherited-user "$mode"
        expect "$tag" "Uid: 1000 1000 1000 1000" "CapInh: 0000000000002000" "CapPrm: 0000000000002000" \
            "CapEff: 0000000000002000" "CapBnd: 0000000000000001" "CapAmb: 0000000000002000" \
            chown=denied sethostname=denied dac-override=denied
    done
    expect_init "inherited-created-$impl" "CapInh: 0000000000002000" "CapPrm: 0000000000002000" \
        "CapEff: 0000000000002000" "CapBnd: 0000000000000001" "CapAmb: 0000000000002000"

    # A set the kernel cannot grant fails setup under both runtimes.
    reset_probe
    if as_caller $rt run --bundle "$bundles/ungrantable" "ungrantable-$impl" \
        < /dev/null > "$results/ungrantable-$impl.stdout" 2> "$results/ungrantable-$impl.stderr"; then
        dump "ungrantable-$impl"
        fail "$impl: inheritable capability outside bounding and the inherited set was granted"
    fi
    test ! -e "$out/probe.status" || fail "$impl: ungrantable workload ran"
    # The waiting inits hold exactly the configured sets.
    expect_init "default-created-$impl" "CapInh: 0000000000002000"
    expect_init "empty-created-$impl" "CapInh: $zero" "CapPrm: $zero" "CapEff: $zero" "CapBnd: $zero" "CapAmb: $zero"
    expect_init "root-created-$impl" "CapInh: 0000000000000020" "CapPrm: 0000000000000021" "CapEff: 0000000000000001" \
        "CapBnd: 0000000000200421" "CapAmb: $zero"
    expect_init "user-created-$impl" "Uid: 1000 1000 1000 1000" "CapInh: 0000000000000003" "CapPrm: 0000000000200003" \
        "CapEff: 0000000000200003" "CapBnd: 0000000000200023" "CapAmb: 0000000000000001"
    echo "$impl: absent, empty, configured root, and configured non-root capability sets ok"
}

shared_checks swift "$ours"
if [ "$compare" = 1 ]; then
    shared_checks runc "$theirs"
    # Identical sets and operation outcomes under both runtimes, for the
    # workloads and for the created inits.
    for mode in foreground detached created; do
        for config in default empty root user inherited; do
            if ! cmp -s "$results/$config-$mode-swift.status" "$results/$config-$mode-runc.status"; then
                diff "$results/$config-$mode-runc.status" "$results/$config-$mode-swift.status" >&2 || :
                fail "$config $mode capabilities differ from runc (diff: runc -> swift)"
            fi
        done
    done
    for config in default empty root user inherited; do
        if ! cmp -s "$results/$config-created-swift.init" "$results/$config-created-runc.init"; then
            diff "$results/$config-created-runc.init" "$results/$config-created-swift.init" >&2 || :
            fail "$config created init capabilities differ from runc (diff: runc -> swift)"
        fi
    done
fi

# Requests runc ignores with a warning are errors here, before any state.
# expect_rejected NAME MESSAGE [COMMAND PREFIX...]
expect_rejected() {
    name=$1 message=$2
    shift 2
    reset_probe
    if "$@" $ours run --bundle "$bundles/$name" "$name" < /dev/null > "$results/$name.stdout" 2> "$results/$name.stderr"; then
        dump "$name"
        fail "$name: run succeeded"
    fi
    grep -qF -- "$message" "$results/$name.stderr" || { dump "$name"; fail "$name: expected error '$message'"; }
    if $ours state "$name" > /dev/null 2>&1; then fail "$name: failed run left state"; fi
    test ! -e "$out/probe.status" || fail "$name: workload ran"
}
expect_rejected unknown-name 'process.capabilities.bounding[0]: unknown capability "CAP_NOPE"'
expect_rejected ambient-not-inheritable 'process.capabilities.ambient must be a subset of both permitted and inheritable; not inheritable: CAP_CHOWN'
# The kernel's capset refusal is reported with what it requires. The reset
# caller matters: an inherited CAP_KILL would make the request grantable.
expect_rejected ungrantable 'set effective, permitted, and inheritable capabilities (the runtime must hold every permitted one, and each inheritable one must be in bounding or already inheritable): Operation not permitted' \
    as_caller
if [ "$last_cap" -lt 40 ]; then
    expect_rejected beyond-kernel "CAP_CHECKPOINT_RESTORE (40) not supported by this kernel (cap_last_cap is $last_cap)"
    range_note="capability beyond cap_last_cap $last_cap rejected"
else
    reset_probe
    $ours run --bundle "$bundles/beyond-kernel" beyond-kernel < /dev/null > /dev/null 2> "$results/beyond-kernel.stderr" \
        || { dump beyond-kernel; fail "CAP_CHECKPOINT_RESTORE is supported (cap_last_cap $last_cap) but was rejected"; }
    test -e "$out/probe.status" || fail "beyond-kernel workload did not run"
    range_note="cap_last_cap is $last_cap, so the beyond-kernel rejection is unit-tested only"
fi
# Reducing the bounding set needs CAP_SETPCAP. Without it an explicit set
# fails with that diagnosis, while an absent one changes nothing and runs.
# The reset caller matters here too: an inheritable CAP_SETPCAP would come
# back into a root exec's permitted set despite the bounding drop.
without_setpcap() { as_caller setpriv --bounding-set -setpcap -- "$@"; }
# Prove the fixture: a process launched the same way lacks CAP_SETPCAP
# (bit 8) in its effective, permitted, inheritable, and bounding sets.
without_setpcap cat /proc/self/status > "$results/no-setpcap.caller" \
    || fail "cannot launch a caller without CAP_SETPCAP"
for set in CapEff CapPrm CapInh CapBnd; do
    mask=$(awk -v set="$set:" '$1 == set { print $2 }' "$results/no-setpcap.caller")
    if [ -z "$mask" ] || [ $((0x$mask & 0x100)) != 0 ]; then
        cat "$results/no-setpcap.caller" >&2
        fail "fixture caller still holds CAP_SETPCAP in $set"
    fi
done
expect_rejected empty-root 'drop bounding capability CAP_CHOWN (the runtime needs CAP_SETPCAP): Operation not permitted' \
    without_setpcap
reset_probe
without_setpcap $ours run --bundle "$bundles/default-root" no-setpcap \
    < /dev/null > /dev/null 2> "$results/no-setpcap.stderr" || { dump no-setpcap; fail "absent capabilities need CAP_SETPCAP"; }
test -e "$out/probe.status" || fail "no-setpcap did not run the probe"

# A foreground run still dies with the runtime after every capability is
# gone, as root and as non-root: the parent-death signal is armed again
# after the drops and needs no privilege.
for name in empty-root-loop empty-user-loop; do
    rm -f "$out/loop.started"
    "$runtime" --root "$state_root" run --bundle "$bundles/$name" "orphan-$name" < /dev/null > /dev/null 2>&1 &
    job=$!
    wait_until "orphan-$name to run" test -e "$out/loop.started"
    pid=$(pid_of "$ours" "orphan-$name")
    capabilities_of "$pid" | grep -qxF "CapBnd: $zero" || fail "orphan-$name kept a bounding set"
    kill -KILL "$job"
    wait "$job" 2>/dev/null || :
    wait_dead "$pid"
    wait_status "$ours" "orphan-$name" stopped
    $ours delete "orphan-$name"
done

# A detached container without capabilities outlives the command that
# started it, and a created one is started through the privilege-free gate.
rm -f "$out/loop.started"
$ours run --detach --bundle "$bundles/empty-root-loop" independent < /dev/null > /dev/null 2> "$results/independent.stderr" \
    || { dump independent; fail "detached run without capabilities failed"; }
wait_until "independent to run" test -e "$out/loop.started"
pid=$(pid_of "$ours" independent)
sleep 0.5
alive "$pid" || fail "detached container without capabilities exited"
test "$(status_of "$ours" independent)" = running
capabilities_of "$pid" | grep -qxF "CapEff: $zero" || fail "detached workload holds capabilities"
$ours delete --force independent

# No runtime descriptor reaches a workload without capabilities.
check_fds() {
    awk '
        $(NF - 1) == "->" && $(NF - 2) ~ /^[0-9]+$/ {
            fd = $(NF - 2); target = $NF
            if (fd + 0 > 2 && target != "/proc/1/fd") { print "leaked descriptor: " $0; bad = 1 }
            entries++
        }
        END { if (entries < 3) { print "unexpected descriptor listing"; bad = 1 }; exit bad }
    ' "$1" >&2 || { cat "$1" >&2; fail "descriptor check failed for $1"; }
}
$ours run --bundle "$bundles/empty-root-fds" fds-run < /dev/null 9< "$scratch" > "$results/fds-run" 2>&1 \
    || { cat "$results/fds-run" >&2; fail "fds-run failed"; }
check_fds "$results/fds-run"
$ours create --bundle "$bundles/empty-root-fds" fds-created < /dev/null 9< "$scratch" > "$results/fds-created" 2>&1 \
    || { cat "$results/fds-created" >&2; fail "fds-created create failed"; }
$ours start fds-created
wait_status "$ours" fds-created stopped
check_fds "$results/fds-created"
$ours delete fds-created

test -z "$(ls -A "$state_root")" || { ls -A "$state_root" >&2; fail "state left behind"; }
comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "Capability integration checks passed (comparison: $comparison): absent object keeps inherited sets, {} clears all five (inherited inheritable/ambient included), configured root and non-root masks with CAP_CHOWN/CAP_SYS_ADMIN/CAP_DAC_OVERRIDE operations, ambient with no_new_privs, inherited inheritable outside bounding, kernel capset refusal, created-init sets, unknown-name and ambient-subset rejection, $range_note, CAP_SETPCAP diagnosis, parent-death cleanup, detached lifetime, descriptor isolation."
