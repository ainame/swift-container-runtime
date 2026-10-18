#!/bin/sh
# OCI hooks compared with runc: phase order, state on stdin (status and pid),
# argv and environment (startContainer inherits the workload's), the
# namespace each phase runs in, and failure, timeout and cleanup behavior.
# Run as root inside a disposable Linux VM with BusyBox (BUSYBOX).
# RUNC_COMPARE=1 also runs runc.
set -eu
runtime=${1:-.build/debug/srunc}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-0}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
ours="timeout -k 2 60 $runtime --root $scratch/state"
theirs="timeout -k 2 60 runc --root $scratch/runc-state"
cleanup() {
    for rt in "$ours" "$theirs"; do
        for id in $($rt list -q 2>/dev/null); do $rt delete --force "$id" >/dev/null 2>&1 || :; done
    done
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { echo "hooks-integration: $*" >&2; exit 1; }

rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/log" "$scratch/log"
cp "$busybox" "$rootfs/bin/busybox"
for applet in sh cat echo sed grep sleep true readlink pwd; do ln -s busybox "$rootfs/bin/$applet"; done
# hook.sh PHASE LOG [fail|sleep]: one line per call, "phase status pid env mnt-ns".
# The test replaces the host's mount namespace with "runtime" and any other
# with "container".
hook='#!/bin/sh
state=$(cat)
status=$(echo "$state" | sed -n "s/.*\"status\":\"\([a-z]*\)\".*/\1/p")
pid=nopid
echo "$state" | grep -q "\"pid\":[1-9]" && pid=pid
echo "$1 $status $pid ${HOOK_ENV:-noenv} $(readlink /proc/self/ns/mnt)" >> "$2"
case "${3:-}" in
fail) echo "hook $1 failed" >&2; exit 3 ;;
sleep) exec sleep 10 ;;
esac'
printf '%s\n' "$hook" > "$scratch/hook.sh"
printf '%s\n' "$hook" > "$rootfs/hook.sh"
chmod 755 "$scratch/hook.sh" "$rootfs/hook.sh"
log=$scratch/log/phases
host_ns=$(readlink /proc/self/ns/mnt)
# phases: the log with mount namespaces named by where they are.
phases() { awk -v host="$host_ns" '{ $NF = ($NF == host) ? "runtime" : "container"; print }' "$log"; }
path_env='"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'

# runtime_hook PHASE [MODE]: a host hook with its own argv[0] and environment.
runtime_hook() {
    printf '{"path": "%s", "args": ["hook", "%s", "%s", "%s"], "env": [%s, "HOOK_ENV=%s"]%s}' \
        "$scratch/hook.sh" "$1" "$log" "${2:-}" "$path_env" "$1" "$([ "${2:-}" = sleep ] && echo ', "timeout": 1')"
}
# config NAME ARGS HOOKS_JSON
config() {
    mkdir -p "$scratch/$1"
    cat > "$scratch/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": {"uid": 0, "gid": 0}, "args": $2, "env": ["PATH=/bin"], "cwd": "/"},
  "mounts": [
    {"destination": "/proc", "type": "proc", "source": "proc"},
    {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "mode=755"]},
    {"destination": "/log", "type": "bind", "source": "$scratch/log", "options": ["rbind", "rw"]}
  ],
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "ipc"}, {"type": "uts"}]},
  "hooks": $3
}
EOF
}
# all_hooks [PHASE MODE]: every phase, MODE (fail/sleep) applied to PHASE.
all_hooks() {
    mode() { [ "${1}" = "${failing:-}" ] && echo "${failing_mode:-}" || :; }
    failing=${1:-} failing_mode=${2:-}
    printf '{"prestart": [%s], "createRuntime": [%s], "createContainer": [%s], "startContainer": [{"path": "/hook.sh", "args": ["hook", "startContainer", "/log/phases", "%s"]}], "poststart": [%s], "poststop": [%s]}' \
        "$(runtime_hook prestart "$(mode prestart)")" "$(runtime_hook createRuntime "$(mode createRuntime)")" \
        "$(runtime_hook createContainer "$(mode createContainer)")" "$(mode startContainer)" \
        "$(runtime_hook poststart "$(mode poststart)")" "$(runtime_hook poststop "$(mode poststop)")"
}
expected_all='prestart creating pid prestart runtime
createRuntime creating pid createRuntime runtime
createContainer creating pid createContainer container
startContainer created pid noenv container
poststart running pid poststart runtime
poststop stopped nopid poststop runtime'

# same_phases IMPL: Swift follows the spec order exactly. runc 1.4 runs
# poststart as soon as start releases the init, racing startContainer, with
# status "created"; it is compared as the same set of calls.
same_phases() {
    if [ "$1" = swift ]; then
        [ "$(phases)" = "$expected_all" ]
    else
        normalized() { sed 's/^poststart [a-z]*/poststart any/' | sort; }
        [ "$(phases | normalized)" = "$(printf '%s\n' "$expected_all" | normalized)" ]
    fi
}

for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; *) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    # create/start/delete: every phase once, in order.
    tag=hooks-lifecycle-$impl
    rm -f "$log"
    config "$tag" '["/bin/sleep", "1000"]' "$(all_hooks)"
    $rt create --bundle "$scratch/$tag" "$tag" < /dev/null > /dev/null 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: create failed"; }
    $rt start "$tag" 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: start failed"; }
    $rt delete --force "$tag" 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: delete failed"; }
    same_phases "$impl" || { phases; fail "$tag: phases differ"; }

    # Foreground run: the same phases around a short workload.
    tag=hooks-run-$impl
    rm -f "$log"
    config "$tag" '["/bin/true"]' "$(all_hooks)"
    $rt run --bundle "$scratch/$tag" "$tag" < /dev/null > /dev/null 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: run failed"; }
    same_phases "$impl" || { phases; fail "$tag: phases differ"; }
    echo "$impl: six phases in order with state, argv, environment and namespaces for create/start/delete and run"
done

# Failures (Swift): a failing setup hook fails create without state or workload.
for phase in prestart createRuntime createContainer; do
    tag=hooks-fail-$phase
    rm -f "$log"
    config "$tag" '["/bin/echo", "must-not-run"]' "$(all_hooks "$phase" fail)"
    if $ours create --bundle "$scratch/$tag" "$tag" < /dev/null > "$scratch/$tag.out" 2> "$scratch/$tag.err"; then fail "$tag: create succeeded"; fi
    grep -qF "error running $phase hook #0" "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: wrong error"; }
    if $ours state "$tag" > /dev/null 2>&1; then fail "$tag: left state"; fi
    ! grep -q startContainer "$log" || fail "$tag: later phases ran"
done
# A failing startContainer hook fails start; the workload never runs.
tag=hooks-fail-start
config "$tag" '["/bin/sh", "-c", "echo ran > /log/workload"]' "$(all_hooks startContainer fail)"
$ours create --bundle "$scratch/$tag" "$tag" < /dev/null > /dev/null 2>&1
if $ours start "$tag" 2> "$scratch/$tag.err"; then fail "$tag: start succeeded"; fi
grep -qF 'error running startContainer hook #0: exit status 3' "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: wrong error"; }
[ ! -e "$scratch/log/workload" ] || fail "$tag: workload ran"
$ours delete --force "$tag"
# A failing poststart fails start and kills the container.
tag=hooks-fail-poststart
config "$tag" '["/bin/sleep", "1000"]' "$(all_hooks poststart fail)"
$ours create --bundle "$scratch/$tag" "$tag" < /dev/null > /dev/null 2>&1
if $ours start "$tag" 2> "$scratch/$tag.err"; then fail "$tag: start succeeded"; fi
grep -qF 'error running poststart hook #0: exit status 3, output: hook poststart failed' "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: wrong error"; }
for _ in $(seq 50); do $ours state "$tag" | grep -q '"stopped"' && break; sleep 0.1; done
$ours state "$tag" | grep -q '"stopped"' || fail "$tag: container still running"
# A failing poststop only warns: delete succeeds and removes the state.
$ours delete --force "$tag" 2> "$scratch/$tag.delete" || fail "$tag: delete failed on a poststart-killed container"
tag=hooks-fail-poststop
config "$tag" '["/bin/sleep", "1000"]' "$(all_hooks poststop fail)"
$ours create --bundle "$scratch/$tag" "$tag" < /dev/null > /dev/null 2>&1
$ours start "$tag"
$ours delete --force "$tag" 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: delete failed"; }
grep -qF 'warning: error running poststop hook #0' "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: no warning"; }
if $ours state "$tag" > /dev/null 2>&1; then fail "$tag: left state"; fi
# A hook past its timeout is killed and fails create promptly.
tag=hooks-timeout
config "$tag" '["/bin/echo", "must-not-run"]' "$(all_hooks createRuntime sleep)"
started=$(date +%s)
if $ours create --bundle "$scratch/$tag" "$tag" < /dev/null > /dev/null 2> "$scratch/$tag.err"; then fail "$tag: create succeeded"; fi
[ $(($(date +%s) - started)) -lt 8 ] || fail "$tag: timeout was not enforced"
grep -qF 'error running createRuntime hook #0: timeout after 1s' "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: wrong error"; }
if pgrep -f "^sleep 10$" > /dev/null; then fail "$tag: timed-out hook survived"; fi
echo 'swift: prestart/createRuntime/createContainer/startContainer/poststart failures, poststop warning and timeout'
echo 'Hooks integration passed.'
