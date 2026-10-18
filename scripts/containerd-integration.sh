#!/bin/sh
# Explicit opt-in: prepared rootful Linux daemon, cgroup v2/cgroupfs and
# nonterminal BusyBox directory rootfs. No Docker/default-security claim.
set -eu
[ "$#" -eq 2 ] || { echo "Usage: $0 LINUX_RUNTIME CONTAINERD_SOCKET" >&2; exit 2; }
runtime=$1 address=$2
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
scratch=$(mktemp -d)
namespace=sct-engine-$$
fixture=/sct-engine-$$
cg=/sys/fs/cgroup
root=$scratch/runtime/$namespace
c() { timeout -k 2 30 ctr --address "$address" --namespace "$namespace" "$@"; }
cleanup() {
    for id in holder stdio bad-create; do
        c tasks kill --all --signal SIGKILL "$id" >/dev/null 2>&1 || :
        c tasks rm "$id" >/dev/null 2>&1 || :
        c containers delete "$id" >/dev/null 2>&1 || :
    done
    c namespaces remove "$namespace" >/dev/null 2>&1 || :
    if [ -d "$cg$fixture" ]; then find "$cg$fixture" -depth -type d -exec rmdir {} \; 2>/dev/null || :; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { echo "containerd: $*" >&2; exit 1; }
wait_until() {
    description=$1; shift
    deadline=$(($(date +%s) + 30))
    until "$@"; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "timed out: $description"
        sleep 0.05
    done
}
absent() { [ ! -e "$1" ]; }
no_open_fds() {
    [ -d "/proc/$1/fd" ] || return 0
    descriptors=$(ls -A "/proc/$1/fd" 2>/dev/null) || return 1
    [ -z "$descriptors" ]
}
field() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'; }
[ "$(id -u)" -eq 0 ] || fail 'requires root'
[ "$(stat -f -c %T "$cg")" = cgroup2fs ] || fail 'requires cgroup v2'
[ -x "$runtime" ] || fail 'runtime is not executable'
c version
mkdir -p "$scratch/rootfs/bin" "$cg$fixture"
cp "${BUSYBOX:-/bin/busybox}" "$scratch/rootfs/bin/busybox"

c run --rootfs --runc-binary "$runtime" --runc-root "$scratch/runtime" --cgroup "$fixture/holder" -d "$scratch/rootfs" holder /bin/busybox sleep 1000
bundle=$("$runtime" --root "$root" state holder | field bundle)
[ -n "$bundle" ] || fail 'missing runtime bundle'
init=$(cat "$bundle/init.pid")
[ -r "/proc/$init/stat" ] || fail 'init PID was not published'
shim=$(awk '{print $4}' "/proc/$init/stat")
[ "$(cat "$bundle/init.pid")" = "$(c tasks list | awk '$1=="holder" {print $2}')" ] || fail 'shim init PID differs'
grep -q '"deviceProgramID"' "$root/holder/state.json" || fail 'device filter was not recorded'

c tasks exec --exec-id output holder /bin/busybox echo engine-exec > "$scratch/exec"
grep -qx engine-exec "$scratch/exec" || fail 'exec stdout differs'
set +e
c tasks exec --exec-id status holder /bin/busybox sh -c 'exit 42'
status=$?
set -e
[ "$status" -eq 42 ] || fail "exec exit status was $status"
c tasks exec --exec-id detached -d holder /bin/busybox sleep 1000
exec_pid=$(cat "$bundle/detached.pid")
[ -r "/proc/$exec_pid/stat" ] || fail 'detached exec PID was not published'
if c tasks exec --exec-id bad holder /missing-program > "$scratch/bad.out" 2> "$scratch/bad.err"; then fail 'missing exec succeeded'; fi
grep -q 'OCI runtime exec failed: exec workload' "$scratch/bad.err" || fail 'shim did not extract runtime exec error'
c tasks kill --all --signal SIGKILL holder
c tasks rm holder >/dev/null
c containers delete holder
wait_until 'shim reaped init' absent "/proc/$init"
wait_until 'shim reaped detached exec' absent "/proc/$exec_pid"
wait_until 'shim closed its file descriptors' no_open_fds "$shim"
[ ! -e "$root/holder" ] && [ ! -e "$cg$fixture/holder" ] || fail 'holder state/cgroup leaked'

# Keep input open until the task is RUNNING. ctr's stdinCloser callback is
# assigned after NewTask: immediate EOF before then is lost in ctr 2.2.2 under
# both runc and Swift. This synchronizes with setup, without a fixed delay.
mkfifo "$scratch/input"
c run --rootfs --runc-binary "$runtime" --runc-root "$scratch/runtime" --cgroup "$fixture/stdio" --rm "$scratch/rootfs" stdio /bin/busybox sh -c '/bin/busybox cat; echo engine-stdout; echo engine-stderr >&2; exit 17' < "$scratch/input" > "$scratch/stdout" 2> "$scratch/stderr" &
client=$!
exec 4> "$scratch/input"
running() { c tasks list | awk '$1=="stdio" && $3=="RUNNING" {found=1} END {exit !found}'; }
wait_until 'stdio running' running
printf 'engine-stdin\n' >&4
exec 4>&-
set +e
wait "$client"
status=$?
set -e
[ "$status" -eq 17 ] || { cat "$scratch/stderr" >&2; fail "attached exit status was $status"; }
printf 'engine-stdin\nengine-stdout\n' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/stdout" || fail 'stdin/stdout content or EOF differs'
grep -qx engine-stderr "$scratch/stderr" || fail 'stderr differs'
[ ! -e "$cg$fixture/stdio" ] && [ ! -e "$root/stdio" ] || fail 'stdio state/cgroup leaked'

if c run --rootfs --runc-binary "$runtime" --runc-root "$scratch/runtime" --cgroup "$fixture/bad-create" --rm "$scratch/rootfs" bad-create /missing-program > "$scratch/create.out" 2> "$scratch/create.err"; then fail 'missing create succeeded'; fi
grep -q 'OCI runtime create failed: exec workload' "$scratch/create.err" || fail 'shim did not extract create error'
[ ! -e "$cg$fixture/bad-create" ] && [ ! -e "$root/bad-create" ] || fail 'failed create leaked state/cgroup'
[ "$(c tasks list | wc -l)" -eq 1 ] || fail 'tasks left behind'
echo 'containerd: PASS (cgroupfs, directory rootfs, pipes, init/exec PID files, exit codes, kill/delete and error cleanup)'
