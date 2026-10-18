#!/bin/sh
# Device cgroup enforcement in init and exec, plus adopted-filter ownership.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-devices-$$
. "$(dirname -- "$0")/cpu-integration.sh"
"$cc" -static -O2 -Wall -Wextra -Werror "$here/fixtures/device-probe.c" -o "$rootfs/bin/device-probe"
"$cc" -O2 -Wall -Wextra -Werror "$here/fixtures/device-bpf-probe.c" -o "$scratch/bpf"
policy() {
    case "$1" in
        deny) echo '[{"allow":false,"access":"rwm"}]' ;;
        allow) echo '[{"allow":false,"access":"rwm"},{"allow":true,"type":"c","major":137,"access":"rwm"}]' ;;
        write) echo '[{"allow":false,"access":"rwm"},{"allow":true,"type":"c","major":137,"access":"w"}]' ;;
        blacklist) echo '[{"allow":true,"access":"rwm"},{"allow":false,"type":"c","major":137,"minor":0,"access":"r"}]' ;;
        no-mknod) echo '[{"allow":true,"access":"rwm"},{"allow":false,"type":"c","major":137,"minor":0,"access":"m"}]' ;;
    esac
}
fields() { printf ', "cgroupsPath":"%s", "resources":{"devices":%s}' "$1" "$(policy "$2")"; }
exercise() {
    impl=$1 rt=$2
    modes='deny allow write no-mknod'
    [ "$impl" != swift ] || modes="$modes blacklist"
    for mode in $modes; do
        tag=devices-$mode-$impl
        path=/$fixture/$tag
        write_config "$tag" "$root" "$(fields "$path" "$mode")" '["/bin/sh","-ec","/bin/device-probe '"$mode"'; exec /bin/sleep 1000"]'
        step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        [ "$("$scratch/bpf" count "$cg$path")" -eq 1 ] || fail "$tag filter missing before start"
        step "$tag" $rt start "$tag"
        wait_until "$tag init probe" grep -q "device policy $mode enforced" "$results/$tag.stdout"
        if [ "$impl" = swift ] && [ "$mode" = deny ]; then
            step "$tag" $rt update --pids-limit 64 "$tag"
            printf '{"devices":[]}' > "$results/device-patch.json"
            if $rt update --resources "$results/device-patch.json" "$tag" > /dev/null 2> "$results/patch.err"; then fail "unsupported live device update accepted"; fi
            [ "$("$scratch/bpf" count "$cg$path")" -eq 1 ] || fail "resource update changed device filter"
        fi
        step "$tag" $rt exec "$tag" /bin/device-probe "$mode" > "$results/$tag.exec" 2> "$results/$tag.stderr"
        grep -qx "device policy $mode enforced" "$results/$tag.exec" || fail "$tag exec escaped policy"
        step "$tag" $rt kill "$tag" KILL
        wait_status "$rt" "$tag" stopped
        step "$tag" $rt delete "$tag"
        [ ! -d "$cg$path" ] || fail "$tag cgroup leaked"
    done
    echo "$impl: device allow/deny, access masks and mknod apply to init and exec"
}
exercise swift "$ours"
if [ "$compare" = 1 ]; then exercise runc "$theirs"; fi

# Keep a separately attached program on an adopted leaf. Failed create and
# normal delete must remove only the runtime's own program, retaining this one.
path=/$fixture/adopted
mkdir "$cg$path"
external=$("$scratch/bpf" allow "$cg$path")
tag=devices-adopted
write_config "$tag" "$root" "$(fields "$path" deny)" '["/bin/sleep","1000"]'
step "$tag" $ours run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
[ "$("$scratch/bpf" count "$cg$path")" -eq 2 ] || fail "owned filter replaced external filter"
step "$tag" $ours delete --force "$tag"
[ "$("$scratch/bpf" count "$cg$path")" -eq 1 ] || fail "delete leaked owned filter or detached external filter"
write_config "$tag" "$root" "$(fields "$path" deny)" '["/missing-program"]'
expect_failure "$ours" "$tag" created 'exec workload'
[ "$("$scratch/bpf" count "$cg$path")" -eq 1 ] || fail "failed create leaked owned filter"
"$scratch/bpf" detach "$cg$path" "$external"
rmdir "$cg$path"

# A child filter must never override a restrictive ancestor's filter.
parent=/$fixture/inherited
mkdir "$cg$parent"
external=$("$scratch/bpf" deny137 "$cg$parent")
tag=devices-inherited
path=$parent/leaf
write_config "$tag" "$root" "$(fields "$path" allow)" '["/bin/device-probe","deny"]'
step "$tag" $ours run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
grep -qx 'device policy deny enforced' "$results/$tag.stdout" || fail "child filter bypassed ancestor"
[ "$("$scratch/bpf" count "$cg$parent")" -eq 1 ] || fail "ancestor program changed"
"$scratch/bpf" detach "$cg$parent" "$external"
rmdir "$cg$parent"

# No BPF privilege must be a synchronous failure, never an unrestricted launch.
tag=devices-no-bpf
path=/$fixture/$tag
write_config "$tag" "$root" "$(fields "$path" deny)" '["/bin/echo","must-not-run"]'
restricted="setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-sys_admin,-bpf $ours"
expect_failure "$restricted" "$tag" created 'load device BPF filter'
[ ! -d "$cg$path" ] || fail "failed BPF load left a cgroup"
echo "Device integration passed: enforcement, ownership and fail-closed setup."
