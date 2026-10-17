#!/bin/sh
# Live resource changes and saved-config merging, compared with runc.
# Reuses lifecycle/cleanup helpers rather than duplicating launch machinery.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-update-$$
. "$(dirname -- "$0")/cpu-integration.sh"
echo '+memory +pids +cpuset' > "$fix/cgroup.subtree_control"
first_cpu=$(sed 's/[-,].*//' "$fix/cpuset.cpus.effective")
next_cpu=$(awk -F ',' '{split($1,a,"-"); if(a[2]>a[1]) print a[1]+1; else if(NF>1) {split($2,b,"-");print b[1]} else print a[1]}' "$fix/cpuset.cpus.effective")
first_node=$(sed 's/[-,].*//' "$fix/cpuset.mems.effective")
cat > "$rootfs/bin/update-workload" <<'WORKLOAD'
while [ ! -e "/tmp/trigger-$1" ]; do sleep 0.02; done
/bin/cpu-probe burn 300 "/tmp/release-$1"
exec /bin/sleep 1000
WORKLOAD
value_is() { [ "$(cat "$cg$path/$1")" = "$2" ] || fail "$tag: $1 expected '$2', got '$(cat "$cg$path/$1")'"; }
refused_update() {
    if "$@" > "$results/$tag.update-out" 2> "$results/$tag.update-error"; then fail "$tag: invalid update succeeded"; else update_status=$?; fi
    not_timeout "$tag" update "$update_status"
}
update_shared() {
    impl=$1 rt=$2
    base=/$fixture/$impl
    for mode in foreground detached created; do
        for who in root user; do
            tag=update-$mode-$who-$impl
            path=$base/$tag
            case "$who" in root) who_json=$root ;; user) who_json=$user ;; esac
            fields=', "cgroupsPath": "'$path'", "resources":{"memory":{"limit":268435456,"swap":536870912,"reservation":16777216},"pids":{"limit":32},"cpu":{"quota":50000,"period":200000,"shares":512,"cpus":"'$first_cpu'","mems":"'$first_node'"}}'
            write_config "$tag" "$who_json" "$fields" '["/bin/sh", "/bin/update-workload", "'$tag'"]'
            runner=
            case "$mode" in
            foreground)
                $rt run --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr" & runner=$!
                ;;
            detached)
                step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
                ;;
            created)
                step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
                step "$tag" $rt update --cpu-quota 60000 "$tag"
                value_is cpu.max '60000 200000'
                step "$tag" $rt start "$tag"
                ;;
            esac
            wait_status "$rt" "$tag" running
            init=$(pid_of "$rt" "$tag")
            # Updates must use saved settings, even after removing the bundle.
            rm -rf "$bundles/$tag"
            step "$tag" $rt update --cpu-quota 80000 "$tag"
            value_is cpu.max '80000 200000'
            step "$tag" $rt update --cpu-period 100000 "$tag"
            value_is cpu.max '80000 100000'
            step "$tag" $rt update --memory 128m --memory-swap 256m --memory-reservation 8m --pids-limit 64 --cpu-share 1024 "$tag"
            value_is memory.max 134217728
            value_is memory.swap.max 134217728
            value_is memory.low 8388608
            value_is pids.max 64
            value_is cpu.weight 100
            value_is cpu.max '80000 100000'
            step "$tag" $rt update --cpu-quota 20000 "$tag"
            value_is cpu.max '20000 100000'

            # A resources file wins over flags; stdin has the same format.
            file=$scratch/resources-$tag.json
            echo '{"cpu":{"quota":30000,"period":150000},"pids":{"limit":48},"memory":{"checkBeforeUpdate":true}}' > "$file"
            step "$tag" $rt update --resources "$file" --cpu-quota 99999 --pids-limit 7 "$tag"
            value_is cpu.max '30000 150000'
            value_is pids.max 48
            echo '{"pids":{"limit":40}}' | $rt update --resources - "$tag"
            value_is pids.max 40

            # A paused container stays paused while its live cpuset and
            # bandwidth change. Kernel affinity must follow the new cpuset.
            step "$tag" $rt pause "$tag"
            step "$tag" $rt update --cpu-quota 25000 --cpu-period 100000 --cpuset-cpus "$next_cpu" --pids-limit 16 "$tag"
            [ "$(status_of "$rt" "$tag")" = paused ] || fail "$tag: update thawed container"
            value_is cpu.max '25000 100000'
            value_is cpuset.cpus "$next_cpu"
            grep -qx "Cpus_allowed_list:[[:space:]]*$next_cpu" "/proc/$init/status" || fail "$tag: live affinity did not change"
            if [ "$next_cpu" != "$first_cpu" ]; then
                if taskset -pc "$first_cpu" "$init" > /dev/null 2>&1; then fail "$tag: escaped updated cpuset"; fi
            fi
            step "$tag" $rt resume "$tag"

            # The pre-update check must refuse a too-small limit before
            # OOM. The preceding pids write is restored by rollback.
            echo '{"memory":{"limit":1,"checkBeforeUpdate":true},"pids":{"limit":8}}' > "$file"
            refused_update $rt update --resources "$file" "$tag"
            grep -q 'rejecting memory limit' "$results/$tag.update-error" || { cat "$results/$tag.update-error" >&3; fail "$tag: wrong refusal"; }
            value_is memory.max 134217728
            # Swift restores the prior value. runc's CLI mutates a shallow
            # config copy before Container.Set, so its attempted rollback
            # reuses the failed request and leaves the earlier pids write.
            case "$impl" in
            swift) value_is pids.max 16 ;;
            runc)
                value_is pids.max 8
                grep -q 'Setting back cgroup configs failed' "$results/$tag.update-error" || fail "$tag: missing runc rollback warning"
                ;;
            esac
            step "$tag" $rt update --cpu-quota 26000 "$tag"
            value_is cpu.max '26000 100000'
            [ "$(pid_of "$rt" "$tag")" = "$init" ] || fail "$tag: init changed during updates"

            # Real CPU work starts only after the final update. Kernel
            # throttling and usage must advance under the changed quota.
            before_throttled=$(sed -n 's/^nr_throttled //p' "$cg$path/cpu.stat")
            before_usage=$(sed -n 's/^usage_usec //p' "$cg$path/cpu.stat")
            : > "$rootfs/tmp/trigger-$tag"
            wait_burn "$tag"
            after_throttled=$(sed -n 's/^nr_throttled //p' "$cg$path/cpu.stat")
            after_usage=$(sed -n 's/^usage_usec //p' "$cg$path/cpu.stat")
            [ "$after_throttled" -gt "$before_throttled" ] || fail "$tag: changed quota did not throttle"
            [ $((after_usage - before_usage)) -ge 270000 ] || fail "$tag: CPU workload did not run"
            echo "$tag updated quota: throttles $before_throttled->$after_throttled, usage +$((after_usage - before_usage))us"
            : > "$rootfs/tmp/release-$tag"
            step "$tag" $rt update --memory -1 --cpu-quota -1 --pids-limit -1 "$tag"
            value_is memory.max max
            value_is memory.swap.max max
            value_is cpu.max 'max 100000'
            value_is pids.max max

            step "$tag" $rt kill "$tag" KILL
            if [ -n "$runner" ]; then
                if wait "$runner"; then result=0; else result=$?; fi
                [ "$result" = 137 ] || fail "$tag: unexpected exit $result"
            else
                wait_status "$rt" "$tag" stopped
                refused_update $rt update --pids-limit 10 "$tag"
                step "$tag" $rt delete "$tag"
            fi
            gone "$tag" "$path"
            no_process_of "$tag"
        done
    done
    # A container that initially needed no controllers can add one later.
    # Legacy/stale metadata must fail before ancestor or leaf writes.
    tag=enable-$impl
    path=/$fixture/fresh-$impl/ctr
    linux_fields=$(printf ', "cgroupsPath": "%s"' "$path")
    write_config "$tag" "$root" "$linux_fields" '["/bin/sleep", "1000"]'
    step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    if [ "$impl" = swift ]; then
        record=$state_root/$tag/state.json
        cp "$record" "$scratch/saved-state"
        sed 's/,"resourceConfiguration":{}//' "$scratch/saved-state" > "$record"
        cmp -s "$record" "$scratch/saved-state" && fail "$tag: legacy fixture did not remove metadata"
        refused_update $rt update --pids-limit 20 "$tag"
        grep -q 'predates saved resource configuration' "$results/$tag.update-error" || fail "$tag: legacy record not identified"
        sed 's/"cgroup":{"bootID":"[^"]*"/"cgroup":{"bootID":"00000000-0000-4000-8000-000000000000"/' "$scratch/saved-state" > "$record"
        refused_update $rt update --pids-limit 20 "$tag"
        [ -z "$(cat "$cg/$fixture/fresh-$impl/cgroup.subtree_control")" ] || fail "$tag: stale update changed controllers"
        cat "$scratch/saved-state" > "$record"
    fi
    step "$tag" $rt update --pids-limit 20 "$tag"
    value_is pids.max 20
    [ "$(status_of "$rt" "$tag")" = created ] || fail "$tag: update started workload"
    step "$tag" $rt delete --force "$tag"
    gone "$tag" "$path"
    echo "$impl: created/running/paused updates, saved merge, file/stdin precedence, live affinity/CPU throttling, memory check and rollback ok"
}
mkdir "$fix/bystander"
echo 50 > "$fix/bystander/cpu.weight"
update_shared swift "$ours"
if [ "$compare" = 1 ]; then update_shared runc "$theirs"; fi
[ "$(cat "$fix/bystander/cpu.weight")" = 50 ] || fail "bystander changed"
[ -z "$(ls -A "$state_root")" ] || fail "state left behind"
echo "Update integration checks passed (runc comparison: $compare)."
