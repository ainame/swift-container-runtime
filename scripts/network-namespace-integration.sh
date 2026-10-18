#!/bin/sh
# Supplied network nsfs/proc paths, real private TCP, init/exec and failures.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-network-$$
. "$(dirname -- "$0")/cpu-integration.sh"
"$cc" -static -O2 -Wall -Wextra -Werror "$here/fixtures/network-probe.c" -o "$rootfs/bin/network-probe"
unshare --net "$rootfs/bin/network-probe" server "$results/port" &
holder=$!
fixture_pids="$fixture_pids $holder"
wait_until 'private namespace listener' test -s "$results/port"
port=$(cat "$results/port")
"$rootfs/bin/network-probe" outside "$port"
owner_namespace=$(readlink "/proc/$holder/ns/net")
host_namespace=$(readlink /proc/self/ns/net)
[ "$owner_namespace" != "$host_namespace" ] || fail 'holder did not create a private network'
namespace_file=$scratch/network.ns
restore_namespace_file() { touch "$namespace_file"; mount --bind "/proc/$holder/ns/net" "$namespace_file"; }
restore_namespace_file
trap 'umount "$namespace_file" 2>/dev/null || :; cleanup' EXIT
base_namespaces=$namespaces
exercise() {
    impl=$1 rt=$2
    for mode in foreground created; do
        tag=network-$mode-$impl
        path=/$fixture/$tag
        # Both proc namespace links and a bind-mounted nsfs path are accepted.
        case "$mode" in foreground) ns_path=/proc/$holder/ns/net ;; created) ns_path=$namespace_file ;; esac
        namespaces=$(printf '%s' "$base_namespaces" | sed 's/]$//')',{"type":"network","path":"'"$ns_path"'"}]'
        args='["/bin/network-probe","client","'"$port"'"]'
        [ "$mode" != created ] || args='["/bin/sh","-ec","/bin/network-probe client '"$port"'; exec /bin/sleep 1000"]'
        write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" "$args"
        if [ "$mode" = foreground ]; then
            step "$tag" $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        else
            step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            init=$(pid_of "$rt" "$tag")
            [ "$(readlink "/proc/$init/ns/net")" = "$owner_namespace" ] || fail 'created init joined wrong network'
            step "$tag" $rt start "$tag"
            wait_until "$tag connected" grep -q joined-network "$results/$tag.stdout"
            # Exec must use init's pinned namespace, not reopen the bundle path.
            umount "$namespace_file"
            rm "$namespace_file"
            step "$tag" $rt exec "$tag" /bin/network-probe client "$port" > "$results/$tag.exec" 2> "$results/$tag.stderr"
            grep -q joined-network "$results/$tag.exec" || fail 'exec lost joined namespace'
            step "$tag" $rt delete --force "$tag"
            restore_namespace_file
        fi
        grep -q joined-network "$results/$tag.stdout" || fail 'init did not connect'
        [ "$(readlink /proc/self/ns/net)" = "$host_namespace" ] || fail 'caller network changed'
        "$rootfs/bin/network-probe" outside "$port"
        [ ! -d "$cg$path" ] || fail 'namespace join leaked cgroup'
    done
    echo "$impl: proc/nsfs paths, private TCP, create-time identity and exec after path removal passed"
}
exercise swift "$ours"
if [ "$compare" = 1 ]; then exercise runc "$theirs"; fi

# Never run the workload after missing, ordinary-file, FIFO, wrong-type, or
# permission-denied namespace input. A malformed FIFO must not block bootstrap.
touch "$scratch/regular"
mkfifo "$scratch/fifo"
for invalid in missing regular fifo wrong-type; do
    tag=network-fail-$invalid path=/$fixture/network-fail-$invalid
    case "$invalid" in
        wrong-type) ns_path=/proc/$holder/ns/uts ;;
        *) ns_path=$scratch/$invalid ;;
    esac
    namespaces=$(printf '%s' "$base_namespaces" | sed 's/]$//')',{"type":"network","path":"'"$ns_path"'"}]'
    write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/echo","must-not-run"]'
    for mode in foreground created; do expect_failure "$ours" "$tag" "$mode" 'network namespace'; done
    [ ! -d "$cg$path" ] || fail 'invalid namespace leaked cgroup'
done
tag=network-no-privilege path=/$fixture/network-no-privilege
namespaces=$(printf '%s' "$base_namespaces" | sed 's/]$//')',{"type":"network","path":"/proc/'"$holder"'/ns/net"}]'
write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/echo","must-not-run"]'
restricted="setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-sys_admin $ours"
expect_failure "$restricted" "$tag" created 'join supplied network namespace'
[ ! -d "$cg$path" ] || fail 'failed setns leaked cgroup'
alive "$holder" || fail 'failed setup killed namespace owner'
[ "$(readlink /proc/self/ns/net)" = "$host_namespace" ] || fail 'failure changed caller namespace'
echo 'Network namespace integration passed.'
