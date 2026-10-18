#!/bin/sh
# Opt-in native-snapshotter profile. Pull/unpack the pinned Alpine image into
# NAMESPACE first; this script never downloads or removes the cached image.
set -eu
[ "$#" -eq 4 ] || { echo "Usage: $0 LINUX_RUNTIME SOCKET NAMESPACE IMAGE@sha256:DIGEST" >&2; exit 2; }
runtime=$1 address=$2 namespace=$3 image=$4
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
case "$image" in *@sha256:*) ;; *) echo 'Use a pinned image digest' >&2; exit 2 ;; esac
scratch=$(mktemp -d)
id=sct-image-$$
fixture=/$id
root=$scratch/runtime/$namespace
c() { timeout -k 2 30 ctr --address "$address" --namespace "$namespace" "$@"; }
cleanup() {
    c tasks kill --all --signal SIGKILL "$id" >/dev/null 2>&1 || :
    c tasks rm "$id" >/dev/null 2>&1 || :
    c containers delete "$id" >/dev/null 2>&1 || :
    if [ -d "/sys/fs/cgroup$fixture" ]; then find "/sys/fs/cgroup$fixture" -depth -type d -exec rmdir {} \; 2>/dev/null || :; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { echo "containerd-image: $*" >&2; exit 1; }
absent() { [ ! -e "$1" ]; }
wait_until() {
    deadline=$(($(date +%s) + 30))
    until "$@"; do [ "$(date +%s)" -lt "$deadline" ] || fail 'cleanup timed out'; sleep 0.05; done
}
c version
printf 'image: %s\n' "$image"
mkdir -p "$scratch/volume" "/sys/fs/cgroup$fixture"
printf 'nameserver 192.0.2.1\n' > "$scratch/resolv.conf"
# Optional supplied network path is explicit; no namespace is provisioned here.
set --
if [ -n "${ENGINE_NETWORK_NAMESPACE_PATH:-}" ]; then
    set -- "$@" --with-ns "network:$ENGINE_NETWORK_NAMESPACE_PATH"
fi
case "${ENGINE_SECCOMP:-}" in
    '') ;;
    default) set -- "$@" --seccomp ;;
    *) set -- "$@" --seccomp --seccomp-profile "$ENGINE_SECCOMP" ;;
esac
if [ -n "${ENGINE_SECCOMP_PROBE:-}" ]; then
    set -- "$@" --mount "type=bind,src=$ENGINE_SECCOMP_PROBE,dst=/seccomp-probe,options=bind:ro:rprivate"
fi
c run --snapshotter native --runc-binary "$runtime" --runc-root "$scratch/runtime" --cgroup "$fixture/workload" -d \
    --mount "type=bind,src=$scratch/resolv.conf,dst=/etc/resolv.conf,options=rbind:ro:rprivate" \
    --mount "type=bind,src=$scratch/volume,dst=/volume,options=rbind:rw:rprivate" \
    "$@" "$image" "$id" /bin/sh -ec 'echo image-volume > /volume/result; exec sleep 1000'
bundle=$("$runtime" --root "$root" state "$id" | sed -n 's/.*"bundle"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$bundle" ] || fail 'missing Swift state/bundle'
init=$(cat "$bundle/init.pid")
grep -q '"deviceProgramID"' "$root/$id/state.json" || fail 'device policy was not recorded'
if [ -n "${ENGINE_CAPTURE_DIRECTORY:-}" ]; then
    mkdir -p "$ENGINE_CAPTURE_DIRECTORY"
    cp "$bundle/config.json" "$ENGINE_CAPTURE_DIRECTORY/create.config.json"
fi
if [ -n "${ENGINE_NETWORK_NAMESPACE_PATH:-}" ]; then
    expected_net=$(stat -Lc %i "$ENGINE_NETWORK_NAMESPACE_PATH")
    actual_net=$(stat -Lc %i "/proc/$init/ns/net")
    [ "$expected_net" = "$actual_net" ] || fail 'engine joined wrong network namespace'
    printf 'network namespace inode: %s\n' "$actual_net"
fi
if [ -n "${ENGINE_NETWORK_TEST_PORT:-}" ]; then
    c tasks exec --exec-id network "$id" /bin/busybox nc -w 3 127.0.0.1 "$ENGINE_NETWORK_TEST_PORT" > "$scratch/network"
    grep -qx joined-network "$scratch/network" || fail 'image exec did not reach supplied namespace listener'
    echo 'network TCP reply: joined-network'
fi
if [ -n "${ENGINE_SECCOMP:-}" ]; then
    grep -Eq '^Seccomp:[[:space:]]+2$' "/proc/$init/status" || fail 'init seccomp filter missing'
    c tasks exec --exec-id seccomp "$id" /seccomp-probe "${ENGINE_SECCOMP_EXPECTATION:-allowed}"
    echo 'seccomp: init filter mode and exec syscall result verified'
fi
c tasks exec --exec-id release "$id" /bin/cat /etc/alpine-release
c tasks exec --exec-id check "$id" /bin/sh -ec 'cat /etc/resolv.conf; cat /volume/result; if (echo forbidden > /etc/resolv.conf) 2>/dev/null; then exit 3; fi' > "$scratch/check"
printf 'nameserver 192.0.2.1\nimage-volume\n' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/check" || fail 'image bind/exec view differs'
[ "$(cat "$scratch/volume/result")" = image-volume ] || fail 'volume write did not reach source'
[ "$(cat "$scratch/resolv.conf")" = 'nameserver 192.0.2.1' ] || fail 'readonly source changed'
c tasks exec --exec-id detached -d "$id" /bin/sleep 1000
exec_pid=$(cat "$bundle/detached.pid")
[ -r "/proc/$init/stat" ] && [ -r "/proc/$exec_pid/stat" ] || fail 'init/exec PID publication failed'
set +e
c tasks exec --exec-id status "$id" /bin/sh -c 'exit 42'
status=$?
set -e
[ "$status" -eq 42 ] || fail 'image exec exit status differs'
c tasks kill --all --signal SIGKILL "$id"
c tasks rm "$id" >/dev/null
c containers delete "$id"
wait_until absent "/proc/$init"
wait_until absent "/proc/$exec_pid"
[ ! -e "$root/$id" ] && [ ! -e "/sys/fs/cgroup$fixture/workload" ] || fail 'image runtime state/cgroup leaked'
if c snapshots --snapshotter native list | awk -v id="$id" '$1==id {found=1} END {exit !found}'; then fail 'image snapshot leaked'; fi
echo 'containerd-image: PASS (native snapshot, readonly config, writable volume, init/exec, PID files, exit status and cleanup)'
