#!/bin/sh
# runc 1.4 signal contract: --all compatibility, private/shared PID namespace
# SIGKILL, surviving children after init exit, freezer and cgroup identity safety.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Detached workloads need a real subreaper, including shared-namespace orphans.
if [ "${SCT_KILL_REAPING:-0}" != 1 ]; then
    reaper_scratch=$(mktemp -d)
    trap 'rm -rf "$reaper_scratch"' EXIT HUP INT TERM
    "${CC:-clang}" -O2 "$here/fixtures/subreaper.c" -o "$reaper_scratch/subreaper"
    set +e
    SCT_KILL_REAPING=1 "$reaper_scratch/subreaper" sh "$0" "$@"
    result=$?
    set -e
    exit "$result"
fi
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-kill-$$
. "$here/cpu-integration.sh"

mkdir "$fix/bystander"
spawn_sleeper "$fix/bystander"
bystander=$sleeper
private_namespaces=$namespaces
private_mounts=$mounts
shared_namespaces='[{"type":"mount"},{"type":"uts"},{"type":"ipc"}]'
shared_mounts='[{"destination":"/dev","type":"tmpfs","source":"tmpfs","options":["nosuid","mode=755"]}]'
three_members() { [ "$(wc -l < "$cg$1/cgroup.procs")" -eq 3 ]; }
absent() { [ ! -e "/proc/$1" ]; }

exercise() {
    impl=$1 rt=$2
    for mode in private shared stopped paused; do
        tag=kill-$mode-$impl
        path=/$fixture/$tag
        case "$mode" in
            private) namespaces=$private_namespaces mounts=$private_mounts ;;
            *) namespaces=$shared_namespaces mounts=$shared_mounts ;;
        esac
        write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/sh","-c","trap \"echo caught\" USR1; /bin/sleep 1000 & /bin/sleep 1000 & while :; do wait; done"]'
        step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        wait_until "$tag three processes" three_members "$path"
        if [ "$mode" = shared ]; then
            step "$tag" $rt kill --all "$tag" USR1
            wait_until "$tag init handled USR1" grep -q caught "$results/$tag.stdout"
            three_members "$path" || fail "--all broadcast a non-KILL signal to children"
        fi
        init=$(pid_of "$rt" "$tag")
        members=$(cat "$cg$path/cgroup.procs")
        # Descendant groups belong to the workload subtree, even when their
        # processes share the caller's PID namespace. An unrelated group must live.
        mkdir "$cg$path/child"
        spawn_sleeper "$cg$path/child"
        descendant=$sleeper
        case "$mode" in
            stopped)
                kill -KILL "$init"
                wait_status "$rt" "$tag" stopped
                [ "$(wc -l < "$cg$path/cgroup.procs")" -ge 2 ] || fail "children did not survive init exit"
                ;;
            paused) step "$tag" $rt pause "$tag" ;;
        esac
        step "$tag" $rt kill --all "$tag" KILL
        # Private-PID namespace killing init doesn't kill a host fixture moved
        # into its cgroup; remove that artificial member ourselves in this case.
        if [ "$mode" = private ]; then stop_sleeper "$descendant"; fi
        wait_until "$tag subtree empty" unpopulated "$cg$path"
        # runc 1.4's cgroup.kill fast path leaves the empty group frozen; its
        # state command still calls that paused. Thaw it before plain delete.
        if [ "$mode" = paused ] && [ "$impl" = runc ]; then step "$tag" $rt resume "$tag"; fi
        for member in $members "$descendant"; do wait_until "reap $member" absent "$member"; done
        alive "$bystander" || fail "kill reached unrelated cgroup"
        step "$tag" $rt kill -a "$tag" TERM
        step "$tag" $rt delete "$tag"
        [ ! -d "$cg$path" ] || fail "$tag cgroup left behind"
    done
    # A stopped private-PID container accepts --all, but plain kill still fails.
    if $rt kill --all missing KILL > /dev/null 2>&1; then fail "missing container accepted"; fi
    echo "$impl: private/shared PID SIGKILL, stopped init, paused subtree, reaping and bystander isolation passed"
}
exercise swift "$ours"
if [ "$compare" = 1 ]; then exercise runc "$theirs"; fi

# A recorded cgroup from another boot must not signal its current members.
tag=stale-kill
path=/$fixture/$tag
namespaces=$shared_namespaces mounts=$shared_mounts
write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/sleep","1000"]'
step "$tag" $ours run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
init=$(pid_of "$ours" "$tag")
cp "$state_root/$tag/state.json" "$results/original.json"
sed 's/"bootID" *: *"[^"]*"/"bootID":"different-boot"/g' "$results/original.json" > "$state_root/$tag/state.json"
if $ours kill --all "$tag" KILL > /dev/null 2> "$results/$tag.stderr"; then fail "stale cgroup accepted"; fi
alive "$init" || fail "stale identity signalled init"
alive "$bystander" || fail "stale identity signalled bystander"
cp "$results/original.json" "$state_root/$tag/state.json"
step "$tag" $ours kill --all "$tag" KILL
wait_until "$tag empty" unpopulated "$cg$path"
step "$tag" $ours delete "$tag"
stop_sleeper "$bystander"
echo "Kill integration passed: shared PID subtree cleanup, compatibility and identity safety."
