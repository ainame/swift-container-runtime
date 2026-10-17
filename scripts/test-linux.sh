#!/bin/sh
# Apple container 0.9+; each invocation creates a disposable Linux VM.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
        swift test --disable-automatic-resolution --scratch-path .build/linux-6.4.1
        swift build --disable-automatic-resolution --scratch-path .build/linux-6.4.1
        sh scripts/integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        sh scripts/oci-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/lifecycle-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/credentials-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/capabilities-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/rlimits-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/readonly-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/path-controls-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/cgroup-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/cpu-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/cpuset-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/freezer-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        swift test -c release --disable-automatic-resolution --scratch-path .build/linux-6.4.1
        sh scripts/integration.sh .build/linux-6.4.1/release/swift-container-runtime
        sh scripts/oci-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/lifecycle-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/credentials-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/capabilities-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/rlimits-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/readonly-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/path-controls-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/cgroup-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/cpu-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/cpuset-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/freezer-integration.sh .build/linux-6.4.1/release/swift-container-runtime
    '
