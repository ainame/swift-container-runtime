#!/bin/sh
# linux.sysctl compared with runc: Docker's default network sysctls plus IPC
# and UTS entries are visible inside the container and leave the host's
# values unchanged. Swift-only refusals cover sysctls of a namespace the
# container does not own, an unsupported key and a missing /proc mount.
# Run as root inside a disposable Linux VM with BusyBox (BUSYBOX).
# RUNC_COMPARE=1 also runs runc.
set -eu
runtime=${1:-.build/debug/swift-container-runtime}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-0}
scratch=$(mktemp -d)
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
fail() { echo "sysctl-integration: $*" >&2; exit 1; }

rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev"
cp "$busybox" "$rootfs/bin/busybox"
for applet in sh cat echo; do ln -s busybox "$rootfs/bin/$applet"; done
keys='net/ipv4/ip_unprivileged_port_start net/ipv4/ping_group_range kernel/shmmax kernel/domainname'
host_values() { for key in $keys; do echo "$key=$(cat "/proc/sys/$key")"; done; }
host_values > "$scratch/host-before"
# Unquoted, so a tab in a value (ping_group_range) prints as one space.
probe="for key in $keys; do echo \$key=\$(cat /proc/sys/\$key); done"
sysctls='"net.ipv4.ip_unprivileged_port_start": "0", "net.ipv4.ping_group_range": "0 2147483647", "kernel.shmmax": "12345678", "kernel.domainname": "sctdomain"'
all='[{"type": "pid"}, {"type": "mount"}, {"type": "ipc"}, {"type": "uts"}, {"type": "network"}]'
proc='{"destination": "/proc", "type": "proc", "source": "proc"}'
# config NAME SYSCTLS NAMESPACES MOUNTS
config() {
    mkdir -p "$scratch/$1"
    cat > "$scratch/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": {"uid": 0, "gid": 0}, "args": ["/bin/sh", "-c", "$probe"], "env": ["PATH=/bin"], "cwd": "/"},
  "mounts": [$4],
  "linux": {"namespaces": $3, "sysctl": {$2}}
}
EOF
}
expected='net/ipv4/ip_unprivileged_port_start=0
net/ipv4/ping_group_range=0 2147483647
kernel/shmmax=12345678
kernel/domainname=sctdomain'
for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; *) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    tag=sysctl-$impl
    config "$tag" "$sysctls" "$all" "$proc"
    $rt run --bundle "$scratch/$tag" "$tag" > "$scratch/$tag.out" 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: run failed"; }
    [ "$(cat "$scratch/$tag.out")" = "$expected" ] || { cat "$scratch/$tag.out"; fail "$tag: container values differ"; }
    host_values | cmp -s - "$scratch/host-before" || fail "$tag: host sysctls changed"
    echo "$impl: network, ipc and uts sysctls applied in the container; host unchanged"
done

# refused NAME MESSAGE SYSCTLS NAMESPACES MOUNTS
refused() {
    config "$1" "$3" "$4" "$5"
    if $ours run --bundle "$scratch/$1" "$1" > "$scratch/$1.out" 2> "$scratch/$1.err"; then fail "$1: run succeeded"; fi
    grep -qF -- "$2" "$scratch/$1.err" || { cat "$scratch/$1.err"; fail "$1: expected '$2'"; }
    [ ! -s "$scratch/$1.out" ] || fail "$1: workload ran"
    if $ours state "$1" > /dev/null 2>&1; then fail "$1: left state"; fi
}
refused host-net "host's network namespace" '"net.ipv4.ip_unprivileged_port_start": "0"' \
    '[{"type": "pid"}, {"type": "mount"}, {"type": "ipc"}, {"type": "uts"}]' "$proc"
refused host-net-path "host's network namespace" '"net.ipv4.ip_unprivileged_port_start": "0"' \
    '[{"type": "pid"}, {"type": "mount"}, {"type": "network", "path": "/proc/self/ns/net"}]' "$proc"
refused unsupported 'separate kernel namespace' '"vm.swappiness": "10"' "$all" "$proc"
refused no-proc 'needs a proc mount' '"kernel.shmmax": "1"' "$all" ''
host_values | cmp -s - "$scratch/host-before" || fail 'host sysctls changed'
echo 'swift: host network (including a joined host path), unsupported key and missing /proc refused without state'
echo 'Sysctl integration passed.'
