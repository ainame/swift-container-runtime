#!/bin/sh
# Apple container 0.9+; each invocation creates a disposable Linux VM.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
container run --rm --cpus 4 --memory 4G \
    --volume "$root:/workspace" --workdir /workspace swift:6.4.1 \
    /bin/sh -eu -c '
        swift --version
        swift --version | grep -q "Swift version 6.4.1 "
        # OCI fixtures: static BusyBox rootfs and runc for comparison, in the VM only.
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq busybox-static runc > /dev/null
        swift test --disable-automatic-resolution --scratch-path .build/linux-6.4.1
        swift build --disable-automatic-resolution --scratch-path .build/linux-6.4.1
        sh scripts/integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        sh scripts/oci-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/lifecycle-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/credentials-integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        swift test -c release --disable-automatic-resolution --scratch-path .build/linux-6.4.1
        sh scripts/integration.sh .build/linux-6.4.1/release/swift-container-runtime
        sh scripts/oci-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/lifecycle-integration.sh .build/linux-6.4.1/release/swift-container-runtime
        RUNC_COMPARE=1 sh scripts/credentials-integration.sh .build/linux-6.4.1/release/swift-container-runtime
    '
