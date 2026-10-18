#!/bin/sh
# File/dir bind and rbind contracts, in-root targets and host isolation.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-bind-$$
. "$(dirname -- "$0")/cpu-integration.sh"
sources=$scratch/sources
mkdir "$sources"
mount -t tmpfs -o nosuid,nodev,noexec tmpfs "$sources"
# Detach only this fixture's source tree; runtime cleanup then kills any child
# namespaces still holding its clones before removing their state and rootfs.
trap 'umount -l "$sources" 2>/dev/null || :; cleanup' EXIT
mkdir -p "$sources/tree/sub" "$rootfs/etc" "$rootfs/targets" "$rootfs/outside"
mount -t tmpfs tmpfs "$sources/tree/sub"
mount --make-shared "$sources/tree/sub"
printf 'nested\n' > "$sources/tree/sub/nested"
printf 'readonly\n' > "$sources/read.txt"
printf 'initial\n' > "$sources/write.txt"
touch "$sources/readonly-source"
mount --bind "$sources/write.txt" "$sources/readonly-source"
mount -o remount,bind,ro "$sources/readonly-source"
printf '#!/bin/sh\nexit 0\n' > "$sources/script"
chmod 755 "$sources/script"
mknod "$sources/null" c 1 3
chmod 666 "$sources/null"
"$cc" -static -O2 -Wall -Wextra -Werror "$here/fixtures/bind-probe.c" -o "$rootfs/bin/bind-probe"
ln -s /etc "$rootfs/etc-link"
touch "$rootfs/targets/file" "$rootfs/outside/file"
ln -s /targets/file "$rootfs/absolute-link"
ln -s ../../../../outside/file "$rootfs/escape-link"
mkdir "$scratch/outside"
printf 'outside-host\n' > "$scratch/outside/file"
printf 'before-dev\n' > "$rootfs/dev/late-source"
printf 'before-dev\n' > "$sources/before-dev"
mkdir -p "$bundles"
printf 'relative\n' > "$bundles/relative-source"
base_mounts=$mounts
# Include all source and target forms used by ordinary engine bind mounts.
mounts=$(printf '%s' "$base_mounts" | sed '$s/]$//')',
 {"destination":"/new/etc/resolv.conf","type":"bind","source":"'"$sources/read.txt"'","options":["bind","ro","nosuid","nodev","noexec"]},
 {"destination":"/writable","type":"none","source":"'"$sources/readonly-source"'","options":["bind","rw"]},
 {"destination":"/strict","type":"bind","source":"'"$sources/read.txt"'","options":["bind","strictatime"]},
 {"destination":"/plain","type":"bind","source":"'"$sources/tree"'","options":["bind"]},
 {"destination":"/recursive","type":"bind","source":"'"$sources/tree"'","options":["rbind","ro","rprivate"]},
 {"destination":"/etc-link/hosts","type":"bind","source":"'"$sources/read.txt"'","options":["bind","ro"]},
 {"destination":"/absolute-link","type":"bind","source":"'"$sources/read.txt"'","options":["bind","ro"]},
 {"destination":"/escape-link","type":"bind","source":"'"$sources/read.txt"'","options":["bind","ro"]},
 {"destination":"/relative","type":"bind","source":"../relative-source","options":["bind","ro"]},
 {"destination":"/pinned","type":"bind","source":"'"$sources/before-dev"'","options":["bind","ro"]},
 {"destination":"/exec-blocked","type":"bind","source":"'"$sources/script"'","options":["bind","noexec"]},
 {"destination":"/exec-enabled","type":"bind","source":"'"$sources/script"'","options":["bind","exec"]},
 {"destination":"/device-blocked","type":"bind","source":"'"$sources/null"'","options":["bind","nodev"]},
 {"destination":"/device-allowed","type":"bind","source":"'"$sources/null"'","options":["bind","dev"]}
]'
cat /proc/self/mountinfo > "$results/host-mounts"
exercise() {
    impl=$1 rt=$2
    for mode in foreground created; do
        tag=bind-$mode-$impl
        path=/$fixture/$tag
        case "$mode" in
            foreground) args='["/bin/bind-probe"]' ;;
            created) args='["/bin/sh","-ec","/bin/bind-probe; exec /bin/sleep 1000"]' ;;
        esac
        write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" "$args"
        if [ "$mode" = foreground ]; then
            step "$tag" $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        else
            # A read-only root must not make explicitly writable binds readonly.
            sed -i 's/"path": "[^"]*"/&,"readonly":true/' "$bundles/$tag/config.json"
            step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            init=$(pid_of "$rt" "$tag")
            awk '$5 ~ /^\/recursive(\/|$)/ && /shared:|master:/ {exit 1}' "/proc/$init/mountinfo" || fail "rprivate was not applied"
            if [ "$impl" = swift ]; then
                awk '$5=="/absolute-link" || $5=="/targets/file" {if ($6 !~ /nosuid/ || $6 !~ /nodev/ || $6 !~ /noexec/) exit 1; found=1} END {if (!found) exit 1}' "/proc/$init/mountinfo" || fail "unmentioned source security flags were cleared"
            fi
            step "$tag" $rt start "$tag"
            wait_until "$tag probe" grep -q 'bind files/dirs' "$results/$tag.stdout"
            step "$tag" $rt exec "$tag" /bin/bind-probe > "$results/$tag.exec" 2> "$results/$tag.stderr"
            grep -qx 'bind files/dirs recursive flags symlinks and I/O ok' "$results/$tag.exec" || fail "exec bind view differs"
            step "$tag" $rt delete --force "$tag"
        fi
        grep -qx 'bind files/dirs recursive flags symlinks and I/O ok' "$results/$tag.stdout" || fail "$tag probe differs"
        [ "$(cat "$sources/write.txt")" = container-write ] || fail "rw file did not reach host source"
        [ "$(cat "$sources/tree/created")" = volume-write ] || fail "rw directory did not reach source"
        [ "$(cat "$sources/tree/sub/changed")" = submount-write ] || fail "rbind submount was not writable"
        [ "$(cat "$scratch/outside/file")" = outside-host ] || fail "symlink escaped root"
        [ "$(cat "$sources/read.txt")" = readonly ] || fail "ro source contents changed"
        cmp "$results/host-mounts" /proc/self/mountinfo || fail "host mount table changed"
        [ ! -d "$cg$path" ] || fail "$tag cgroup leaked"
    done
    echo "$impl: file/directory bind, rbind, readonly root, symlinks, attributes and exec passed"
}
exercise swift "$ours"
if [ "$compare" = 1 ]; then exercise runc "$theirs"; fi

# Pinning sources before earlier mounts is a Swift-only regression. Installed
# runc 1.4 resolves this source after /dev is hidden and rejects the bundle.
mounts=$(printf '%s' "$base_mounts" | sed '$s/]$//')',{"destination":"/pinned","type":"bind","source":"'"$rootfs/dev/late-source"'","options":["bind","ro"]}]'
tag=early-source-swift path=/$fixture/early-source
write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/cat","/pinned"]'
step "$tag" $ours run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
grep -qx before-dev "$results/$tag.stdout" || fail "source was hidden before being pinned"

# A bind replacing a /dev tmpfs must never populate the host-backed directory.
mkdir "$sources/dev"
mounts=$(printf '%s' "$base_mounts" | sed '$s/]$//')',{"destination":"/dev","type":"bind","source":"'"$sources/dev"'","options":["bind"]}]'
tag=host-dev-swift path=/$fixture/host-dev
write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/true"]'
step "$tag" $ours run --bundle "$bundles/$tag" "$tag"
[ -z "$(ls -A "$sources/dev")" ] || fail "runtime created nodes in host-backed /dev"

# A missing source fails before mounts; type mismatches fail after earlier
# mounts. Both errors leave state, processes, cgroups and host mounts untouched.
for failure in missing mismatch magic dangling; do
    tag=bind-fail-$failure path=/$fixture/bind-fail-$failure
    case "$failure" in
        missing) source=$sources/missing dest=/x ;;
        mismatch) source=$sources/read.txt dest=/etc ;;
        magic) source=$sources/read.txt dest=/magic-link; ln -s /proc/self/fd/0 "$rootfs/magic-link" ;;
        dangling) source=$sources/read.txt dest=/dangling; ln -s /missing-target "$rootfs/dangling" ;;
    esac
    mounts=$(printf '%s' "$base_mounts" | sed '$s/]$//')',{"destination":"'"$dest"'","type":"bind","source":"'"$source"'","options":["bind"]}]'
    write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/echo","must-not-run"]'
    for mode in foreground created; do expect_failure "$ours" "$tag" "$mode" ''; done
    [ ! -d "$cg$path" ] || fail "failed bind leaked cgroup"
    cmp "$results/host-mounts" /proc/self/mountinfo || fail "failed bind changed host mounts"
done
echo 'Bind integration passed.'
