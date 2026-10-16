#!/bin/sh
# Apple container 0.9+; each invocation creates a disposable Linux VM.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
container run --rm --cpus 4 --memory 4G \
    --volume "$root:/workspace" --workdir /workspace swift:6.4.1 \
    /bin/sh -eu -c '
        swift --version
        swift --version | grep -q "Swift version 6.4.1 "
        swift test --disable-automatic-resolution --scratch-path .build/linux-6.4.1
        swift build --disable-automatic-resolution --scratch-path .build/linux-6.4.1
        sh scripts/integration.sh .build/linux-6.4.1/debug/swift-container-runtime
        swift build -c release --disable-automatic-resolution --scratch-path .build/linux-6.4.1
        sh scripts/integration.sh .build/linux-6.4.1/release/swift-container-runtime
    '
