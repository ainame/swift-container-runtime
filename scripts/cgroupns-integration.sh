#!/bin/sh
# Cgroup namespaces and cgroup2 mounts, compared with runc: init and exec see
# their container cgroup as "/", /sys/fs/cgroup is a read-only cgroup2 mount of
# that cgroup only, and exec joins the init's cgroup namespace. A cgroup mount
# without a cgroup namespace is refused (Swift only).
# Run as root inside a disposable Linux VM with BusyBox (BUSYBOX).
# RUNC_COMPARE=1 also runs runc.
set -eu
runtime=${1:-.build/debug/srunc}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-0}
scratch=$(mktemp -d)
fixture=sct-cgroupns-$$
ours="timeout -k 2 60 $runtime --root $scratch/state"
theirs="timeout -k 2 60 runc --root $scratch/runc-state"
cleanup() {
    for rt in "$ours" "$theirs"; do
        for id in $($rt list -q 2>/dev/null); do $rt delete --force "$id" >/dev/null 2>&1 || :; done
    done
    [ ! -d "/sys/fs/cgroup/$fixture" ] || find "/sys/fs/cgroup/$fixture" -depth -type d -exec rmdir {} \; 2>/dev/null || :
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { echo "cgroupns-integration: $*" >&2; exit 1; }

rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/sys"
cp "$busybox" "$rootfs/bin/busybox"
for applet in sh cat echo grep cut mkdir sleep readlink; do ln -s busybox "$rootfs/bin/$applet"; done
# The probe is a file, so its quoting never meets config.json.
cat > "$rootfs/bin/probe" <<'EOF'
#!/bin/sh
cat /proc/self/cgroup
grep " /sys/fs/cgroup " /proc/self/mounts | cut -d" " -f3,4 | cut -d, -f1
grep -qx 1 /sys/fs/cgroup/cgroup.procs && echo init-in-root
mkdir /sys/fs/cgroup/child 2>/dev/null || echo readonly
EOF
chmod 755 "$rootfs/bin/probe"
# config NAME ARGS NAMESPACES
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
    {"destination": "/sys/fs/cgroup", "type": "cgroup", "source": "cgroup", "options": ["ro", "nosuid", "noexec", "nodev"]}
  ],
  "linux": {"namespaces": $3, "cgroupsPath": "/$fixture/$1"}
}
EOF
}
namespaces='[{"type": "pid"}, {"type": "mount"}, {"type": "cgroup"}]'
expected='0::/
cgroup2 ro
init-in-root
readonly'
for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; *) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    tag=cgns-run-$impl
    config "$tag" '["/bin/probe"]' "$namespaces"
    $rt run --bundle "$scratch/$tag" "$tag" > "$scratch/$tag.out" 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: run failed"; }
    [ "$(cat "$scratch/$tag.out")" = "$expected" ] || { cat "$scratch/$tag.out"; fail "$tag: init view differs"; }

    # Exec joins the init's namespace; its own cgroup is the namespace root.
    tag=cgns-exec-$impl
    config "$tag" '["/bin/sleep", "1000"]' "$namespaces"
    $rt create --bundle "$scratch/$tag" "$tag" < /dev/null > /dev/null 2>&1
    $rt start "$tag"
    init=$($rt state "$tag" | sed -n 's/.*"pid" *: *\([0-9]*\).*/\1/p')
    $rt exec "$tag" /bin/sh -c 'cat /proc/self/cgroup; readlink /proc/self/ns/cgroup' > "$scratch/$tag.out"
    [ "$(sed -n 1p "$scratch/$tag.out")" = '0::/' ] || { cat "$scratch/$tag.out"; fail "$tag: exec cgroup view differs"; }
    [ "$(sed -n 2p "$scratch/$tag.out")" = "$(readlink "/proc/$init/ns/cgroup")" ] || {
        echo "init $init: $(readlink "/proc/$init/ns/cgroup")"; cat "$scratch/$tag.out"; $rt state "$tag"
        fail "$tag: exec is not in the init's cgroup namespace"
    }
    [ "$(readlink "/proc/$init/ns/cgroup")" != "$(readlink /proc/self/ns/cgroup)" ] || fail "$tag: init shares the host cgroup namespace"
    $rt delete --force "$tag"
    echo "$impl: cgroup namespace rooted at the container cgroup, read-only cgroup2 mount, exec joins the namespace"
done

tag=cgns-refused
config "$tag" '["/bin/echo", "must-not-run"]' '[{"type": "pid"}, {"type": "mount"}]'
if $ours run --bundle "$scratch/$tag" "$tag" > "$scratch/$tag.out" 2> "$scratch/$tag.err"; then fail "$tag: run succeeded"; fi
grep -qF 'requires a cgroup namespace' "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: wrong error"; }
[ ! -s "$scratch/$tag.out" ] || fail "$tag: workload ran"
echo 'swift: cgroup mount without a cgroup namespace refused'
echo 'Cgroup namespace integration passed.'
