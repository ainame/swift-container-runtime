#!/bin/sh
# Build the pinned upstream tests and a native static BusyBox rootfs on Linux.
# The caller installs Go, make, git, a C compiler and busybox-static first.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
checkout=${1:?Usage: prepare-runtime-tools.sh CHECKOUT}
revision=$(cat "$root/scripts/runtime-tools-revision")
if [ ! -d "$checkout" ]; then
    git init -q "$checkout"
    git -C "$checkout" remote add origin https://github.com/opencontainers/runtime-tools.git
fi
[ -z "$(git -C "$checkout" status --porcelain --untracked-files=no)" ] || {
    echo "runtime-tools checkout has tracked changes" >&2; exit 1;
}
git -C "$checkout" fetch --depth 1 origin "$revision"
git -C "$checkout" checkout --detach "$revision"
make -C "$checkout" runtimetest validation-executables
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
# tar preserves the staging root's permissions. A mktemp directory's 0700
# would prevent a non-root container user from executing /runtimetest.
chmod 755 "$stage"
mkdir -p "$stage/bin" "$stage/etc" "$stage/proc" "$stage/sys" "$stage/dev" "$stage/tmp"
chmod 1777 "$stage/tmp"
cp /bin/busybox "$stage/bin/busybox"
# Lifecycle helpers do not all copy the probe into their generated bundle.
cp "$checkout/runtimetest" "$stage/runtimetest"
for applet in $(/bin/busybox --list); do
    [ "$applet" = busybox ] || ln -s busybox "$stage/bin/$applet"
done
tar -czf "$checkout/rootfs-$(go env GOARCH).tar.gz" -C "$stage" .
