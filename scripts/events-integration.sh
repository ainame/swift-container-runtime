#!/bin/sh
# events: stats snapshots, timed streams, prompt OOM notifications and stream
# ends on exit/deletion, compared with runc. Reuses the cpu-integration
# lifecycle/cleanup helpers rather than duplicating launch machinery.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-events-$$
. "$(dirname -- "$0")/cpu-integration.sh"
echo '+memory +pids' > "$fix/cgroup.subtree_control"
# io and hugetlb are reported only where the kernel provides them.
echo '+io' 2>/dev/null > "$fix/cgroup.subtree_control" || warn "io controller unavailable; blkio tables stay empty"

cat > "$rootfs/bin/events-workload" <<'WORKLOAD'
while [ ! -e "/tmp/trigger-$1" ]; do sleep 0.02; done
/bin/cpu-probe burn 300 "/tmp/release-$1"
exec /bin/sleep 1000
WORKLOAD
cat > "$rootfs/bin/oom-workload" <<'WORKLOAD'
while [ ! -e "/tmp/trigger-$1" ]; do sleep 0.02; done
# A 64 MiB dd buffer exceeds the 16 MiB limit; the kernel kills dd only.
/bin/dd if=/dev/zero of=/dev/null bs=64M count=1 2>/dev/null || :
exec /bin/sleep 1000
WORKLOAD

# json_flat < LINES: one "PATH<TAB>VALUE" per scalar of each JSON line, with
# object keys and array indexes joined by "." and strings unquoted (escapes
# kept). Empty containers print {} or []. Field order does not matter.
json_flat() {
    awk '
    function path(d,   p, k) {
        p = ""
        for (k = 1; k <= d; k++) p = (k == 1) ? key[k] : p "." key[k]
        return p
    }
    {
        s = $0; n = length(s); i = 1; depth = 0
        while (i <= n) {
            c = substr(s, i, 1)
            if (c == "{" || c == "[") {
                if (depth > 0) empty[depth] = 0
                depth++; kind[depth] = c; empty[depth] = 1; slot[depth] = 0
                key[depth] = (c == "[") ? 0 : ""; wantkey[depth] = (c == "{"); i++
            } else if (c == "}" || c == "]") {
                if (empty[depth]) print path(depth - 1) "\t" ((c == "}") ? "{}" : "[]")
                depth--; i++
            } else if (c == ",") {
                if (kind[depth] == "[") key[depth] = ++slot[depth]; else wantkey[depth] = 1
                i++
            } else if (c == ":") {
                wantkey[depth] = 0; i++
            } else if (c == "\"") {
                j = i + 1
                while (j <= n && substr(s, j, 1) != "\"") j += (substr(s, j, 1) == "\\") ? 2 : 1
                text = substr(s, i + 1, j - i - 1); i = j + 1
                if (kind[depth] == "{" && wantkey[depth]) key[depth] = text
                else { empty[depth] = 0; print path(depth) "\t" text }
            } else if (c == " " || c == "\t") {
                i++
            } else if (match(substr(s, i), /^[^],} \t]+/)) {
                empty[depth] = 0; print path(depth) "\t" substr(s, i, RLENGTH); i += RLENGTH
            } else {
                i++
            }
        }
    }'
}
# json_values PATH < LINES: every value at PATH, one per line.
json_values() { json_flat | awk -F '\t' -v want="$1" '$1 == want { print $2 }'; }
# json_get PATH < LINE: the value at PATH, or nothing when it is absent.
json_get() { json_values "$1" | head -n 1; }
json_has() { [ -n "$(json_flat | awk -F '\t' -v want="$1" '$1 == want { print "found"; exit }')" ]; }
# expect_field TAG LINE PATH VALUE: an empty VALUE requires an omitted field.
expect_field() {
    actual=$(printf '%s\n' "$2" | json_get "$3")
    if [ -z "$4" ] && printf '%s\n' "$2" | json_has "$3"; then
        printf '%s\n' "$2" >&3
        fail "$1: $3 is '$actual', expected it omitted"
    fi
    [ "$actual" = "$4" ] || { printf '%s\n' "$2" >&3; fail "$1: $3 is '$actual', expected '$4'"; }
}
# expect_events TAG FILE TYPE: every event names TAG and has type TYPE.
expect_events() {
    if json_values id < "$2" | grep -vqxF "$1"; then fail "$1: an event names another container"; fi
    if json_values type < "$2" | grep -vqxF "$3"; then fail "$1: unexpected event type in $2"; fi
}
lines_of() { if [ -e "$1" ]; then wc -l < "$1"; else echo 0; fi; }
has_lines() { [ "$(lines_of "$1")" -ge "$2" ]; }
# last_sample FILE: the last newline-terminated line, never a partial write.
last_sample() { head -n "$(lines_of "$1")" "$1" | tail -n 1; }
sample_is() { [ "$(last_sample "$1" | json_get "$2")" = "$3" ]; }
exited() { ! kill -0 "$1" 2>/dev/null; }
alive_stream() { kill -0 "$2" 2>/dev/null || { cat "$results/$1.events-error" >&3 2>/dev/null || :; fail "$1: stream ended $3"; }; }
# finished TAG PID: the background events command ended with status 0
# within wait_until's bound; a timeout or kill is a failure.
finished() {
    wait_until "$1 events stream to end" exited "$2"
    if wait "$2"; then return 0; else stream_status=$?; fi
    not_timeout "$1" events "$stream_status"
    cat "$results/$1.events-error" >&3 2>/dev/null || :
    fail "$1: events stream failed with status $stream_status"
}
# refused TAG PATTERN COMMAND...: fails without a timeout, matching stderr.
refused() {
    refused_tag=$1 pattern=$2
    shift 2
    if "$@" > "$results/$refused_tag.refused-out" 2> "$results/$refused_tag.refused-error"; then
        fail "$refused_tag: '$*' succeeded"
    else
        refused_status=$?
    fi
    not_timeout "$refused_tag" "$*" "$refused_status"
    grep -q -- "$pattern" "$results/$refused_tag.refused-error" \
        || { cat "$results/$refused_tag.refused-error" >&3; fail "$refused_tag: expected '$pattern'"; }
}
# swap_record RECORD SED: replaces state.json atomically, as updates do.
swap_record() {
    sed "$2" "$1" > "$1.events-tmp"
    mv "$1.events-tmp" "$1"
}
# paused_snapshot RT TAG PATH: with the cgroup frozen, a snapshot equals the
# kernel's own pids and CPU readback, which must not move around it.
paused_snapshot() {
    kernel_pids=$(cat "$cg$3/pids.current")
    kernel_usec=$(stat_of "$cg$3/cpu.stat" usage_usec)
    memory_low=$(cat "$cg$3/memory.current")
    step "$2" $1 events --stats "$2" > "$results/$2.paused"
    [ "$(cat "$cg$3/pids.current")" = "$kernel_pids" ] && [ "$(stat_of "$cg$3/cpu.stat" usage_usec)" = "$kernel_usec" ] \
        || fail "$2: frozen counters moved"
    memory_high=$(cat "$cg$3/memory.current")
    paused=$(cat "$results/$2.paused")
    expect_field "$2" "$paused" type stats
    expect_field "$2" "$paused" data.pids.current "$kernel_pids"
    expect_field "$2" "$paused" data.cpu.usage.total $((kernel_usec * 1000))
    paused_memory=$(printf '%s\n' "$paused" | json_get data.memory.usage.usage)
    if [ "$memory_low" -gt "$memory_high" ]; then memory_swap=$memory_low memory_low=$memory_high memory_high=$memory_swap; fi
    [ "$paused_memory" -ge "$memory_low" ] && [ "$paused_memory" -le "$memory_high" ] \
        || fail "$2: memory usage $paused_memory outside $memory_low..$memory_high"
}

events_shared() {
    impl=$1 rt=$2
    base=/$fixture/$impl
    refused "missing-$impl" 'does not exist' $rt events --stats "missing-$impl"
    for who in root user; do
        case "$who" in root) who_json=$root ;; user) who_json=$user ;; esac

        # A snapshot reports the typed cgroup v2 values once, at once.
        tag=events-$who-$impl
        path=$base/$tag
        fields=', "cgroupsPath": "'$path'", "resources":{"memory":{"limit":67108864},"pids":{"limit":32}}'
        write_config "$tag" "$who_json" "$fields" '["/bin/sh", "/bin/events-workload", "'$tag'"]'
        step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        wait_status "$rt" "$tag" running
        step "$tag" $rt events --stats "$tag" > "$results/$tag.snapshot"
        [ "$(lines_of "$results/$tag.snapshot")" = 1 ] || fail "$tag: --stats did not print exactly one line"
        snapshot=$(cat "$results/$tag.snapshot")
        expect_field "$tag" "$snapshot" type stats
        expect_field "$tag" "$snapshot" id "$tag"
        expect_field "$tag" "$snapshot" data.intel_rdt '{}'
        expect_field "$tag" "$snapshot" data.network_interfaces null
        expect_field "$tag" "$snapshot" data.memory.usage.limit 67108864
        expect_field "$tag" "$snapshot" data.cpuset.cpu_exclusive 0
        expect_field "$tag" "$snapshot" data.pids.limit 32
        printf '%s\n' "$snapshot" | json_has data.memory.raw.anon || fail "$tag: no raw memory.stat"
        # The live init alone is stable; the polling loop's sleep is not.
        [ "$(printf '%s\n' "$snapshot" | json_get data.pids.current)" -ge 1 ] || fail "$tag: pids current"
        [ "$(printf '%s\n' "$snapshot" | json_get data.memory.usage.usage)" -gt 0 ] || fail "$tag: memory usage"
        # cpu.stat microseconds become nanoseconds.
        kernel_usec=$(stat_of "$cg$path/cpu.stat" usage_usec)
        total=$(printf '%s\n' "$snapshot" | json_get data.cpu.usage.total)
        [ "$total" -le $((kernel_usec * 1000)) ] && [ "$total" -ge 1000 ] || fail "$tag: cpu total $total vs ${kernel_usec}us"

        # Interval validation follows runc: a malformed or nonpositive one fails.
        # The malformed reason differs by runc release ("parse error" in 1.4,
        # "missing unit" in newer Go), so only the common prefix is required.
        refused "$tag" 'invalid value .*5.* for flag -interval' $rt events --interval 5 "$tag"
        refused "$tag" 'duration interval must be greater than 0' $rt events --interval 0 "$tag"

        # A stream waits one interval for its first sample, then samples
        # repeatedly, including while paused.
        $rt events --interval 300ms "$tag" > "$results/$tag.events" 2> "$results/$tag.events-error" & stream=$!
        sleep 0.1
        [ "$(lines_of "$results/$tag.events")" = 0 ] || fail "$tag: first sample did not wait for the interval"
        wait_until "$tag first samples" has_lines "$results/$tag.events" 2
        step "$tag" $rt pause "$tag"
        wait_status "$rt" "$tag" paused
        paused_snapshot "$rt" "$tag" "$path"
        paused_total=$((kernel_usec * 1000))
        count=$(lines_of "$results/$tag.events")
        wait_until "$tag paused samples" has_lines "$results/$tag.events" $((count + 2))
        sample_is "$results/$tag.events" data.cpu.usage.total "$paused_total" || fail "$tag: paused sample moved"
        alive_stream "$tag" "$stream" "while paused"

        # After resume the stream continues and counters grow with real CPU work.
        step "$tag" $rt resume "$tag"
        wait_status "$rt" "$tag" running
        : > "$rootfs/tmp/trigger-$tag"
        wait_burn "$tag"
        count=$(lines_of "$results/$tag.events")
        wait_until "$tag later sample" has_lines "$results/$tag.events" $((count + 1))
        last_total=$(last_sample "$results/$tag.events" | json_get data.cpu.usage.total)
        [ $((last_total - paused_total)) -ge 270000000 ] || fail "$tag: cpu total grew only $paused_total->$last_total ns"
        : > "$rootfs/tmp/release-$tag"

        # An update rewrites state.json; the stream continues and reports it.
        step "$tag" $rt update --pids-limit 20 "$tag"
        wait_until "$tag updated pids limit" sample_is "$results/$tag.events" data.pids.limit 20
        alive_stream "$tag" "$stream" "on update"
        # A rejected update changes nothing and leaves the stream sampling.
        echo '{"memory":{"limit":1,"checkBeforeUpdate":true}}' > "$scratch/$tag.resources"
        refused "$tag" 'rejecting memory limit' $rt update --resources "$scratch/$tag.resources" "$tag"
        count=$(lines_of "$results/$tag.events")
        wait_until "$tag sample after a rejected update" has_lines "$results/$tag.events" $((count + 1))
        alive_stream "$tag" "$stream" "on a rejected update"
        last=$(last_sample "$results/$tag.events")
        expect_field "$tag" "$last" data.pids.limit 20
        expect_field "$tag" "$last" data.memory.usage.limit 67108864
        # Unlimited memory is MaxUint64; an unlimited pids.max is omitted (0).
        step "$tag" $rt update --memory -1 --pids-limit -1 "$tag"
        wait_until "$tag unlimited memory" sample_is "$results/$tag.events" data.memory.usage.limit 18446744073709551615
        expect_field "$tag" "$(last_sample "$results/$tag.events")" data.pids.limit ''
        alive_stream "$tag" "$stream" "on an unlimited update"

        # The init's exit empties the cgroup, which ends the stream with 0.
        step "$tag" $rt kill "$tag" KILL
        finished "$tag" "$stream"
        expect_events "$tag" "$results/$tag.events" stats
        wait_status "$rt" "$tag" stopped
        refused "$tag" "container with id $tag is not running" $rt events --stats "$tag"
        step "$tag" $rt delete "$tag"
        gone "$tag" "$path"
        no_process_of "$tag"

        # OOM kills are reported promptly, not at the next (hourly) sample.
        tag=events-oom-$who-$impl
        path=$base/$tag
        fields=', "cgroupsPath": "'$path'", "resources":{"memory":{"limit":16777216,"swap":16777216}}'
        write_config "$tag" "$who_json" "$fields" '["/bin/sh", "/bin/oom-workload", "'$tag'"]'
        step "$tag" $rt run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        wait_status "$rt" "$tag" running
        $rt events --interval 1h "$tag" > "$results/$tag.events" 2> "$results/$tag.events-error" & stream=$!
        sleep 0.3
        : > "$rootfs/tmp/trigger-$tag"
        oom_reported() { json_values type < "$results/$tag.events" | grep -qx oom; }
        wait_until "$tag OOM event" oom_reported
        expect_events "$tag" "$results/$tag.events" oom
        [ "$(stat_of "$cg$path/memory.events" oom_kill)" -ge 1 ] || fail "$tag: kernel recorded no OOM kill"
        alive_stream "$tag" "$stream" "while the cgroup was populated"
        step "$tag" $rt kill "$tag" KILL
        finished "$tag" "$stream"
        step "$tag" $rt delete "$tag"
        gone "$tag" "$path"

        # Deleting a created container ends its stream promptly, whether it
        # is idle (hourly) or sampling continuously (1ns).
        for interval in 1h 1ns; do
            tag=events-delete-$who-$impl-$interval
            path=$base/$tag
            write_config "$tag" "$who_json" ', "cgroupsPath": "'$path'"' '["/bin/sleep", "1000"]'
            step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            step "$tag" $rt events --stats "$tag" > "$results/$tag.snapshot"
            $rt events --interval "$interval" "$tag" > "$results/$tag.events" 2> "$results/$tag.events-error" & stream=$!
            sleep 0.3
            alive_stream "$tag" "$stream" "before deletion"
            step "$tag" $rt delete --force "$tag"
            finished "$tag" "$stream"
            expect_events "$tag" "$results/$tag.events" stats
            if [ "$interval" = 1ns ]; then has_lines "$results/$tag.events" 1 || fail "$tag: no samples at 1ns"; fi
            gone "$tag" "$path"
            no_process_of "$tag"
        done
    done
    echo "$impl: snapshots, paused readback, interval checks, CPU growth across pause/resume, accepted/rejected/unlimited updates, prompt OOM, exit and deletion ends ok"
}

# Swift-only guards: a record naming another cgroup generation is refused
# for snapshots and ends a running stream, and a stream whose container is
# replaced under the same ID ends without reporting the replacement. A
# bystander container is never reported or disturbed.
stale_guards() {
    bystander=events-bystander
    bystander_path=/$fixture/swift/$bystander
    write_config "$bystander" "$root" ', "cgroupsPath": "'$bystander_path'"' '["/bin/sleep", "1000"]'
    step "$bystander" $ours run --detach --bundle "$bundles/$bystander" "$bystander" < /dev/null > "$results/$bystander.stdout" 2> "$results/$bystander.stderr"
    wait_status "$ours" "$bystander" running
    bystander_pid=$(pid_of "$ours" "$bystander")

    # Another boot's record: the generation differs from the pinned one.
    tag=events-stale
    path=/$fixture/swift/$tag
    write_config "$tag" "$root" ', "cgroupsPath": "'$path'"' '["/bin/sleep", "1000"]'
    step "$tag" $ours run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    wait_status "$ours" "$tag" running
    record=$state_root/$tag/state.json
    cp "$record" "$scratch/saved-$tag"
    $ours events --interval 1h "$tag" > "$results/$tag.events" 2> "$results/$tag.events-error" & stream=$!
    sleep 0.3
    stale='s/"cgroup":{"bootID":"[^"]*"/"cgroup":{"bootID":"00000000-0000-4000-8000-000000000000"/'
    swap_record "$record" "$stale"
    finished "$tag" "$stream"
    refused "$tag" 'missing, replaced, or from another boot' $ours events --stats "$tag"
    cp "$scratch/saved-$tag" "$record.events-tmp"
    mv "$record.events-tmp" "$record"
    step "$tag" $ours events --stats "$tag" > /dev/null

    # A real replacement: the stream is stopped while the container is
    # deleted and recreated with the same ID and cgroup path, then resumed.
    # The runtime runs without the timeout wrapper so SIGSTOP reaches it.
    tag=events-replaced
    path=/$fixture/swift/$tag
    write_config "$tag" "$root" ', "cgroupsPath": "'$path'"' '["/bin/sleep", "1000"]'
    step "$tag" $ours run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    wait_status "$ours" "$tag" running
    $runtime --root "$state_root" events --interval 1h "$tag" > "$results/$tag.events" 2> "$results/$tag.events-error" & stream=$!
    fixture_pids="$fixture_pids $stream"
    sleep 0.3
    kill -STOP "$stream"
    step "$tag" $ours delete --force "$tag"
    gone "$tag" "$path"
    step "$tag" $ours run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    wait_status "$ours" "$tag" running
    kill -CONT "$stream"
    finished "$tag" "$stream"
    [ "$(lines_of "$results/$tag.events")" = 0 ] || fail "$tag: the replaced stream reported the new container"
    wait_status "$ours" "$tag" running

    # The bystander is unaffected and reported only under its own ID.
    [ "$(pid_of "$ours" "$bystander")" = "$bystander_pid" ] && kill -0 "$bystander_pid" \
        || fail "$bystander: disturbed by the stale guards"
    grep -qx 'populated 1' "$cg$bystander_path/cgroup.events" || fail "$bystander: cgroup emptied"
    step "$bystander" $ours events --stats "$bystander" > "$results/$bystander.snapshot"
    expect_events "$bystander" "$results/$bystander.snapshot" stats
    for id in events-stale events-replaced "$bystander"; do
        step "$id" $ours delete --force "$id"
    done
    gone events-stale "/$fixture/swift/events-stale"
    gone events-replaced "/$fixture/swift/events-replaced"
    gone "$bystander" "$bystander_path"
    echo "swift: stale and replaced cgroup generations refused and end streams; bystander untouched"
}

# Swift-only: a stream started without the memory controller begins OOM
# monitoring once an update enables it. The ancestor is fresh because
# controllers enabled on an existing parent stay enabled.
late_memory_oom() {
    tag=events-late-memory
    path=/$fixture/late-memory/$tag
    write_config "$tag" "$root" ', "cgroupsPath": "'$path'", "resources":{"pids":{"limit":32}}' '["/bin/sh", "/bin/oom-workload", "'$tag'"]'
    step "$tag" $ours run --detach --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    wait_status "$ours" "$tag" running
    [ ! -e "$cg$path/memory.events" ] || fail "$tag: memory controller enabled before the update"
    $ours events --interval 1h "$tag" > "$results/$tag.events" 2> "$results/$tag.events-error" & stream=$!
    sleep 0.3
    step "$tag" $ours update --memory 16m --memory-swap 16m "$tag"
    [ -e "$cg$path/memory.events" ] || fail "$tag: update did not enable the memory controller"
    : > "$rootfs/tmp/trigger-$tag"
    oom_reported() { json_values type < "$results/$tag.events" | grep -qx oom; }
    wait_until "$tag OOM event after enabling memory" oom_reported
    expect_events "$tag" "$results/$tag.events" oom
    [ "$(stat_of "$cg$path/memory.events" oom_kill)" -ge 1 ] || fail "$tag: kernel recorded no OOM kill"
    alive_stream "$tag" "$stream" "while the cgroup was populated"
    step "$tag" $ours kill "$tag" KILL
    finished "$tag" "$stream"
    step "$tag" $ours delete "$tag"
    gone "$tag" "$path"
    no_process_of "$tag"
    echo "swift: OOM monitoring attached after an update enabled the memory controller"
}

events_shared swift "$ours"
stale_guards
late_memory_oom
if [ "$compare" = 1 ]; then events_shared runc "$theirs"; fi
[ -z "$(ls -A "$state_root")" ] || fail "state left behind"
echo "Events integration checks passed (runc comparison: $compare)."
