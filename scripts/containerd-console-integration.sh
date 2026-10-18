#!/bin/sh
# Opt-in console gate through the real shim: containerd allocates terminals
# with --console-socket, ctr attaches them to a pseudoterminal from script(1),
# and resizes them through the shim to that terminal's size. Pull/unpack the
# pinned image into NAMESPACE with the native snapshotter first.
set -eu
[ "$#" -eq 4 ] || { echo "Usage: $0 LINUX_RUNTIME SOCKET NAMESPACE IMAGE@sha256:DIGEST" >&2; exit 2; }
runtime=$1 address=$2 namespace=$3 image=$4
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
case "$image" in *@sha256:*) ;; *) echo 'Use a pinned image digest' >&2; exit 2 ;; esac
command -v script > /dev/null || { echo 'script(1) from util-linux is required' >&2; exit 2; }
scratch=$(mktemp -d)
id=sct-console-$$
root=$scratch/runtime/$namespace
ctr="timeout -k 2 30 ctr --address $address --namespace $namespace"
cleanup() {
    $ctr tasks kill --all --signal SIGKILL "$id" >/dev/null 2>&1 || :
    $ctr tasks rm "$id" >/dev/null 2>&1 || :
    $ctr containers delete "$id" >/dev/null 2>&1 || :
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { echo "containerd-console: $*" >&2; exit 1; }
# attached ROWS COLUMNS STATUS LOG COMMAND: run COMMAND on a ROWS x COLUMNS
# pseudoterminal and require its exit status.
attached() {
    rows=$1 columns=$2 expected=$3 log=$4
    shift 4
    set +e
    script -qec "stty rows $rows cols $columns; $*" "$log" < /dev/null > /dev/null
    status=$?
    set -e
    [ "$status" = "$expected" ] || { cat "$log"; fail "exit status $status, expected $expected"; }
    # ctr's terminal echoes a NUL as ^@ before the output, with runc too.
    tr -d '\r' < "$log" | sed 's/^\^@//' > "$log.clean"
}
# ctr resizes through the shim after the start, so the size is read later.
probe="tty; sleep 0.5; stty size; echo ctty > /dev/tty; [ -t 0 ] && [ -t 1 ] && echo stdio=tty"
runtime_options="--snapshotter native --runc-binary $runtime --runc-root $scratch/runtime"

# Foreground run: the init's terminal, its size and exit status.
attached 30 100 3 "$scratch/run" \
    "$ctr run $runtime_options -t --rm $image $id /bin/sh -c '$probe; exit 3'"
for line in /dev/pts/0 '30 100' ctty stdio=tty; do
    grep -qx "$line" "$scratch/run.clean" || { cat "$scratch/run.clean"; fail "run output lacks '$line'"; }
done
[ ! -e "$root/$id" ] || fail 'run --rm left runtime state'
echo 'run -t: init terminal, shim resize to 30x100, controlling terminal and exit 3'

# A detached terminal init, then an attached terminal exec.
# ctr requires a console on stdin even when it detaches.
attached 24 80 0 "$scratch/detached" "$ctr run $runtime_options -d -t $image $id /bin/sleep 1000"
attached 40 120 4 "$scratch/exec" \
    "$ctr tasks exec -t --exec-id console $id /bin/sh -c '$probe; exit 4'"
for line in '40 120' ctty stdio=tty; do
    grep -qx "$line" "$scratch/exec.clean" || { cat "$scratch/exec.clean"; fail "exec output lacks '$line'"; }
done
grep -qx '/dev/pts/[1-9][0-9]*' "$scratch/exec.clean" || { cat "$scratch/exec.clean"; fail 'exec did not get its own terminal'; }
$ctr tasks kill --signal SIGKILL "$id"
for _ in $(seq 100); do $ctr tasks ls | grep -q "$id.*STOPPED" && break; sleep 0.1; done
$ctr tasks rm "$id" > /dev/null
$ctr containers delete "$id"
[ ! -e "$root/$id" ] || fail 'runtime state leaked'
echo 'exec -t: separate exec terminal, shim resize to 40x120, controlling terminal and exit 4'
echo 'containerd-console: PASS (attached run and exec terminals through the shim, cleanup)'
