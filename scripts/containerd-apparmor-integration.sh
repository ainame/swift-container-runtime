#!/bin/sh
# Opt-in image check with containerd's generated default AppArmor profile, on
# a host with AppArmor enabled. Init and engine exec must both be confined.
set -eu
[ "$#" -eq 4 ] || { echo "Usage: $0 LINUX_RUNTIME SOCKET NAMESPACE IMAGE@sha256:DIGEST" >&2; exit 2; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
grep -q '^Y' /sys/module/apparmor/parameters/enabled 2>/dev/null || { echo 'AppArmor is not enabled' >&2; exit 2; }
ENGINE_APPARMOR=${ENGINE_APPARMOR:-sct-default} sh "$here/containerd-image-integration.sh" "$@"
echo 'containerd-apparmor: PASS (generated default profile on init and exec, image cleanup)'
