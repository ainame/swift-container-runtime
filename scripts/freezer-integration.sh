#!/bin/sh
# Real freezer transitions versus runc, reusing the cgroup lifecycle fixture.
# Two independently ticking workload processes must stop together at pause
# completion and both make progress again after resume.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-freezer-$$
. "$(dirname -- "$0")/cpu-integration.sh"
chmod 1777 "$rootfs/tmp"
cat > "$rootfs/bin/ticker" <<'TICKER'
counter() {
    i=0
    while :; do
        i=$((i + 1))
        echo "$i" > "/tmp/$1.new"
        mv "/tmp/$1.new" "/tmp/$1"
        sleep 0.01
    done
}
counter "$1-child" &
counter "$1-main"
TICKER

read_counter() { cat "$rootfs/tmp/$1" 2>/dev/null || echo 0; }
counters_ready() { [ "$(read_counter "$1-main")" -gt 0 ] && [ "$(read_counter "$1-child")" -gt 0 ]; }
counters_advanced() { [ "$(read_counter "$1-main")" -gt "$2" ] && [ "$(read_counter "$1-child")" -gt "$3" ]; }
refused() {
    refusal_tag=$1
    shift
    if "$@" > "$results/$refusal_tag.stdout" 2> "$results/$refusal_tag.stderr"; then
        fail "$refusal_tag: invalid transition succeeded"
    else
        refusal_status=$?
    fi
    not_timeout "$refusal_tag" "$*" "$refusal_status"
}
freezer_shared() {
    impl=$1 rt=$2
    base=/$fixture/$impl
    for mode in foreground detached created; do
        for who in root user; do
            tag=tick-$mode-$who-$impl
            path=$base/$tag
            case "$who" in root) who_json=$root ;; user) who_json=$user ;; esac
            write_config "$tag" "$who_json" "$(cgroup_fields "$path" '{}')" '["/bin/sh", "/bin/ticker", "'$tag'"]'
            runner=
            case "$mode" in
            foreground)
                $rt run --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr" &
                runner=$!
                ;;
            detached)
                step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
                ;;
            created)
                step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
                # runc permits freezing a created init at its start gate.
                step "$tag" $rt pause "$tag"
                wait_status "$rt" "$tag" paused
                refused "$tag-start-paused" $rt start "$tag"
                step "$tag" $rt resume "$tag"
                wait_status "$rt" "$tag" created
                step "$tag" $rt start "$tag"
                ;;
            esac
            wait_status "$rt" "$tag" running
            wait_until "$tag counters" counters_ready "$tag"
            refused "$tag-resume-running" $rt resume "$tag"

            # Pause returns only after every cgroup task is frozen, and
            # state/list must show paused while retaining the init PID.
            step "$tag" $rt pause "$tag"
            wait_status "$rt" "$tag" paused
            grep -qx 'frozen 1' "$cg$path/cgroup.events" || fail "$tag: freeze not completed"
            [ "$(pid_of "$rt" "$tag")" -gt 1 ] || fail "$tag: paused state lost init PID"
            $rt list --format json | grep -q '"paused"' || fail "$tag: list omitted paused state"
            main=$(read_counter "$tag-main") child=$(read_counter "$tag-child")
            sleep 0.2
            [ "$(read_counter "$tag-main")" = "$main" ] && [ "$(read_counter "$tag-child")" = "$child" ] || fail "$tag: a frozen counter advanced"
            refused "$tag-pause-paused" $rt pause "$tag"
            refused "$tag-delete-paused" $rt delete "$tag"
            step "$tag" $rt resume "$tag"
            wait_status "$rt" "$tag" running
            wait_until "$tag resumed counters" counters_advanced "$tag" "$main" "$child"

            # Both SIGKILL and forced deletion must finish while frozen,
            # without leaving descendants. Exit 137 is the workload result.
            step "$tag" $rt pause "$tag"
            if [ "$who" = root ]; then
                step "$tag" $rt kill "$tag" KILL
                if [ "$mode" = foreground ]; then
                    # Foreground run removes its state on exit; stopped
                    # need not remain observable to a separate command.
                    if wait "$runner"; then result=0; else result=$?; fi
                    [ "$result" = 137 ] || fail "$tag: foreground kill returned $result"
                    runner=
                    if $rt state "$tag" >/dev/null 2>&1; then fail "$tag: foreground state remains"; fi
                else
                    wait_status "$rt" "$tag" stopped
                    refused "$tag-pause-stopped" $rt pause "$tag"
                    refused "$tag-resume-stopped" $rt resume "$tag"
                    step "$tag" $rt delete "$tag"
                fi
            else
                step "$tag" $rt delete --force "$tag"
            fi
            if [ -n "$runner" ]; then
                if wait "$runner"; then result=0; else result=$?; fi
                [ "$result" = 137 ] || fail "$tag: foreground kill returned $result instead of 137"
            fi
            gone "$tag" "$path"
            no_process_of "$tag"
        done
    done
    echo "$impl: freeze/thaw, created gate, state/list, transition errors and frozen deletion ok"
}
# A separate group/process is never frozen or killed by these commands.
mkdir "$fix/bystander"
spawn_sleeper "$fix/bystander"
bystander=$sleeper
freezer_shared swift "$ours"
if [ "$compare" = 1 ]; then freezer_shared runc "$theirs"; fi
# A live init with a stale cgroup boot record must not freeze the group
# now at that path. Restore the record before ordinary cleanup.
tag=stale-freezer-swift
path=/$fixture/$tag
write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/sleep", "1000"]'
step "$tag" $ours create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
record=$state_root/$tag/state.json
cp "$record" "$scratch/original-state"
sed 's/"cgroup":{"bootID":"[^"]*"/"cgroup":{"bootID":"00000000-0000-4000-8000-000000000000"/' "$record" > "$scratch/stale-state"
cmp -s "$record" "$scratch/stale-state" && fail "stale record was not changed"
cat "$scratch/stale-state" > "$record"
refused "$tag-pause-stale" $ours pause "$tag"
[ "$(cat "$cg$path/cgroup.freeze")" = 0 ] || fail "stale record froze a group"
sed 's/"inode":[0-9][0-9]*/"inode":1/' "$scratch/original-state" > "$record"
refused "$tag-pause-wrong-inode" $ours pause "$tag"
[ "$(cat "$cg$path/cgroup.freeze")" = 0 ] || fail "wrong inode froze a group"
cat "$scratch/original-state" > "$record"
step "$tag" $ours delete --force "$tag"
gone "$tag" "$path"
alive "$bystander" && [ "$(cat "$fix/bystander/cgroup.freeze")" = 0 ] || fail "bystander affected"
[ -z "$(ls -A "$state_root")" ] || fail "state left behind"
echo "Freezer integration checks passed (runc comparison: $compare)."
