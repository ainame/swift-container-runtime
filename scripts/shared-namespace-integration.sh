#!/bin/sh
# Inherited namespaces use chroot. Runtime-owned mounts must not outlive delete
# or a failed launch, and pre-existing host mounts must remain untouched.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-sharedns-$$
. "$(dirname -- "$0")/cpu-integration.sh"
namespaces='[]'
printf 'inherited namespaces\n' > "$rootfs/message"
cat /proc/self/mountinfo > "$results/host-mounts"
for mode in foreground created failure; do
    tag=sharedns-$mode path=/$fixture/sharedns-$mode
    case "$mode" in
        foreground) args='["/bin/cat","/message"]' ;;
        created) args='["/bin/sleep","1000"]' ;;
        failure) args='["/bin/does-not-exist"]' ;;
    esac
    write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" "$args"
    # No UTS namespace means no hostname change is permitted.
    sed -i '/"hostname":/d' "$bundles/$tag/config.json"
    case "$mode" in
        foreground)
            step "$tag" $ours run --bundle "$bundles/$tag" "$tag" > "$results/message"
            grep -qx 'inherited namespaces' "$results/message" || fail 'chroot workload output' ;;
        created)
            step "$tag" $ours create --bundle "$bundles/$tag" "$tag"
            pid=$($ours state "$tag" | field pid)
            for namespace in mnt pid uts ipc net user cgroup; do
                [ "$(readlink /proc/self/ns/$namespace)" = "$(readlink /proc/$pid/ns/$namespace)" ] || fail "unexpected new $namespace namespace"
            done
            step "$tag" $ours start "$tag"
            step "$tag" $ours delete --force "$tag" ;;
        failure) expect_failure "$ours" "$tag" foreground 'exec workload' ;;
    esac
    cmp "$results/host-mounts" /proc/self/mountinfo || fail "$mode leaked or changed host mounts"
done
# An explicit path to our own mount namespace must not take pivot_root's
# old-root detachment path. Inherit by omitting the mount entry instead.
namespaces='[{"type":"mount","path":"/proc/self/ns/mnt"}]'
tag=sharedns-explicit path=/$fixture/sharedns-explicit
write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/true"]'
sed -i '/"hostname":/d' "$bundles/$tag/config.json"
expect_failure "$ours" "$tag" foreground 'omit the mount namespace'
cmp "$results/host-mounts" /proc/self/mountinfo || fail 'explicit host mount path changed mounts'
echo 'Inherited namespace integration passed.'
