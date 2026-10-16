#!/bin/sh
# Apple container 0.9+; each invocation creates a disposable Linux VM.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
container run --rm --cpus 4 --memory 4G \
    --volume "$root:/workspace" --workdir /workspace swift:6.4 \
    /bin/sh -eu -c 'swift test --scratch-path .build/linux; swift build --scratch-path .build/linux; sh scripts/integration.sh .build/linux/debug/swift-container-runtime'
