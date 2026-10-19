#!/bin/sh
# Rootless operation as an unprivileged host user (uid 1000), compared with
# runc: the unmodified `spec --rootless` starter runs (only terminal is
# turned off) with container root mapped to the caller and setgroups denied;
# exit statuses propagate; create/start/state/exec/kill/delete work without a
# cgroup and keep state below $XDG_RUNTIME_DIR by default; requested
# additionalGids fail under a direct map; a multi-ID map goes through
# newuidmap/newgidmap and /etc/subuid; requested resources fail without a
# delegated cgroup; pause fails without a cgroup. Every failure leaves no state.
#
# Run as root inside a disposable Linux VM: it creates uid 1000 if missing and
# appends its /etc/subuid and /etc/subgid ranges. Requires a statically linked
# BusyBox (BUSYBOX, default /bin/busybox), util-linux setpriv and unshare, the
# uidmap package (newuidmap/newgidmap), and unprivileged user namespaces.
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/srunc}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-auto}
uid=1000
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
xdg=$scratch/xdg
results=$scratch/results

fail() {
    echo "rootless-integration: $*" >&2
    exit 1
}

[ "$(id -u)" = 0 ] || fail "must run as root (it prepares uid $uid)"
if ldd "$busybox" >/dev/null 2>&1; then fail "BusyBox at $busybox must be statically linked"; fi
for tool in setpriv unshare newuidmap newgidmap; do
    command -v "$tool" >/dev/null || fail "$tool is required (util-linux, uidmap)"
done
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

# The unprivileged caller: an existing uid 1000 or a new user, with a
# subordinate range for the helper maps and its own XDG runtime directory.
getent passwd "$uid" >/dev/null || useradd -u "$uid" -M -N -d /nonexistent sct-rootless
user=$(getent passwd "$uid" | cut -d: -f1)
gid=$(getent passwd "$uid" | cut -d: -f4)
grep -q "^$user:" /etc/subuid 2>/dev/null || echo "$user:200000:65536" >> /etc/subuid
grep -q "^$user:" /etc/subgid 2>/dev/null || echo "$user:200000:65536" >> /etc/subgid
subuid=$(grep "^$user:" /etc/subuid | head -n 1 | cut -d: -f2)
subgid=$(grep "^$user:" /etc/subgid | head -n 1 | cut -d: -f2)
# env -i: nothing from root's environment reaches the unprivileged runtime.
as_user() {
    setpriv --reuid "$uid" --regid "$gid" --init-groups -- \
        env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME="$scratch" XDG_RUNTIME_DIR="$xdg" "$@"
}
ours="timeout -k 2 30 $runtime"
theirs="timeout -k 2 30 runc"

cleanup() {
    for rt in "$ours" "$theirs"; do
        for id in $(as_user $rt list -q 2>/dev/null); do as_user $rt delete --force "$id" >/dev/null 2>&1 || :; done
    done
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

chmod 755 "$scratch"
mkdir -p "$xdg" "$results"
chown "$uid:$gid" "$xdg" "$results"
chmod 700 "$xdg"
as_user unshare --user --map-root-user true \
    || fail "uid $uid cannot create a user namespace (kernel.unprivileged_userns_clone or apparmor_restrict_unprivileged_userns?)"

# A read-only BusyBox rootfs, owned by the host's root as an image would be.
rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/sys" "$rootfs/tmp"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done

bundles=$scratch/bundles
mkdir -p "$bundles"
chown "$uid:$gid" "$bundles"
# write_config NAME USER_JSON LINUX_EXTRA ARGS_JSON: the rootless starter's
# namespaces and mounts with explicit maps; LINUX_EXTRA adds linux fields.
write_config() {
    as_user mkdir -p "$bundles/$1"
    cat > "$results/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs", "readonly": true},
  "process": {"cwd": "/", "args": $4, "env": ["PATH=/bin"], "user": $2},
  "hostname": "rootless",
  "mounts": [
    {"destination": "/proc", "type": "proc", "source": "proc"},
    {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
    {"destination": "/dev/pts", "type": "devpts", "source": "devpts", "options": ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620"]},
    {"destination": "/sys", "type": "none", "source": "/sys", "options": ["rbind", "nosuid", "noexec", "nodev", "ro"]}
  ],
  "linux": {
    "namespaces": [{"type": "pid"}, {"type": "ipc"}, {"type": "uts"}, {"type": "mount"}, {"type": "user"}],
    "maskedPaths": ["/proc/kcore", "/sys/firmware"],
    "readonlyPaths": ["/proc/sys"]$3
  }
}
EOF
    as_user sh -c "cat > '$bundles/$1/config.json'" < "$results/config.json"
}
own_maps=',
    "uidMappings": [{"containerID": 0, "hostID": '"$uid"', "size": 1}],
    "gidMappings": [{"containerID": 0, "hostID": '"$gid"', "size": 1}]'
root_user='{"uid": 0, "gid": 0}'
# alive PID: exists and has not exited. Zombies count as exited: a detached
# init's reaper may be a PID 1 that never reaps (as in CI job containers).
alive() {
    stat_line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    state=${stat_line##*) }
    case "${state%% *}" in Z | X | x | '') return 1 ;; esac
}
# A container ID records no state when the runtime lists none.
no_state() { [ -z "$(as_user $1 list -q)" ] || fail "$2 left state: $(as_user $1 list -q)"; }

for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; runc) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    out=$results/$impl

    # The generated starter, unmodified except for terminal: its default
    # `sh` reads the probe from stdin.
    starter=$bundles/starter-$impl
    as_user mkdir -p "$starter/rootfs"
    as_user sh -c "cd '$starter' && $rt spec --rootless" || fail "$impl spec --rootless"
    as_user sed -i 's/"terminal" *: *true/"terminal": false/' "$starter/config.json"
    rmdir "$starter/rootfs" && cp -a "$rootfs" "$starter/rootfs"
    printf '%s\n' 'id -u; id -g; cat /proc/self/uid_map /proc/self/gid_map /proc/self/setgroups; touch /probe 2>&1; true' \
        | as_user sh -c "cd '$starter' && $rt run starter-$impl" > "$out.starter" 2>&1 \
        || { cat "$out.starter"; fail "$impl starter run"; }
    [ "$(sed -n 1p "$out.starter")" = 0 ] && [ "$(sed -n 2p "$out.starter")" = 0 ] || { cat "$out.starter"; fail "$impl starter ids"; }
    grep -Eq "^ +0 +$uid +1$" "$out.starter" || fail "$impl starter uid map"
    grep -Eq "^ +0 +$gid +1$" "$out.starter" || fail "$impl starter gid map"
    grep -qx deny "$out.starter" || fail "$impl starter setgroups"
    grep -q 'Read-only file system' "$out.starter" || fail "$impl starter root is writable"
    no_state "$rt" "$impl starter run"

    # Exit status propagation in the foreground.
    write_config "exit-$impl" "$root_user" "$own_maps" '["/bin/sh", "-c", "exit 7"]'
    status=0
    as_user $rt run --bundle "$bundles/exit-$impl" "exit-$impl" < /dev/null || status=$?
    [ "$status" = 7 ] || fail "$impl exit status $status"

    # Persistent lifecycle without a cgroup, in the default state root.
    write_config "life-$impl" "$root_user" "$own_maps" '["/bin/sleep", "1000"]'
    as_user $rt create --bundle "$bundles/life-$impl" "life-$impl" < /dev/null > /dev/null 2> "$out.create" \
        || { cat "$out.create"; fail "$impl create"; }
    pid=$(as_user $rt state "life-$impl" | sed -n 's/.*"pid" *: *\([0-9]*\).*/\1/p')
    [ -n "$pid" ] || fail "$impl state has no pid"
    grep -Eq "^Uid:[[:space:]]+${uid}[[:space:]]" "/proc/$pid/status" || fail "$impl init host uid"
    as_user $rt start "life-$impl"
    as_user $rt state "life-$impl" | grep -q '"running"' || fail "$impl not running after start"
    as_user $rt exec "life-$impl" /bin/sh -c 'id -u; hostname' > "$out.exec" || fail "$impl exec"
    [ "$(cat "$out.exec")" = "0
rootless" ] || { cat "$out.exec"; fail "$impl exec output"; }
    as_user $rt pause "life-$impl" > /dev/null 2>&1 && fail "$impl paused a container without a cgroup"
    as_user $rt kill "life-$impl" KILL
    i=0
    until as_user $rt state "life-$impl" | grep -q '"stopped"'; do
        i=$((i + 1)); [ "$i" -lt 50 ] || fail "$impl init did not stop"; sleep 0.1
    done
    as_user $rt delete "life-$impl"
    if alive "$pid"; then fail "$impl init survived delete"; fi
    no_state "$rt" "$impl delete"

    # setgroups is denied under a direct map, so requested groups fail.
    write_config "groups-$impl" '{"uid": 0, "gid": 0, "additionalGids": [5]}' "$own_maps" '["/bin/true"]'
    as_user $rt run --bundle "$bundles/groups-$impl" "groups-$impl" < /dev/null > "$out.groups" 2>&1 \
        && fail "$impl accepted additionalGids with setgroups denied"
    no_state "$rt" "$impl additionalGids"

    # Requested resources need a delegated cgroup, which uid 1000 lacks here.
    write_config "limits-$impl" "$root_user" "$own_maps"',
    "resources": {"pids": {"limit": 64}}' '["/bin/true"]'
    as_user $rt run --bundle "$bundles/limits-$impl" "limits-$impl" < /dev/null > "$out.limits" 2>&1 \
        && fail "$impl ran resources without a delegated cgroup"
    no_state "$rt" "$impl resources"

    # Subordinate IDs through newuidmap/newgidmap; setgroups stays allowed.
    helper_maps=',
    "uidMappings": [{"containerID": 0, "hostID": '"$uid"', "size": 1}, {"containerID": 1, "hostID": '"$subuid"', "size": 65536}],
    "gidMappings": [{"containerID": 0, "hostID": '"$gid"', "size": 1}, {"containerID": 1, "hostID": '"$subgid"', "size": 65536}]'
    write_config "helper-$impl" '{"uid": 1000, "gid": 1000}' "$helper_maps" \
        '["/bin/sh", "-c", "id -u; id -g; cat /proc/self/uid_map /proc/self/setgroups"]'
    as_user $rt run --bundle "$bundles/helper-$impl" "helper-$impl" < /dev/null > "$out.helper" 2>&1 \
        || { cat "$out.helper"; fail "$impl helper maps"; }
    [ "$(sed -n 1p "$out.helper")" = 1000 ] && [ "$(sed -n 2p "$out.helper")" = 1000 ] \
        || { cat "$out.helper"; fail "$impl helper ids"; }
    grep -Eq "^ +1 +$subuid +65536$" "$out.helper" || fail "$impl helper uid map"
    grep -qx allow "$out.helper" || fail "$impl helper setgroups"
    no_state "$rt" "$impl helper maps"

    # A map the subordinate ranges do not grant is refused by the helper.
    bad_maps=',
    "uidMappings": [{"containerID": 0, "hostID": '"$uid"', "size": 1}, {"containerID": 1, "hostID": 1, "size": 10}],
    "gidMappings": [{"containerID": 0, "hostID": '"$gid"', "size": 1}]'
    write_config "refused-$impl" "$root_user" "$bad_maps" '["/bin/true"]'
    as_user $rt run --bundle "$bundles/refused-$impl" "refused-$impl" < /dev/null > "$out.refused" 2>&1 \
        && fail "$impl installed a map outside /etc/subuid"
    no_state "$rt" "$impl refused map"
done

# This runtime only: the state root defaulted to $XDG_RUNTIME_DIR, failures
# say why, and supplementary groups apply when newgidmap leaves setgroups
# allowed (runc refuses any additionalGids when rootless).
[ -d "$xdg/swift-container-runtime" ] || fail "swift state root is not below XDG_RUNTIME_DIR"
grep -q 'setgroups is denied' "$results/swift.groups" || { cat "$results/swift.groups"; fail "additionalGids error"; }
grep -q 'newuidmap refused' "$results/swift.refused" || { cat "$results/swift.refused"; fail "helper error"; }
write_config groups-helper '{"uid": 0, "gid": 0, "additionalGids": [5]}' "$helper_maps" '["/bin/id", "-G"]'
as_user $ours run --bundle "$bundles/groups-helper" groups-helper < /dev/null > "$results/swift.groups-helper" 2>&1 \
    || { cat "$results/swift.groups-helper"; fail "additionalGids with newgidmap"; }
[ "$(cat "$results/swift.groups-helper")" = "0 5" ] || { cat "$results/swift.groups-helper"; fail "groups with newgidmap"; }

echo "Rootless integration passed (runc comparison: $compare)."
