#!/bin/sh
# Compare host-PID snapshots with the actual cgroup, including descendants,
# and check host ps option forwarding, filtering, and failure behavior.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-ps-$$
. "$(dirname -- "$0")/cpu-integration.sh"
json_pids() { tr '[],' '\n\n\n' | sed '/^[[:space:]]*$/d' | sort -n; }
# Extract a PID column by its header, preserving emitted row order.
table_pids() {
    awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i == "PID") column=i; if (!column) exit 2; next } NF { if (!column || $column !~ /^[0-9]+$/) exit 3; print $column }'
}
expected_pids() {
    find "$cg$1" -name cgroup.procs -exec cat {} \; | sort -nu
}
ps_matches() {
    expected_pids "$path" > "$results/$tag.expected"
    $rt ps --format json "$tag" | json_pids > "$results/$tag.actual"
    cmp -s "$results/$tag.expected" "$results/$tag.actual"
}
ps_shared() {
    impl=$1 rt=$2
    base=/$fixture/$impl
    for mode in foreground detached created; do
        for who in root user; do
            tag=ps-$mode-$who-$impl
            path=$base/$tag
            case "$who" in root) who_json=$root ;; user) who_json=$user ;; esac
            write_config "$tag" "$who_json" "$(cgroup_fields "$path" '{}')" '["/bin/sh", "-ec", "/bin/sleep 1000 & /bin/sleep 1000 & wait"]'
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
                ps_matches || fail "$tag: created PID list differs from cgroup"
                [ "$(wc -l < "$results/$tag.actual")" -eq 1 ] || fail "$tag: expected only waiting init"
                step "$tag" $rt start "$tag"
                ;;
            esac
            wait_status "$rt" "$tag" running
            wait_until "$tag three processes" three_members "$path"
            ps_matches || fail "$tag: JSON PID list differs from cgroup"

            # A shuffled PID column and descending sort must reach host ps
            # unchanged. Neither table may include unrelated host processes.
            $rt ps "$tag" > "$results/$tag.default"
            table_pids < "$results/$tag.default" | sort -n > "$results/$tag.table"
            cmp "$results/$tag.expected" "$results/$tag.table" || fail "$tag: default table PID mismatch"
            $rt ps "$tag" -e -o comm,pid --sort=-pid > "$results/$tag.custom"
            table_pids < "$results/$tag.custom" > "$results/$tag.table"
            sort -nr "$results/$tag.expected" > "$results/$tag.descending"
            cmp "$results/$tag.descending" "$results/$tag.table" || fail "$tag: custom columns/sort not preserved"
            if $rt ps "$tag" --invalid-ps-option > /dev/null 2> "$results/$tag.bad"; then fail "$tag: invalid host ps option succeeded"; else ps_status=$?; fi
            not_timeout "$tag" ps "$ps_status"

            # Paused processes still belong to the snapshot. A process in
            # a descendant cgroup must also be included.
            step "$tag" $rt pause "$tag"
            ps_matches || fail "$tag: paused processes disappeared"
            step "$tag" $rt resume "$tag"
            mkdir "$cg$path/child"
            spawn_sleeper "$cg$path/child"
            ps_matches || fail "$tag: descendant PID missing"
            stop_sleeper "$sleeper"
            wait_until "$tag child empty" unpopulated "$cg$path/child"
            rmdir "$cg$path/child"

            step "$tag" $rt kill "$tag" KILL
            if [ -n "$runner" ]; then
                if wait "$runner"; then result=0; else result=$?; fi
                [ "$result" = 137 ] || fail "$tag: foreground exit $result"
            else
                wait_status "$rt" "$tag" stopped
                wait_until "$tag group empty" unpopulated "$cg$path"
                stopped_json=$($rt ps --format json "$tag")
                echo "$tag stopped ps: $stopped_json"
                [ "$stopped_json" = null ] || fail "$tag: expected runc's null for an empty PID slice, got $stopped_json"
                step "$tag" $rt delete "$tag"
            fi
            gone "$tag" "$path"
            no_process_of "$tag"
        done
    done
    # A threaded leaf exposes cgroup.threads instead of cgroup.procs.
    thread_root=/$fixture/thread-$impl
    mkdir "$cg$thread_root" "$cg$thread_root/anchor"
    echo threaded > "$cg$thread_root/anchor/cgroup.type"
    tag=thread-ps-$impl
    path=$thread_root/ctr
    write_config "$tag" "$root" "$(cgroup_fields "$path" '{}')" '["/bin/sleep", "1000"]'
    step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    $rt ps --format json "$tag" | json_pids > "$results/$tag.actual"
    cat "$cg$path/cgroup.threads" | sort -n > "$results/$tag.expected"
    cmp "$results/$tag.expected" "$results/$tag.actual" || fail "$tag: threaded group snapshot differs"
    step "$tag" $rt delete --force "$tag"
    gone "$tag" "$path"
    echo "$impl: JSON, default/custom host ps, paused/created/stopped states, descendant/threaded groups and filtering ok"
}
three_members() { [ "$(wc -l < "$cg$1/cgroup.procs")" -eq 3 ]; }
ps_shared swift "$ours"
if [ "$compare" = 1 ]; then ps_shared runc "$theirs"; fi
[ -z "$(ls -A "$state_root")" ] || fail "state left behind"
echo "PS integration checks passed (runc comparison: $compare)."
