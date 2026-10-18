#!/bin/sh
# Direct enforcement and lifecycle comparison with runc; no daemon required.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-seccomp-$$
. "$(dirname -- "$0")/cpu-integration.sh"
"$cc" -static -O2 -Wall -Wextra -Werror "$here/fixtures/seccomp-probe.c" -o "$rootfs/bin/seccomp-probe"
policy='{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getpgid"],"action":"SCMP_ACT_ERRNO","errnoRet":13}]}'
configure() {
    config_tag=$1 config_who=$2 config_nnp=$3 config_policy=$4 config_args=$5
    write_config "$config_tag" "$config_who" "$(cgroup_fields "/$fixture/$config_tag" '{}'),\"seccomp\":$config_policy" "$config_args"
    # Set process.noNewPrivileges without changing any other security fields.
    sed "s/\"terminal\": false/\"terminal\": false, \"noNewPrivileges\": $config_nnp/" "$bundles/$config_tag/config.json" > "$scratch/config"
    mv "$scratch/config" "$bundles/$config_tag/config.json"
}
exercise() {
    impl=$1 rt=$2
    for who in root user; do
        case "$who" in root) credentials=$root ;; *) credentials=$user ;; esac
        for nnp in true false; do
            tag=seccomp-$impl-$who-$nnp
            configure "$tag" "$credentials" "$nnp" "$policy" '["/bin/seccomp-probe","identity-denied"]'
            step "$tag" $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            grep -qx 'getpgid: EACCES' "$results/$tag.stdout" || fail 'init bypassed seccomp'
            [ ! -d "$cg/$fixture/$tag" ] || fail 'foreground cgroup leaked'
            configure "$tag" "$credentials" "$nnp" "$policy" '["/bin/sh","-ec","/bin/seccomp-probe identity-denied; exec /bin/sleep 1000"]'
            step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            pid=$(pid_of "$rt" "$tag")
            grep -Eq '^Seccomp:[[:space:]]+2$' "/proc/$pid/status" || fail 'created init has no filter'
            step "$tag" $rt start "$tag"
            wait_until 'init syscall denial' grep -qx 'getpgid: EACCES' "$results/$tag.stdout"
            # The container's policy must survive edits/removal, including exec
            # with a standalone process file, which must not reload the bundle.
            sed 's/getpgid/getppid/' "$bundles/$tag/config.json" > "$scratch/config"
            mv "$scratch/config" "$bundles/$tag/config.json"
            step "$tag" $rt exec "$tag" /bin/seccomp-probe identity-denied > "$results/$tag.exec" 2> "$results/$tag.stderr"
            grep -qx 'getpgid: EACCES' "$results/$tag.exec" || fail 'edited bundle weakened exec policy'
            printf '{"args":["/bin/seccomp-probe","identity-denied"],"cwd":"/","user":%s,"noNewPrivileges":%s}' "$credentials" "$nnp" > "$scratch/process.json"
            rm -rf "$bundles/$tag"
            step "$tag" $rt exec --process "$scratch/process.json" "$tag" > "$results/$tag.exec" 2> "$results/$tag.stderr"
            grep -qx 'getpgid: EACCES' "$results/$tag.exec" || fail 'standalone exec bypassed policy'
            step "$tag" $rt delete --force "$tag"
            [ ! -d "$cg/$fixture/$tag" ] || fail 'delete leaked cgroup'
        done
    done
    echo "$impl: root/nonroot, no_new_privs true/false, init/create/exec, persisted policy and cleanup passed"
}
exercise swift "$ours"
if [ "$compare" = 1 ]; then exercise runc "$theirs"; fi

# Every argument operator: real syscall result distinguishes allowed from denied.
for definition in 'EQ 100 0 100 99' 'NE 100 0 99 100' 'LT 100 0 99 100' 'LE 100 0 100 101' 'GE 100 0 100 99' 'GT 100 0 101 100' 'MASKED_EQ 240 160 165 149' 'EQ 4294967296 0 4294967296 0'; do
    set -- $definition
    operator=$1 value=$2 value_two=$3 match=$4 miss=$5
    policy='{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getpgid"],"action":"SCMP_ACT_ERRNO","errnoRet":13,"args":[{"index":0,"value":'"$value"',"valueTwo":'"$value_two"',"op":"SCMP_CMP_'"$operator"'"}]}]}'
    for impl in swift runc; do
        case "$impl" in swift) rt=$ours ;; *) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
        tag=argument-$impl-$operator
        configure "$tag" "$root" true "$policy" '["/bin/sh","-ec","/bin/seccomp-probe argument '"$match"' denied; /bin/seccomp-probe argument '"$miss"' allowed"]'
        step "$tag" $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        grep -qx 'argument: EACCES' "$results/$tag.stdout" && grep -qx 'argument: allowed' "$results/$tag.stdout" || fail 'argument comparison failed'
    done
done
# Distinct argument indices use AND; repeated indices preserve runc's OR.
for combination in and or; do
    case "$combination" in
        and) conditions='[{"index":0,"value":100,"op":"SCMP_CMP_EQ"},{"index":1,"value":200,"op":"SCMP_CMP_EQ"}]'; command='/bin/seccomp-probe arguments 100 200 denied; /bin/seccomp-probe arguments 100 201 allowed; /bin/seccomp-probe arguments 101 200 allowed' ;;
        or) conditions='[{"index":0,"value":100,"op":"SCMP_CMP_EQ"},{"index":0,"value":101,"op":"SCMP_CMP_EQ"}]'; command='/bin/seccomp-probe argument 100 denied; /bin/seccomp-probe argument 101 denied; /bin/seccomp-probe argument 102 allowed' ;;
    esac
    for impl in swift runc; do
        case "$impl" in swift) rt=$ours ;; *) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
        tag=combination-$impl-$combination
        policy='{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getpgid"],"action":"SCMP_ACT_ERRNO","errnoRet":13,"args":'"$conditions"'}]}'
        configure "$tag" "$root" true "$policy" '["/bin/sh","-ec","'"$command"'"]'
        step "$tag" $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    done
done
# Actions that allow, return ENOSYS without a tracer, or terminate with SIGSYS.
for action in LOG TRACE TRAP KILL KILL_THREAD KILL_PROCESS; do
    for impl in swift runc; do
        case "$impl" in swift) rt=$ours ;; *) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
        tag=action-$impl-$action
        policy='{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getpgid"],"action":"SCMP_ACT_'"$action"'"}]}'
        mode=identity-allowed
        [ "$action" != TRACE ] || mode=identity-enosys
        configure "$tag" "$root" true "$policy" '["/bin/seccomp-probe","'"$mode"'"]'
        set +e
        $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        status=$?
        set -e
        case "$action" in
            LOG|TRACE) [ "$status" = 0 ] || { dump "$tag"; fail "$action failed"; } ;;
            *) [ "$status" = 159 ] || { dump "$tag"; fail "$action did not terminate with SIGSYS: $status"; } ;;
        esac
        [ ! -d "$cg/$fixture/$tag" ] || fail 'action leaked cgroup'
    done
done
for flags in '[]' '["SECCOMP_FILTER_FLAG_LOG"]' '["SECCOMP_FILTER_FLAG_SPEC_ALLOW"]' '["SECCOMP_FILTER_FLAG_TSYNC"]'; do
    tag=seccomp-flags
    configure "$tag" "$root" true '{"defaultAction":"SCMP_ACT_ALLOW","flags":'"$flags"'}' '["/bin/seccomp-probe","allowed"]'
    step "$tag" $ours run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
done
# An inherited filter refusing new filter loads must fail without a workload.
tag=seccomp-load-fails
configure "$tag" "$root" false '{"defaultAction":"SCMP_ACT_ALLOW"}' '["/bin/echo","must-not-run"]'
restricted="$rootfs/bin/seccomp-probe deny-load $ours"
expect_failure "$restricted" "$tag" created 'load linux.seccomp filter'
[ ! -d "$cg/$fixture/$tag" ] || fail 'load failure leaked cgroup'
for bad_policy in '{"defaultAction":"SCMP_ACT_NOTIFY"}' '{"defaultAction":"SCMP_ACT_ALLOW","flags":["SECCOMP_FILTER_FLAG_NEW_LISTENER"]}' '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["sct_missing_syscall"],"action":"SCMP_ACT_ERRNO"}]}'; do
    tag=seccomp-invalid
    configure "$tag" "$root" true "$bad_policy" '["/bin/echo","must-not-run"]'
    for mode in foreground created; do expect_failure "$ours" "$tag" "$mode" 'linux.seccomp'; done
    [ ! -d "$cg/$fixture/$tag" ] || fail 'invalid policy leaked cgroup'
done
echo 'Seccomp integration passed.'
