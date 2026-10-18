#!/bin/sh
# Named per-container sessions, host-key exclusion, exec joining and opt-out.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-keyring-$$
. "$(dirname -- "$0")/cpu-integration.sh"
"$cc" -static -O2 -Wall -Wextra -Werror "$here/fixtures/keyring-probe.c" -o "$rootfs/bin/keyring-probe"
probe=$rootfs/bin/keyring-probe
ring() { sed -n 's/^keyring=//p' "$1"; }
check_view() {
    view=$1 policy=$2 caller_file=$3 expected_name=$4
    actual=$(ring "$view")
    [ -n "$actual" ] || { cat "$view" >&3; fail 'missing keyring ID'; }
    if [ "$policy" = default ]; then
        [ "$actual" != "$(cat "$caller_file")" ] || fail 'inherited caller session by default'
        grep -qx 'parent-secret=0' "$view" || fail 'caller key leaked into container session'
        grep -Eq '^description=keyring;[0-9]+;[0-9]+;[0-9a-fA-F]+;_ses\.'"$expected_name"'$' "$view" || fail 'wrong session name'
        permissions=$(sed -n 's/^description=//p' "$view" | cut -d';' -f4)
        [ $((0x$permissions & 0x80000)) != 0 ] || fail 'owner search permission missing'
    else
        [ "$actual" = "$(cat "$caller_file")" ] || fail 'no-new-keyring did not inherit caller'
        grep -qx 'parent-secret=1' "$view" || fail 'explicitly inherited key missing'
    fi
}
exercise() {
    impl=$1 rt=$2
    for label in root user; do
        case "$label" in root) credentials=$root ;; *) credentials=$user ;; esac
        for policy in default inherit; do
            flag=
            [ "$policy" = default ] || flag=--no-new-keyring
            tag=keys-$impl-$label-$policy
            write_config "$tag" "$credentials" "$(cgroup_fields "/$fixture/$tag" '{}')" '["/bin/keyring-probe","inspect"]'
            step "$tag" "$probe" parent "$results/$tag.parent" $rt run $flag --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            check_view "$results/$tag.stdout" "$policy" "$results/$tag.parent" "$tag"
            write_config "$tag" "$credentials" "$(cgroup_fields "/$fixture/$tag" '{}')" '["/bin/keyring-probe","hold"]'
            step "$tag" "$probe" parent "$results/$tag.parent" $rt create $flag --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            step "$tag" $rt start "$tag"
            wait_until 'keyring workload started' grep -q '^keyring=' "$results/$tag.stdout"
            check_view "$results/$tag.stdout" "$policy" "$results/$tag.parent" "$tag"
            init_ring=$(ring "$results/$tag.stdout")
            step "$tag" "$probe" parent "$results/$tag.exec-parent" $rt exec "$tag" /bin/keyring-probe inspect > "$results/$tag.exec" 2> "$results/$tag.stderr"
            check_view "$results/$tag.exec" "$policy" "$results/$tag.exec-parent" "$tag"
            if [ "$policy" = default ]; then
                [ "$(ring "$results/$tag.exec")" = "$init_ring" ] || fail 'exec did not join init session'
                grep -qx 'container-secret=1' "$results/$tag.exec" || fail 'exec lost container session keys'
            fi
            # Standalone exec gets the persisted policy after bundle removal.
            printf '{"args":["/bin/keyring-probe","inspect"],"cwd":"/","user":%s}' "$credentials" > "$scratch/process.json"
            rm -rf "$bundles/$tag"
            step "$tag" "$probe" parent "$results/$tag.exec-parent" $rt exec --process "$scratch/process.json" "$tag" > "$results/$tag.exec" 2> "$results/$tag.stderr"
            check_view "$results/$tag.exec" "$policy" "$results/$tag.exec-parent" "$tag"
            if [ "$policy" = default ]; then
                [ "$(ring "$results/$tag.exec")" = "$init_ring" ] || fail 'standalone exec lost session identity'
                # Another live container must get a different named session.
                second=$tag-other
                write_config "$second" "$credentials" "$(cgroup_fields "/$fixture/$second" '{}')" '["/bin/keyring-probe","hold"]'
                step "$second" "$probe" parent "$results/$second.parent" $rt run --detach --bundle "$bundles/$second" "$second" < /dev/null > "$results/$second.stdout" 2> "$results/$second.stderr"
                wait_until 'other keyring workload' grep -q '^keyring=' "$results/$second.stdout"
                check_view "$results/$second.stdout" default "$results/$second.parent" "$second"
                [ "$(ring "$results/$second.stdout")" != "$init_ring" ] || fail 'different IDs share a session'
                step "$second" $rt delete --force "$second"
            fi
            step "$tag" $rt delete --force "$tag"
            [ ! -d "$cg/$fixture/$tag" ] || fail 'keyring lifecycle leaked cgroup'
        done
    done
    echo "$impl: root/nonroot, init/exec session identity, caller keys excluded, opt-out and bundle removal passed"
}
exercise swift "$ours"
if [ "$compare" = 1 ]; then exercise runc "$theirs"; fi
# Join and permission errors must fail before workload/readiness. Unlike runc's
# ENOSYS fallback, Swift requires an explicit opt-out when keyrings are absent.
for kind in join permissions; do
    for error in EPERM ENOSYS; do
        tag=keys-denied-$kind-$error
        write_config "$tag" "$root" "$(cgroup_fields "/$fixture/$tag" '{}')" '["/bin/echo","must-not-run"]'
        restricted="$probe deny $kind $error $ours"
        for mode in foreground created; do expect_failure "$restricted" "$tag" "$mode" 'session keyring'; done
        [ ! -d "$cg/$fixture/$tag" ] || fail 'failed keyctl leaked cgroup'
    done
done
# A failed exec join must leave the running init and its original session alone.
tag=keys-exec-failure
write_config "$tag" "$root" "$(cgroup_fields "/$fixture/$tag" '{}')" '["/bin/keyring-probe","hold"]'
step "$tag" $ours run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
wait_until 'exec failure init' grep -q '^keyring=' "$results/$tag.stdout"
init=$(pid_of "$ours" "$tag")
before=$(cat "$cg/$fixture/$tag/cgroup.procs")
set +e
"$probe" deny join EPERM $ours exec "$tag" /bin/echo must-not-run > "$results/$tag.exec" 2> "$results/$tag.exec-error"
status=$?
set -e
not_timeout "$tag" 'denied exec join' "$status"
[ "$status" != 0 ] && [ ! -s "$results/$tag.exec" ] || fail 'failed exec ran workload'
grep -q 'join session keyring' "$results/$tag.exec-error" || fail 'exec did not report keyring failure'
alive "$init" || fail 'failed exec killed init'
[ "$(cat "$cg/$fixture/$tag/cgroup.procs")" = "$before" ] || fail 'failed exec leaked process'
step "$tag" $ours exec "$tag" /bin/keyring-probe inspect > "$results/$tag.exec" 2> "$results/$tag.stderr"
[ "$(ring "$results/$tag.exec")" = "$(ring "$results/$tag.stdout")" ] || fail 'failed exec changed init session'
step "$tag" $ours delete --force "$tag"

# An upgraded runtime preserves inherited-session behavior for old records.
tag=keys-legacy
write_config "$tag" "$root" "$(cgroup_fields "/$fixture/$tag" '{}')" '["/bin/keyring-probe","hold"]'
step "$tag" "$probe" parent "$results/$tag.parent" $ours run --detach --no-new-keyring --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
sed 's/"noNewKeyring":true,//' "$state_root/$tag/state.json" > "$scratch/legacy.json"
mv "$scratch/legacy.json" "$state_root/$tag/state.json"
step "$tag" "$probe" parent "$results/$tag.exec-parent" $ours exec "$tag" /bin/keyring-probe inspect > "$results/$tag.exec" 2> "$results/$tag.stderr"
check_view "$results/$tag.exec" inherit "$results/$tag.exec-parent" "$tag"
step "$tag" $ours delete --force "$tag"

# The explicit opt-out performs no keyctl setup even when joining is denied.
tag=keys-opt-out
write_config "$tag" "$root" "$(cgroup_fields "/$fixture/$tag" '{}')" '["/bin/echo","opted-out"]'
step "$tag" "$probe" deny join EPERM $ours run --no-new-keyring --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
grep -qx opted-out "$results/$tag.stdout" || fail 'explicit keyring opt-out did not run'
echo 'Session keyring integration passed.'
