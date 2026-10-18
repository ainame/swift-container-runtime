#!/bin/sh
# Opt-in pinned image check in an externally prepared private network namespace.
set -eu
[ "$#" -eq 4 ] || { echo "Usage: $0 LINUX_RUNTIME SOCKET NAMESPACE IMAGE@sha256:DIGEST" >&2; exit 2; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
holder=
cleanup() {
    if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || :; wait "$holder" 2>/dev/null || :; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
"${CC:-clang}" -static -O2 -Wall -Wextra -Werror "$here/fixtures/network-probe.c" -o "$scratch/probe"
unshare --net "$scratch/probe" server "$scratch/port" &
holder=$!
deadline=$(($(date +%s) + 30))
until [ -s "$scratch/port" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo 'namespace listener timed out' >&2; exit 1; }
    sleep 0.05
done
port=$(cat "$scratch/port")
"$scratch/probe" outside "$port"
host=$(readlink /proc/self/ns/net)
ENGINE_NETWORK_NAMESPACE_PATH=/proc/$holder/ns/net ENGINE_NETWORK_TEST_PORT=$port \
    sh "$here/containerd-image-integration.sh" "$@"
[ "$(readlink /proc/self/ns/net)" = "$host" ] || { echo 'caller network changed' >&2; exit 1; }
"$scratch/probe" outside "$port"
echo 'containerd-network: PASS (supplied namespace identity, private TCP, image exec, caller isolation and cleanup)'
