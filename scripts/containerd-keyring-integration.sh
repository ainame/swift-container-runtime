#!/bin/sh
# Opt-in image keyring identity check; this explicit profile permits keyctl.
set -eu
[ "$#" -eq 4 ] || { echo "Usage: $0 LINUX_RUNTIME SOCKET NAMESPACE IMAGE@sha256:DIGEST" >&2; exit 2; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
"${CC:-clang}" -static -O2 -Wall -Wextra -Werror "$here/fixtures/keyring-probe.c" -o "$scratch/probe"
ENGINE_KEYRING_PROBE=$scratch/probe sh "$here/containerd-image-integration.sh" "$@"
echo 'containerd-keyring: PASS (image init/exec session identity, shared session key and cleanup)'
