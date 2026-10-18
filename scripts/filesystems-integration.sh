#!/bin/sh
# Engine-requested filesystems and readonly mount flags against runc.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-filesystems-$$
. "$(dirname -- "$0")/cpu-integration.sh"
"$cc" -static -O2 -Wall -Wextra -Werror "$here/fixtures/mount-probe.c" -lrt -o "$rootfs/bin/mount-probe"
queue=/sct-filesystems-$$
"$rootfs/bin/mount-probe" host-create "$queue"
# The fixture's existing cleanup owns workloads and cgroups; also unlink only
# this fixture's host IPC queue on both success and failure.
trap '"$rootfs/bin/mount-probe" host-remove "$queue" || :; cleanup' EXIT
namespaces='[{"type":"pid"},{"type":"mount"},{"type":"uts"},{"type":"ipc"},{"type":"network"}]'
mounts='[
 {"destination":"/proc","type":"proc","options":["nosuid","noexec","nodev"]},
 {"destination":"/dev","type":"tmpfs","options":["nosuid","mode=755"]},
 {"destination":"/dev/shm","type":"tmpfs","source":"shm","options":["nosuid","noexec","nodev","mode=1777","size=65536k"]},
 {"destination":"/dev/mqueue","type":"mqueue","options":["nosuid","noexec","nodev"]},
 {"destination":"/sys","type":"sysfs","options":["nosuid","noexec","nodev","ro"]},
 {"destination":"/readonly","type":"tmpfs","options":["ro"]}
]'
expected='sysfs-ro-net-private mqueue-private shm-tmpfs readonly-EROFS ok'
exercise() {
    impl=$1 rt=$2
    for mode in foreground created; do
        tag=fs-$mode-$impl
        path=/$fixture/$tag
        case "$mode" in
            foreground) args='["/bin/mount-probe","check","'"$queue"'"]' ;;
            created) args='["/bin/sh","-ec","/bin/mount-probe check '"$queue"'; exec /bin/sleep 1000"]' ;;
        esac
        write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" "$args"
        if [ "$mode" = foreground ]; then
            step "$tag" $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        else
            step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            init=$(pid_of "$rt" "$tag")
            # Mounts already exist before init is allowed to execute.
            grep -q ' /sys ro,.* - sysfs ' "/proc/$init/mountinfo" || fail "created sysfs mount missing or writable"
            grep -q ' /dev/mqueue .* - mqueue ' "/proc/$init/mountinfo" || fail "created mqueue mount missing"
            step "$tag" $rt start "$tag"
            wait_until "$tag probe" grep -q "$expected" "$results/$tag.stdout"
            step "$tag" $rt exec "$tag" /bin/mount-probe check "$queue" > "$results/$tag.exec" 2> "$results/$tag.stderr"
            grep -qx "$expected" "$results/$tag.exec" || fail "exec mount/IPC result differs"
            step "$tag" $rt kill "$tag" KILL
            wait_status "$rt" "$tag" stopped
            step "$tag" $rt delete "$tag"
        fi
        grep -qx "$expected" "$results/$tag.stdout" || fail "$tag mount/IPC result differs"
        [ ! -d "$cg$path" ] || fail "$tag cgroup left behind"
    done
    echo "$impl: engine filesystems, readonly flags, private IPC, create/start and exec passed"
}
exercise swift "$ours"
if [ "$compare" = 1 ]; then exercise runc "$theirs"; fi
# A symlinked sysfs target must fail after the preceding mounts, with no
# workload, state, cgroup or mount escaping into this fixture's outside path.
rmdir "$rootfs/sys"
mkdir "$scratch/outside"
echo unchanged > "$scratch/outside/sentinel"
outside_type=$(stat -f -c %T "$scratch/outside")
ln -s "$scratch/outside" "$rootfs/sys"
for impl in swift runc; do
    if [ "$impl" = runc ] && [ "$compare" != 1 ]; then continue; fi
    case "$impl" in swift) rt=$ours message='resolve mount destination' ;; runc) rt=$theirs message= ;; esac
    tag=fs-symlink-$impl
    path=/$fixture/$tag
    write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/echo","must-not-run"]'
    for mode in foreground created; do expect_failure "$rt" "$tag" "$mode" "$message"; done
    [ ! -d "$cg$path" ] || fail "failed mount left cgroup"
    [ "$(stat -f -c %T "$scratch/outside")" = "$outside_type" ] || fail "host mount changed"
    [ "$(cat "$scratch/outside/sentinel")" = unchanged ] || fail "host content changed"
done
# The host namespace queue remains until the EXIT trap unlinks it.
# O_EXCL must still fail here; successful creation would mean the workload
# removed the host's queue instead of its private namesake.
if "$rootfs/bin/mount-probe" host-create "$queue" 2>/dev/null; then fail "host queue was removed"; fi
[ -r /sys/kernel/uevent_seqnum ] || fail "host sysfs changed"
echo "Filesystems integration passed."
