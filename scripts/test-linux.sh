#!/bin/sh
# Apple container 0.9+; each invocation creates a disposable Linux VM.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=debug
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [--configuration debug|release|all] [SUITE ...]"
        echo "Default: debug unit tests and integration suites; select suites for focused work."
        echo "Use --configuration all for review, or --list to list suites."
        exit 0 ;;
    --list) exec sh "$root/scripts/run-integration.sh" --list ;;
esac
if [ "${1:-}" = --configuration ]; then
    [ "$#" -ge 2 ] || { echo "--configuration needs a value" >&2; exit 2; }
    configuration=$2
    shift 2
fi
case "$configuration" in
    debug|release|all) ;;
    *) echo "Unknown configuration: $configuration" >&2; exit 2 ;;
esac
# Reject typos before paying for VM startup, package installation, or builds.
sh "$root/scripts/run-integration.sh" --check "$@"
container run --rm --cpus 4 --memory 4G \
    --volume "$root:/workspace" --workdir /workspace swift:6.4.1 \
    /bin/sh -eu -c '
        # cgroup v2 delegation for the cgroup and CPU integration, before any
        # child starts: this top-level shell (and so every later gate) moves
        # into the /runner leaf, leaving the root without processes so that
        # it may enable memory, pids, cpu, and cpuset for the test subtrees. The VM
        # is discarded afterwards; no other process is moved.
        mkdir /sys/fs/cgroup/runner
        echo $$ > /sys/fs/cgroup/runner/cgroup.procs
        echo "+memory +pids +cpu +cpuset" > /sys/fs/cgroup/cgroup.subtree_control \
            || { echo "root cgroup still holds:"; cat /sys/fs/cgroup/cgroup.procs; exit 1; }
        swift --version
        swift --version | grep -q "Swift version 6.4.1 "
        # OCI fixtures: static BusyBox rootfs and runc for comparison, in the VM only.
        # The rlimit, readonly, path and CPU probes are linked statically by the image clang against glibc.
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq busybox-static runc > /dev/null
        configuration=$1
        shift
        case "$configuration" in
            all) configurations="debug release" ;;
            *) configurations=$configuration ;;
        esac
        # A unit-test invocation also builds the executable. Each selected suite
        # then uses that configuration; debug is the development default.
        for configuration in $configurations; do
            swift test -c "$configuration" --disable-automatic-resolution --scratch-path .build/linux-6.4.1
            sh scripts/run-integration.sh \
                ".build/linux-6.4.1/$configuration/swift-container-runtime" "$@"
        done
    ' test-linux "$configuration" "$@"
