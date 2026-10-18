#!/bin/sh
# Requested AppArmor/SELinux labels: availability failures before launch,
# empty labels, exec overrides and cleanup. Positive label application needs
# a host with the module enabled; this suite reports which case it covered.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-lsm-$$
. "$(dirname -- "$0")/cpu-integration.sh"

apparmor=0
if [ -e /sys/kernel/security/apparmor ] && grep -q '^Y' /sys/module/apparmor/parameters/enabled 2>/dev/null; then apparmor=1; fi
selinux=0
if [ "$(stat -f -c %t /sys/fs/selinux 2>/dev/null)" = f97cff8c ] && [ "$(tr -d '\0\n' < /proc/self/attr/current)" != kernel ]; then selinux=1; fi
echo "host: AppArmor enabled=$apparmor, SELinux enabled=$selinux"

# configure TAG PROCESS_FIELDS LINUX_FIELDS ARGS
configure() {
    write_config "$1" "$root" "$(cgroup_fields "/$fixture/$1" '{}')$3" "$4"
    if [ -n "$2" ]; then
        sed "s/\"terminal\": false/\"terminal\": false, $2/" "$bundles/$1/config.json" > "$scratch/config"
        mv "$scratch/config" "$bundles/$1/config.json"
    fi
}
no_cgroup() { [ ! -d "$cg/$fixture/$1" ] || fail "$1: cgroup leaked"; }

# Empty labels request nothing, as engines write them on hosts without LSMs.
for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; *) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    tag=lsm-empty-$impl
    configure "$tag" '"apparmorProfile": "", "selinuxLabel": ""' ', "mountLabel": ""' '["/bin/echo","ran"]'
    step "$tag" $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    [ "$(cat "$results/$tag.stdout")" = ran ] || fail "$tag: workload did not run"
    no_cgroup "$tag"
done
echo 'swift: empty AppArmor/SELinux/mount labels run unchanged'

# Requested but unavailable modules fail create and run before any workload,
# state or cgroup exists. runc's AppArmor write falls back to attr/exec, which
# an SELinux kernel without a policy accepts, so runc is not compared there.
if [ "$apparmor" = 0 ]; then
    tag=lsm-apparmor
    configure "$tag" '"apparmorProfile": "docker-default"' '' '["/bin/echo","must-not-run"]'
    for mode in foreground created; do expect_failure "$ours" "$tag" "$mode" 'AppArmor is not enabled'; done
    no_cgroup "$tag"
    echo 'swift: unavailable AppArmor profile refused for run/create without state or cgroup'
fi
if [ "$selinux" = 0 ]; then
    tag=lsm-selinux
    configure "$tag" '"selinuxLabel": "system_u:system_r:container_t:s0"' '' '["/bin/echo","must-not-run"]'
    for mode in foreground created; do expect_failure "$ours" "$tag" "$mode" 'SELinux is disabled'; done
    if [ "$compare" = 1 ]; then
        for mode in foreground created; do expect_failure "$theirs" "$tag" "$mode" 'selinux'; done
    fi
    no_cgroup "$tag"
    echo 'swift/runc: unavailable SELinux label refused for run/create without state or cgroup'
fi
tag=lsm-mount-label
configure "$tag" '' ', "mountLabel": "system_u:object_r:container_file_t:s0"' '["/bin/echo","must-not-run"]'
for mode in foreground created; do expect_failure "$ours" "$tag" "$mode" 'linux.mountLabel'; done
no_cgroup "$tag"
echo 'swift: nonempty linux.mountLabel refused'

# An exec process label is checked like init's, leaving the container intact.
if [ "$apparmor" = 0 ] || [ "$selinux" = 0 ]; then
    tag=lsm-exec
    configure "$tag" '' '' '["/bin/sleep","1000"]'
    step "$tag" $ours create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    step "$tag" $ours start "$tag"
    if [ "$apparmor" = 0 ]; then
        field='"apparmorProfile":"docker-default"' reason='AppArmor is not enabled'
    else
        field='"selinuxLabel":"system_u:system_r:container_t:s0"' reason='SELinux is disabled'
    fi
    printf '{"args":["/bin/echo","must-not-run"],"cwd":"/","user":%s,%s}' "$root" "$field" > "$scratch/process.json"
    if $ours exec --process "$scratch/process.json" "$tag" > "$results/$tag.exec" 2> "$results/$tag.exec-stderr"; then
        fail "$tag: exec with an unavailable label succeeded"
    fi
    grep -qF "$reason" "$results/$tag.exec-stderr" || { cat "$results/$tag.exec-stderr"; fail "$tag: expected '$reason'"; }
    [ ! -s "$results/$tag.exec" ] || fail "$tag: exec workload ran"
    $ours state "$tag" | grep -q '"running"' || fail "$tag: container no longer running"
    # Without an override the recorded (empty) labels apply.
    step "$tag" $ours exec "$tag" /bin/echo ok > "$results/$tag.exec" 2> "$results/$tag.exec-stderr"
    [ "$(cat "$results/$tag.exec")" = ok ] || fail "$tag: plain exec failed"
    step "$tag" $ours delete --force "$tag"
    no_cgroup "$tag"
    echo 'swift: unavailable exec process label refused; container and plain exec unaffected'
fi
if [ "$apparmor" = 1 ] || [ "$selinux" = 1 ]; then
    echo 'note: positive label application is not exercised by this suite yet' >&2
fi
echo 'LSM integration passed.'
