#!/bin/sh
# Container OOM policy, early setup and persisted exec policy against runc.
set -eu
CGROUP_FIXTURE_LIBRARY=1
CGROUP_FIXTURE_NAME=sct-oom-$$
. "$(dirname -- "$0")/cpu-integration.sh"
caller_score=$(cat /proc/self/oom_score_adj)
configure() {
    oom_tag=$1 oom_user=$2 oom_value=$3 oom_args=$4
    write_config "$oom_tag" "$oom_user" "$(cgroup_fields "/$fixture/$oom_tag" '{}')" "$oom_args"
    if [ "$oom_value" != absent ]; then
        sed "s/\"terminal\": false/\"terminal\": false, \"oomScoreAdj\": $oom_value/" "$bundles/$oom_tag/config.json" > "$scratch/config"
        mv "$scratch/config" "$bundles/$oom_tag/config.json"
    fi
}
assert_score() {
    [ "$(cat "$1")" = "$2" ] || fail "OOM score at $1 differs from $2"
}
exercise() {
    impl=$1 rt=$2
    for label in root user; do
        case "$label" in root) credentials=$root ;; *) credentials=$user ;; esac
        for value in absent null -1000 -321 0 321 1000; do
            tag=oom-$impl-$label-$value
            expected=$value
            case "$value" in absent|null) expected=$caller_score ;; esac
            configure "$tag" "$credentials" "$value" '["/bin/cat","/proc/self/oom_score_adj"]'
            step "$tag" $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            assert_score "$results/$tag.stdout" "$expected"
            [ ! -d "$cg/$fixture/$tag" ] || fail 'foreground OOM cgroup leaked'
            configure "$tag" "$credentials" "$value" '["/bin/sleep","1000"]'
            step "$tag" $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
            init=$(pid_of "$rt" "$tag")
            assert_score "/proc/$init/oom_score_adj" "$expected"
            step "$tag" $rt start "$tag"
            # Command exec reads process defaults from an edited bundle, but OOM
            # policy remains the original container setting, as runc does.
            sed 's/"oomScoreAdj": [-0-9null]*/"oomScoreAdj": 777/' "$bundles/$tag/config.json" > "$scratch/config"
            mv "$scratch/config" "$bundles/$tag/config.json"
            step "$tag" $rt exec "$tag" /bin/cat /proc/self/oom_score_adj > "$results/$tag.exec" 2> "$results/$tag.stderr"
            assert_score "$results/$tag.exec" "$expected"
            printf '{"args":["/bin/cat","/proc/self/oom_score_adj"],"cwd":"/","user":%s,"oomScoreAdj":888}' "$credentials" > "$scratch/process.json"
            rm -rf "$bundles/$tag"
            step "$tag" $rt exec --process "$scratch/process.json" "$tag" > "$results/$tag.exec" 2> "$results/$tag.stderr"
            assert_score "$results/$tag.exec" "$expected"
            assert_score "/proc/$init/oom_score_adj" "$expected"
            step "$tag" $rt delete --force "$tag"
            [ ! -d "$cg/$fixture/$tag" ] || fail 'OOM delete leaked cgroup'
        done
    done
    echo "$impl: inherited/null, -1000...1000, root/nonroot, create-time value, init/exec and original policy passed"
}
exercise swift "$ours"
if [ "$compare" = 1 ]; then exercise runc "$theirs"; fi
# Preserve a nonzero caller value when absent, but honor an explicit reset to 0.
# Each wrapper is a fixture-owned child; the invoking shell stays unchanged.
cat > "$scratch/with-score" <<'WRAPPER'
#!/bin/sh
value=$1
shift
echo "$value" > /proc/self/oom_score_adj
exec "$@"
WRAPPER
chmod +x "$scratch/with-score"
for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; *) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    for value in absent 0; do
        tag=oom-parent-$impl-$value
        expected=275
        [ "$value" != 0 ] || expected=0
        configure "$tag" "$root" "$value" '["/bin/cat","/proc/self/oom_score_adj"]'
        step "$tag" "$scratch/with-score" 275 $rt run --bundle "$bundles/$tag" "$tag" > "$results/$tag.stdout" 2> "$results/$tag.stderr"
        assert_score "$results/$tag.stdout" "$expected"
    done
    tag=oom-parent-exec-$impl
    configure "$tag" "$root" absent '["/bin/sleep","1000"]'
    step "$tag" "$scratch/with-score" 275 $rt create --bundle "$bundles/$tag" "$tag" < /dev/null > "$results/$tag.stdout" 2> "$results/$tag.stderr"
    init=$(pid_of "$rt" "$tag")
    assert_score "/proc/$init/oom_score_adj" 275
    step "$tag" $rt start "$tag"
    step "$tag" "$scratch/with-score" 350 $rt exec "$tag" /bin/cat /proc/self/oom_score_adj > "$results/$tag.exec" 2> "$results/$tag.stderr"
    assert_score "$results/$tag.exec" 350
    assert_score "/proc/$init/oom_score_adj" 275
    step "$tag" $rt delete --force "$tag"
done
# This fixture has CAP_SYS_RESOURCE; dropping only that capability keeps
# namespace setup available while the negative OOM write must fail earlier.
for impl in swift runc; do
    case "$impl" in swift) rt=$ours ;; *) [ "$compare" = 1 ] || continue; rt=$theirs ;; esac
    tag=oom-permission-$impl
    configure "$tag" "$root" -1 '["/bin/echo","must-not-run"]'
    restricted="setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-sys_resource $rt"
    for mode in foreground created; do
        case "$impl" in swift) reason=process.oomScoreAdj ;; *) reason=oom_score_adj ;; esac
        expect_failure "$restricted" "$tag" "$mode" "$reason"
    done
    [ ! -d "$cg/$fixture/$tag" ] || fail 'denied OOM write leaked cgroup'
done
# Range errors fail before a launcher exists.
for value in -1001 1001; do
    tag=oom-invalid
    configure "$tag" "$root" "$value" '["/bin/echo","must-not-run"]'
    for mode in foreground created; do expect_failure "$ours" "$tag" "$mode" 'process.oomScoreAdj'; done
    [ ! -d "$cg/$fixture/$tag" ] || fail 'invalid OOM score leaked cgroup'
done
assert_score /proc/self/oom_score_adj "$caller_score"
echo 'OOM adjustment integration passed.'
