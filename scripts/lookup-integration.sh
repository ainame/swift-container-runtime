#!/bin/sh
# process.args[0] lookup: Go exec.LookPath semantics as runc applies them,
# through foreground run, create/start, the exec command, and standalone
# process JSON, compared with runc. Every runtime is started with the
# caller PATH set to /third, a directory that exists only inside the
# rootfs, so any use of the caller's PATH would find a tool there.
# Run as root inside a disposable Linux VM. Requires a statically linked
# BusyBox (BUSYBOX, default /bin/busybox).
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/srunc}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-auto}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
results=$scratch/results

fail() {
    echo "lookup-integration: $*" >&2
    exit 1
}

if ldd "$busybox" >/dev/null 2>&1; then
    fail "BusyBox at $busybox must be statically linked"
fi
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac
runtimes=ours
if [ "$compare" = 1 ]; then
    runtimes="ours theirs"
    runc_binary=$(command -v runc)
fi
command_of() {
    case "$1" in
    ours) echo "timeout -k 2 30 env PATH=/third $runtime --root $scratch/state" ;;
    theirs) echo "timeout -k 2 30 env PATH=/third $runc_binary --root $scratch/runc-state" ;;
    esac
}

cleanup() {
    for rt in $runtimes; do
        cmd=$(command_of "$rt")
        for id in $($cmd list -q 2>/dev/null); do $cmd delete --force "$id" >/dev/null 2>&1 || :; done
    done
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Rootfs: static BusyBox in /bin plus PATH fixtures, each "tool" printing
# where it was found:
#   /first/tool    a directory          /second/tool  a non-executable file
#   /third/tool    executable           /links        symlink to /third
#   /rootonly/tool 0700, root only      /all/tool     executable by anyone
#   /work/tool     executable, relative lookups use cwd /work
rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp" "$results" \
    "$rootfs/first/tool" "$rootfs/second" "$rootfs/third" "$rootfs/rootonly" "$rootfs/all" "$rootfs/work"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
tool() { # PATH MODE OUTPUT
    printf '#!/bin/sh\necho %s\n' "$3" > "$rootfs/$1"
    chmod "$2" "$rootfs/$1"
}
tool second/tool 0644 second
tool third/tool 0755 third
tool rootonly/tool 0700 rootonly
tool all/tool 0755 all
tool work/tool 0755 work
ln -s /third "$rootfs/links"

bundles=$scratch/bundles
mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]}
]'
# process_json ARGS_JSON ENV_JSON CWD UID
process_json() {
    echo "{\"terminal\": false, \"user\": {\"uid\": $4, \"gid\": $4}, \"args\": $1, \"env\": $2, \"cwd\": \"$3\"}"
}
# bundle NAME ARGS_JSON ENV_JSON [CWD [UID]]
bundle() {
    mkdir -p "$bundles/$1"
    cat > "$bundles/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": $(process_json "$2" "$3" "${4:-/}" "${5:-0}"),
  "hostname": "lookupbox",
  "mounts": $mounts,
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}
}
EOF
}

# timed_out STATUS: timeout(1) expired or the command was killed. Such a
# status never counts as an expected failure, for either runtime.
timed_out() { case "$1" in 124 | 137 | 143) return 0 ;; *) return 1 ;; esac; }

# outcome RT TAG EXPECTED PATTERN STATUS -- COMMAND...: runs the command once.
# A non-empty EXPECTED requires success with exactly that stdout. An empty
# one requires failure with no stdout; for this runtime the exit status must
# be STATUS (125 for run, 1 for create and exec) with PATTERN in stderr, and
# runc may fail with any status other than a timeout.
outcome() {
    rt=$1 tag=$2 expected=$3 pattern=$4 failure=$5
    shift 6
    set +e
    "$@" < /dev/null > "$results/$tag.out" 2> "$results/$tag.err"
    status=$?
    set -e
    actual=$(cat "$results/$tag.out")
    if [ -n "$expected" ]; then
        [ "$status" = 0 ] && [ "$actual" = "$expected" ] && return 0
    elif [ "$status" != 0 ] && ! timed_out "$status" && [ -z "$actual" ]; then
        [ "$rt" = theirs ] && return 0
        [ "$status" = "$failure" ] && grep -q -- "$pattern" "$results/$tag.err" && return 0
    fi
    cat "$results/$tag.err" >&2
    fail "$tag: status $status, stdout '$actual', expected '${expected:-a failure matching $pattern}'"
}

# run_case NAME EXPECTED PATTERN ARGS_JSON ENV_JSON [CWD [UID]]: foreground run.
run_case() {
    name=$1 expected=$2 pattern=$3
    shift 3
    bundle "$name" "$@"
    for rt in $runtimes; do
        cmd=$(command_of "$rt")
        outcome "$rt" "run-$name-$rt" "$expected" "$pattern" 125 -- $cmd run --bundle "$bundles/$name" "$name"
        # A failed run leaves no container behind.
        test -z "$($cmd list -q)" || fail "run-$name-$rt left a container"
    done
}

notfound='executable file not found'
relative='relative to the current directory'

# Bare names search the workload's PATH in order: directories, files that
# are not executable, and names below a non-directory are skipped, and the
# first executable candidate wins. Symlinks resolve inside the container.
run_case later-candidate third "" '["tool"]' '["PATH=/first:/second:/bin/busybox:/third:/all"]'
run_case symlink third "" '["tool"]' '["PATH=/links"]'
run_case last-path-wins third "" '["tool"]' '["PATH=/all", "PATH=/third"]'
run_case lexical-join third "" '["tool"]' '["PATH=/all/../third/"]'
# Permission is checked with the workload credentials.
run_case root-permission rootonly "" '["tool"]' '["PATH=/rootonly:/all"]'
run_case user-permission all "" '["tool"]' '["PATH=/rootonly:/all"]' / 1000
run_case user-denied "" "$notfound" '["tool"]' '["PATH=/rootonly"]' / 1000
# argv[0] is passed unchanged: the shell's $0 and PID 1's cmdline both
# start with the bare name, not the resolved /bin/sh.
run_case argv0 "$(printf 'sh\nsh')" "" '["sh", "-c", "echo $0; head -c 2 /proc/1/cmdline"]' '["PATH=/bin"]'
# Without a usable workload PATH nothing is found, although the caller's
# PATH (/third) would have found it.
run_case missing-path "" "$notfound" '["tool"]' '[]'
run_case empty-path "" "$notfound" '["tool"]' '["PATH="]'
run_case unknown-command "" "$notfound" '["no-such-command"]' '["PATH=/bin:/third"]'
run_case only-unusable "" "$notfound" '["tool"]' '["PATH=/first:/second"]'
# A first match through an empty or relative element is refused (Go's
# ErrDot) rather than trying later elements; a later absolute match after
# a relative miss is fine.
run_case empty-element "" "$relative" '["tool"]' '["PATH=:/third"]' /work
run_case dot-element "" "$relative" '["tool"]' '["PATH=.:/third"]' /work
run_case relative-element "" "$relative" '["true"]' '["PATH=bin"]' /
run_case relative-miss third "" '["tool"]' '["PATH=missing:/third"]' /work
# Names with a slash bypass PATH and may be relative to the cwd.
run_case explicit-relative work "" '["./tool"]' '["PATH=/third"]' /work
run_case explicit-nested third "" '["../third/tool"]' '[]' /work
run_case explicit-absolute all "" '["/all/tool"]' '["PATH=/third"]'
run_case explicit-not-executable "" 'permission denied' '["/second/tool"]' '["PATH=/third"]'
run_case explicit-directory "" 'is a directory' '["/first/tool"]' '["PATH=/third"]'
run_case explicit-missing "" 'no such file' '["./tool"]' '["PATH=/third"]' /

# create resolves the name (and fails) before start; start executes the
# resolved file, so a file that vanishes in between never runs. This
# runtime also fails that start; runc's exit status is not compared.
bundle created '["tool"]' '["PATH=/second:/third"]'
bundle created-missing '["tool"]' '["PATH=/second"]'
for rt in $runtimes; do
    cmd=$(command_of "$rt")
    outcome "$rt" "create-missing-$rt" "" "$notfound" 1 -- $cmd create --bundle "$bundles/created-missing" missing
    test -z "$($cmd list -q)" || fail "create-missing-$rt left a container"
    $cmd create --bundle "$bundles/created" created < /dev/null > "$results/created-$rt.out" 2>&1 \
        || fail "create-$rt failed: $(cat "$results/created-$rt.out")"
    $cmd start created
    for _ in $(seq 100); do
        grep -q third "$results/created-$rt.out" && break
        sleep 0.05
    done
    test "$(cat "$results/created-$rt.out")" = third || fail "start-$rt printed '$(cat "$results/created-$rt.out")'"
    $cmd delete --force created

    $cmd create --bundle "$bundles/created" vanished < /dev/null \
        > "$results/vanished-$rt.out" 2> "$results/vanished-$rt.err" \
        || fail "create-vanished-$rt failed: $(cat "$results/vanished-$rt.err")"
    mv "$rootfs/third/tool" "$rootfs/third/tool.moved"
    set +e
    $cmd start vanished > "$results/vanished-$rt.start.out" 2>&1
    status=$?
    set -e
    ! timed_out "$status" || fail "start-vanished-$rt timed out"
    [ "$rt" = theirs ] || [ "$status" != 0 ] || fail "start-vanished-$rt succeeded"
    # runc start can return before the init's execve, so the file stays
    # missing until the init has exited.
    deadline=$(($(date +%s) + 10))
    until $cmd state vanished | grep -q '"stopped"'; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "start-vanished-$rt: init did not stop"
        sleep 0.05
    done
    # The workload's stdout stays empty; diagnostics go to stderr, which
    # may name the missing file.
    if [ -s "$results/vanished-$rt.out" ]; then
        for kind in out err start.out; do
            echo "--- vanished-$rt.$kind" >&2
            cat "$results/vanished-$rt.$kind" >&2
        done
        fail "start-vanished-$rt ran the workload"
    fi
    mv "$rootfs/third/tool.moved" "$rootfs/third/tool"
    $cmd delete vanished
done

# exec, in a container whose own bundle PATH is /bin.
bundle loop '["sleep", "1000"]' '["PATH=/bin"]'
for rt in $runtimes; do
    cmd=$(command_of "$rt")
    $cmd run --detach --bundle "$bundles/loop" loop < /dev/null > /dev/null 2>&1 || fail "run-loop-$rt failed"
    outcome "$rt" "exec-bundle-path-$rt" "" "$notfound" 1 -- $cmd exec loop tool
    outcome "$rt" "exec-env-path-$rt" third "" 1 -- $cmd exec -e PATH=/third loop tool
    outcome "$rt" "exec-env-last-$rt" third "" 1 -- $cmd exec -e PATH=/all -e PATH=/third loop tool
    outcome "$rt" "exec-argv0-$rt" sh "" 1 -- $cmd exec loop sh -c 'echo "$0"'
    outcome "$rt" "exec-user-$rt" all "" 1 -- $cmd exec -u 1000:1000 -e PATH=/rootonly:/all loop tool
    outcome "$rt" "exec-relative-$rt" work "" 1 -- $cmd exec --cwd /work loop ./tool
    outcome "$rt" "exec-dot-$rt" "" "$relative" 1 -- $cmd exec --cwd /work -e PATH=:/third loop tool
    outcome "$rt" "exec-unknown-$rt" "" "$notfound" 1 -- $cmd exec loop no-such-command
    process_json '["tool"]' '["PATH=/second:/third"]' / 0 > "$scratch/process-$rt.json"
    outcome "$rt" "exec-process-$rt" third "" 1 -- $cmd exec -p "$scratch/process-$rt.json" loop
    process_json '["tool"]' '[]' / 0 > "$scratch/process-empty-$rt.json"
    outcome "$rt" "exec-process-missing-$rt" "" "$notfound" 1 -- $cmd exec -p "$scratch/process-empty-$rt.json" loop
    # Failed execs leave the init running.
    $cmd state loop | grep -q '"running"' || fail "exec failures stopped loop under $rt"
    $cmd delete --force loop
done

echo "lookup-integration: PASS"
