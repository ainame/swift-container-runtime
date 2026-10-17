#!/bin/sh
# Test fixture for scripts/lifecycle-integration.sh: detached processes in a
# PID namespace whose PID 1 (sleep) never reaps, like a hosted container
# whose PID 1 is tail. The exec launcher sits outside the container's PID
# namespace, so a detached exec process is reparented, as with runc, to the
# caller's nearest subreaper, never into the container. A zombie left
# anywhere in the container would keep its PID namespace from tearing down.
#
# MODE subreaper: run by scripts/fixtures/subreaper.c, the caller runc
# documents for detached processes; every exited process must be reaped.
# MODE plain: no subreaper, so only PID 1 could reap orphans and never does.
# A failed detached exec must still leave no zombie: the runtime reaps the
# process it killed (runc does too), and the container stops and deletes.
# Usage: detached-exec.sh MODE TAG "RUNTIME --root DIR" BUNDLE SCRATCH
set -eu
mode=$1 tag=$2 rt=$3 bundle=$4 scratch=$5
id=detached-exec-$mode-$tag
reaper=$PPID

fail() {
    echo "lifecycle-integration (detached exec, $mode, $tag): $*" >&2
    ps -eo pid,ppid,stat,wchan:30,args >&2 || :
    exit 1
}
trap '$rt delete --force "$id" > /dev/null 2>&1 || :' EXIT
stat_field() { # PID INDEX: a /proc/PID/stat field after the command name.
    stat_line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    index=$2
    set -- ${stat_line##*) }
    shift $((index - 1))
    echo "$1"
}
alive() { case "$(stat_field "$1" 1)" in '' | Z | X | x) return 1 ;; esac; }
# Reaped: not even a zombie remains.
gone() { test ! -e "/proc/$1"; }
# reaper_children_are PID...: the subreaper's direct and adopted children,
# live or zombie, are exactly these. Every process's stat names its parent
# (zombies included, unlike their namespace links), and this works without
# the optional /proc/PID/task/TID/children file.
sorted() { tr ' ' '\n' | sed '/^$/d' | sort -n | tr '\n' ' '; }
reaper_children() {
    for entry in /proc/[0-9]*; do
        if [ "$(stat_field "${entry#/proc/}" 2)" = "$reaper" ]; then echo "${entry#/proc/}"; fi
    done
}
reaper_children_are() {
    test "$(reaper_children | sorted)" = "$(echo "$*" | sorted)"
}
wait_until() { # DESCRIPTION COMMAND...: polls for up to 10 seconds.
    description=$1
    shift
    deadline=$(($(date +%s) + 10))
    until "$@"; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for $description"
        sleep 0.05
    done
}
field() { sed -n "s/^ *\"$1\" *: *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p"; }
has_status() { test "$($rt state "$id" 2>/dev/null | field status)" = "$1"; }

# The topology: PID 1 here never reaps; only the subreaper mode has another
# reaper, and it is this shell's parent.
test "$(cat /proc/1/comm)" = sleep || fail "PID 1 is not the non-reaping sleep"
case "$mode" in
subreaper) test "$(cat "/proc/$reaper/comm")" = subreaper || fail "the caller is not the subreaper fixture" ;;
plain) test "$reaper" = 0 || fail "the caller must enter from outside this PID namespace" ;;
*) fail "unknown mode $mode" ;;
esac
if [ "$mode" = subreaper ]; then
    reaper_children_are "$$" || fail "the subreaper already has other children"
fi

$rt run -d -b "$bundle" "$id" < /dev/null > /dev/null 2>&1
pid=$($rt state "$id" | field pid)
container_namespace=$(readlink "/proc/$pid/ns/pid")
# The detached init, too, now belongs to the subreaper.
if [ "$mode" = subreaper ]; then
    reaper_children_are "$$" "$pid" || fail "detached init $pid does not belong to the subreaper"
fi

# A detached exec process shares the init's PID namespace and cgroup, and
# belongs to the caller's subreaper rather than to PID 1 or the container.
# Without a subreaper its exit could never be reaped, so plain skips it.
if [ "$mode" = subreaper ]; then
    $rt exec -d --pid-file "$scratch/$id.pid" "$id" /bin/sleep 1000
    exec_pid=$(cat "$scratch/$id.pid")
    test "$exec_pid" -gt 1
    alive "$exec_pid" || fail "detached exec process $exec_pid is not running"
    test "$(readlink "/proc/$exec_pid/ns/pid")" = "$container_namespace"
    test "$(cat "/proc/$exec_pid/cgroup")" = "$(cat "/proc/$pid/cgroup")"
    # exec -d returns after its launcher (runc: the runc process) has exited.
    test "$(stat_field "$exec_pid" 2)" = "$reaper" || fail "detached exec $exec_pid does not belong to the subreaper"
    kill -KILL "$exec_pid"
    wait_until "detached exec $exec_pid to be reaped" gone "$exec_pid"
fi

# A failed PID-file publication kills only the spawned process, and the
# runtime reaps it itself; the init keeps running. In plain mode nothing
# else could reap it, so the stop below would hang on its zombie.
if $rt exec -d --pid-file "$scratch/no-parent/$id.pid" "$id" /bin/sleep 1000 2> /dev/null; then
    fail "exec with an unwritable PID file succeeded"
fi
if [ "$mode" = subreaper ]; then
    wait_until "the subreaper to hold only this shell and init $pid" reaper_children_are "$$" "$pid"
fi
test "$($rt state "$id" | field status)" = running

# TERM stops the container: its PID namespace tears down and delete removes
# the state. The orphaned init is reaped by the subreaper; in plain mode it
# stays a zombie of PID 1, which shows that PID 1 really never reaps.
$rt kill "$id" TERM
wait_until "$id to become stopped" has_status stopped
if [ "$mode" = subreaper ]; then
    wait_until "init $pid to be reaped" gone "$pid"
else
    test "$(stat_field "$pid" 1)" = Z || fail "init $pid is not a zombie of the non-reaping PID 1"
    test "$(stat_field "$pid" 2)" = 1 || fail "init $pid is not a child of PID 1"
fi
$rt delete "$id"
if $rt state "$id" > /dev/null 2>&1; then fail "state of $id survived delete"; fi
# Every process ever left to the subreaper has been reaped.
if [ "$mode" = subreaper ]; then
    wait_until "the subreaper to hold only this shell" reaper_children_are "$$"
fi
echo "$tag: $mode detached processes under a non-reaping PID 1 ok"
