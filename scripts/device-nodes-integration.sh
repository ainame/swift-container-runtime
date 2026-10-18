#!/bin/sh
# Custom character/block/FIFO nodes, exact modes/owners and symlink refusal.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-device-nodes-$$
. "$(dirname -- "$0")/cpu-integration.sh"
nodes='[
 {"path":"/dev/custom/null","type":"c","major":1,"minor":3,"fileMode":432,"uid":1000,"gid":2000},
 {"path":"/dev/block","type":"b","major":8,"minor":1,"fileMode":384},
 {"path":"/dev/fifo","type":"p","fileMode":416}
]'
for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; runc) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    tag=device-nodes-$impl path=/$fixture/device-nodes-$impl
    fields=$(cgroup_fields "$path" '{}')',"devices":'"$nodes"
    write_config "$tag" "$root" "$fields" '["/bin/sh","-ec","test -c /dev/custom/null; test -b /dev/block; test -p /dev/fifo; stat -c %a:%u:%g /dev/custom/null; stat -c %a /dev/block /dev/fifo; printf works > /dev/custom/null"]'
    step "$tag" $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag"
    printf '660:1000:2000\n600\n640\n' > "$results/expected"
    cmp "$results/expected" "$results/$tag" || fail "$impl device permissions or ownership"
done
# A symlink parent in the rootfs must not redirect mknod outside it.
mkdir "$scratch/outside"
ln -s "$scratch/outside" "$rootfs/device-escape"
tag=device-escape path=/$fixture/device-escape
fields=$(cgroup_fields "$path" '{}')',"devices":[{"path":"/device-escape/node","type":"p"}]'
write_config "$tag" "$root" "$fields" '["/bin/true"]'
expect_failure "$ours" "$tag" foreground ''
[ ! -e "$scratch/outside/node" ] || fail 'device node escaped the rootfs'
echo 'Custom device nodes integration passed.'
