#!/bin/sh
# Rootful UID/GID maps, created-init readback, exec and mapping failure cleanup.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-userns-$$
. "$(dirname -- "$0")/cpu-integration.sh"
# The mapped root must be able to search the supplied rootfs path.
chmod 755 "$scratch"
maps=',"uidMappings":[{"containerID":0,"hostID":1000,"size":1000}],"gidMappings":[{"containerID":0,"hostID":2000,"size":1000}]'
namespaces='[{"type":"pid"},{"type":"mount"},{"type":"uts"},{"type":"ipc"},{"type":"network"},{"type":"user"}]'
for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; runc) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    tag=userns-$impl path=/$fixture/userns-$impl
    write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')$maps" '["/bin/sleep","1000"]'
    step "$tag" $rt create --bundle "$bundles/$tag" "$tag"
    # The supervisor sees parent-namespace IDs while init sees mapped IDs.
    pid=$($rt state "$tag" | field pid)
    grep -Eq '^Uid:[[:space:]]+1000[[:space:]]+1000' "/proc/$pid/status" || fail "$impl host UID"
    grep -Eq '^Gid:[[:space:]]+2000[[:space:]]+2000' "/proc/$pid/status" || fail "$impl host GID"
    step "$tag" $rt start "$tag"
    step "$tag" $rt exec "$tag" /bin/sh -ec 'id -u; id -g; cat /proc/self/uid_map; cat /proc/self/gid_map' > "$results/$tag"
    grep -qx 0 "$results/$tag" || fail "$impl exec mapped IDs"
    grep -Eq '^[[:space:]]+0[[:space:]]+1000[[:space:]]+1000$' "$results/$tag" || fail "$impl UID map"
    grep -Eq '^[[:space:]]+0[[:space:]]+2000[[:space:]]+1000$' "$results/$tag" || fail "$impl GID map"
    step "$tag" $rt delete --force "$tag"
done
# Init and exec share the named session keyring. A join refused by the
# keyring's permissions would silently create a separate keyring instead, so
# the identity and the init's key are compared. runc 1.4 adds other-search
# permission here, yet its exec still gets a new keyring; it is only reported.
"$cc" -static -O2 -Wall -Wextra -Werror "$here/fixtures/keyring-probe.c" -o "$rootfs/bin/keyring-probe"
ring() { sed -n 's/^keyring=//p' "$1"; }
for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; runc) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    tag=userns-keys-$impl path=/$fixture/userns-keys-$impl
    write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')$maps" '["/bin/keyring-probe","hold"]'
    step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    step "$tag" $rt start "$tag"
    wait_until 'userns keyring workload started' grep -q '^keyring=' "$results/$tag.stdout"
    step "$tag" $rt exec "$tag" /bin/keyring-probe inspect > "$results/$tag.exec" 2> "$results/$tag.stderr"
    shared=no
    [ -n "$(ring "$results/$tag.exec")" ] && [ "$(ring "$results/$tag.exec")" = "$(ring "$results/$tag.stdout")" ] \
        && grep -qx 'container-secret=1' "$results/$tag.exec" && shared=yes
    if [ "$impl" = swift ]; then
        [ "$shared" = yes ] || { cat "$results/$tag.stdout" "$results/$tag.exec"; fail 'swift exec did not join the init session keyring'; }
    else
        echo "runc: exec shares the init session keyring in a user namespace: $shared"
    fi
    step "$tag" $rt delete --force "$tag"
done
echo 'Rootful user namespace integration passed.'
