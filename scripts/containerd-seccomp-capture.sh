#!/bin/sh
# Capture reference engine profiles before enabling them in Swift. Opt-in only.
set -eu
[ "$#" -eq 4 ] || { echo "Usage: $0 SOCKET NAMESPACE IMAGE@sha256:DIGEST OUTPUT_DIRECTORY" >&2; exit 2; }
address=$1 namespace=$2 image=$3 output=$4
case "$image" in *@sha256:*) ;; *) echo 'Use a pinned image digest' >&2; exit 2 ;; esac
case "$output" in /*) ;; *) output=$PWD/$output ;; esac
[ ! -e "$output" ] || { echo 'Output directory must be new' >&2; exit 2; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
id=sct-seccomp-$$
root=$scratch/runtime/$namespace
c() { timeout -k 2 30 ctr --address "$address" --namespace "$namespace" "$@"; }
cleanup() {
    c tasks kill --all --signal SIGKILL "$id" >/dev/null 2>&1 || :
    c tasks rm "$id" >/dev/null 2>&1 || :
    c containers delete "$id" >/dev/null 2>&1 || :
    rmdir "/sys/fs/cgroup/$id/workload" "/sys/fs/cgroup/$id" 2>/dev/null || :
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$output" "/sys/fs/cgroup/$id"
cat > "$scratch/profile.json" <<'JSON'
{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getcwd"],"action":"SCMP_ACT_ERRNO","errnoRet":13}]}
JSON
"${CC:-clang}" -static -O2 -Wall -Wextra -Werror "$here/fixtures/seccomp-probe.c" -o "$scratch/probe"
"$scratch/probe" allowed
for profile in default deny-getcwd; do
    set -- --seccomp
    [ "$profile" = default ] || set -- "$@" --seccomp-profile "$scratch/profile.json"
    c run --snapshotter native --runc-binary /usr/bin/runc --runc-root "$scratch/runtime" \
        --cgroup "/$id/workload" --mount "type=bind,src=$scratch/probe,dst=/seccomp-probe,options=bind:ro:rprivate" \
        "$@" -d "$image" "$id" /bin/sleep 1000
    /usr/bin/runc --root "$root" state "$id" > "$scratch/state.json"
    bundle=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundle"])' "$scratch/state.json")
    cp "$bundle/config.json" "$output/$profile.config.json"
    c tasks exec --exec-id status "$id" /bin/grep '^Seccomp:' /proc/self/status > "$scratch/status"
    cat "$scratch/status"
    awk '$1=="Seccomp:" && $2==2 {found=1} END {exit !found}' "$scratch/status"
    case "$profile" in default) expected=allowed ;; *) expected=denied ;; esac
    c tasks exec --exec-id probe "$id" /seccomp-probe "$expected"
    c tasks kill --all --signal SIGKILL "$id"
    c tasks rm "$id" >/dev/null
    c containers delete "$id"
    [ ! -e "/sys/fs/cgroup/$id/workload" ] || { echo 'reference cgroup leaked' >&2; exit 1; }
    [ ! -e "$root/$id" ] || { echo 'reference state leaked' >&2; exit 1; }
    if c snapshots --snapshotter native list | awk -v id="$id" '$1==id {found=1} END {exit !found}'; then echo 'reference snapshot leaked' >&2; exit 1; fi
done
echo 'containerd-seccomp-capture: PASS (reference default profile, custom denied getcwd, exec and cleanup)'
