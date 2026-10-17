#!/bin/sh
# CPU/node list readback and real affinity constraints, using the same
# lifecycle and cleanup fixture as CPU bandwidth tests. No unrelated host
# process is moved; every configured CPU/node comes from the effective set.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-cpuset-$$
. "$(dirname -- "$0")/cpu-integration.sh"
echo +cpuset > "$fix/cgroup.subtree_control"
"$cc" -static -O2 -o "$rootfs/bin/cpuset-probe" "$here/fixtures/cpuset-probe.c"

first_cpu=$(cat "$fix/cpuset.cpus.effective" | sed 's/[-,].*//')
first_node=$(cat "$fix/cpuset.mems.effective" | sed 's/[-,].*//')
[ -n "$first_cpu" ] && [ -n "$first_node" ] || fail "effective CPU/node sets are empty"
# Pick a second allowed CPU when the parent offers one. The configured
# container receives only first_cpu, so this CPU must become inaccessible.
outside=$(awk -F ',' '{ split($1, first, "-"); if (first[2] > first[1]) print first[1]+1; else if (NF > 1) { split($2, nextRange, "-"); print nextRange[1]; } else print -1 }' "$fix/cpuset.cpus.effective")
cpuset_values() {
    for cpuset_file in cpuset.cpus cpuset.mems cpuset.cpus.effective cpuset.mems.effective; do
        echo "$cpuset_file $(cat "$cg$1/$cpuset_file")"
    done
}
cpuset_shared() {
    impl=$1 rt=$2
    base=/$fixture/$impl
    # Root and non-root workloads see the same cpuset and cannot escape it
    # through affinity. Create-time readback proves readiness ordering.
    for mode in foreground detached created; do
        for who in root user; do
            tag=pin-$who-$mode-$impl
            case "$who" in root) who_json=$root ;; user) who_json=$user ;; esac
            fields=$(cgroup_fields "$base/$tag" "{\"cpus\": \"$first_cpu\", \"mems\": \"$first_node\"}")
            args='["/bin/sh", "-ec", "cat /proc/self/cgroup; grep -E '\''^(Cpus_allowed_list|Mems_allowed_list):'\'' /proc/self/status; /bin/cpuset-probe '$first_cpu' '$outside'"]'
            write_config "$tag" "$who_json" "$fields" "$args"
            observe "$rt" "$tag" "$mode" "$base/$tag" cpuset_values
            expect "$results/$tag.stdout" "$tag" "0::$base/$tag|allowed affinity ok"
            grep -qx "Cpus_allowed_list:[[:space:]]*$first_cpu" "$results/$tag.stdout" || fail "$tag: wrong allowed CPUs"
            grep -qx "Mems_allowed_list:[[:space:]]*$first_node" "$results/$tag.stdout" || fail "$tag: wrong allowed memory nodes"
            [ "$outside" = -1 ] || expect "$results/$tag.stdout" "$tag" 'outside affinity EINVAL'
            if [ "$mode" = created ]; then
                expect "$results/$tag.values" "$tag" "cpuset.cpus $first_cpu|cpuset.mems $first_node|cpuset.cpus.effective $first_cpu|cpuset.mems.effective $first_node"
            fi
        done
    done

    # A newly created group inherits each unspecified effective set.
    # Its configured list remains empty rather than being eagerly copied.
    for shape in empty cpu-only mem-only; do
        tag=$shape-$impl
        case "$shape" in
        empty) limits='{"cpus": "", "mems": ""}' expected_cpus= expected_mems= ;;
        cpu-only) limits="{\"cpus\": \"$first_cpu\"}" expected_cpus=$first_cpu expected_mems= ;;
        mem-only) limits="{\"mems\": \"$first_node\"}" expected_cpus= expected_mems=$first_node ;;
        esac
        path=$base/$tag
        write_config "$tag" "$root" "$(cgroup_fields "$path" "$limits")" "$true_args"
        observe "$rt" "$tag" created "$path" cpuset_values
        expect "$results/$tag.values" "$tag" "cpuset.cpus $expected_cpus|cpuset.mems $expected_mems"
        if [ -z "$expected_cpus" ]; then expected_cpus=$(cat "$fix/cpuset.cpus.effective"); fi
        if [ -z "$expected_mems" ]; then expected_mems=$(cat "$fix/cpuset.mems.effective"); fi
        expect "$results/$tag.values" "$tag" "cpuset.cpus.effective $expected_cpus|cpuset.mems.effective $expected_mems"
    done

    # Empty/omitted strings perform no write, even on a supplied group.
    for form in '{}' '{"cpus": "", "mems": ""}'; do
        tag=inherit-$impl
        path=/$fixture/$tag
        supplied "$path"
        echo "$first_cpu" > "$cg$path/cpuset.cpus"
        echo "$first_node" > "$cg$path/cpuset.mems"
        write_config "$tag" "$root" "$(cgroup_fields "$path" "$form")" "$true_args"
        step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        cpuset_values "$path" > "$results/$tag.values"
        expect "$results/$tag.values" "$tag" "cpuset.cpus $first_cpu|cpuset.mems $first_node"
        step "$tag" $rt delete --force "$tag"
        release_supplied "$impl" "$path"
    done

    # Kernel syntax/range failures must prevent workload execution and
    # remove a newly created cgroup, without accepting wrapper timeouts.
    for field in cpus mems; do
        for invalid in invalid-list 999999; do
            tag=bad-$field-$invalid-$impl
            path=$base/$tag
            write_config "$tag" "$root" "$(cgroup_fields "$path" "{\"$field\": \"$invalid\"}")" "$true_args"
            message=
            [ "$impl" != swift ] || message="cpuset.$field to $invalid"
            expect_failure "$rt" "$tag" created "$message"
            [ "$impl" != swift ] || gone "$tag" "$path"
        done
    done
    echo "$impl: cpuset readiness, inheritance, CPU/node lists, affinity and invalid-list cleanup ok"
}

# A supplied sibling's settings must survive every success and failure.
mkdir "$fix/bystander"
echo "$first_cpu" > "$fix/bystander/cpuset.cpus"
echo "$first_node" > "$fix/bystander/cpuset.mems"
cpuset_values "/$fixture/bystander" > "$scratch/before"
cpuset_shared swift "$ours"
if [ "$compare" = 1 ]; then
    cpuset_shared runc "$theirs"
    for record in "$results"/*-swift.values; do
        other=$(echo "$record" | sed 's/-swift\./-runc./')
        cmp "$record" "$other" || fail "cpuset values differ from runc"
    done
fi
cpuset_values "/$fixture/bystander" > "$scratch/after"
cmp "$scratch/before" "$scratch/after" || fail "bystander cpuset changed"
[ -z "$(ls -A "$state_root")" ] || fail "state left behind"
echo "Cpuset integration checks passed (runc comparison: $compare; CPU $first_cpu, node $first_node, excluded CPU $outside). NUMA placement is not measured."
