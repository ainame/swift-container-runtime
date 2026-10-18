#!/bin/sh
# OCI foreground run checks. Run as root inside a disposable Linux VM.
# Requires a statically linked BusyBox (BUSYBOX, default /bin/busybox).
# RUNC_COMPARE=auto (default) runs the shared checks under runc when it is
# installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/swift-container-runtime}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
busybox=${BUSYBOX:-/bin/busybox}
compare=${RUNC_COMPARE:-auto}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

if ldd "$busybox" >/dev/null 2>&1; then
    echo "BusyBox at $busybox must be statically linked" >&2
    exit 1
fi
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || { echo "RUNC_COMPARE=1 but runc is not installed" >&2; exit 1; } ;;
esac

before_hostname=$(hostname)
mount_count() { wc -l < /proc/self/mountinfo; }
before_mounts=$(mount_count)

# Shared rootfs: a static BusyBox with relative applet links.
bundle=$scratch/bundle
rootfs=$bundle/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev" "$rootfs/tmp"
cp "$busybox" "$rootfs/bin/busybox"
for applet in $("$rootfs/bin/busybox" --list); do
    test "$applet" = busybox || ln -s busybox "$rootfs/bin/$applet"
done
echo inside-rootfs > "$rootfs/marker"
echo host-only > "$scratch/host-marker"
cat > "$rootfs/probe.sh" <<EOF
set -eu
test "\$\$" = 1
test "\$(hostname)" = ocibox
test "\$(pwd)" = /work/sub
test "\$FOO" = "bar baz"
test "\$(env | grep -c '^FOO=')" = 1
test "\${EMPTY-unset}" = ""
test "\$EQ" = x=y=z
test "\$PATH" = /bin
test -z "\${HOST_ONLY+x}"
test "\$(cat /marker)" = inside-rootfs
test ! -e "$scratch/host-marker"
grep -q probe.sh /proc/1/cmdline
for device in null zero full random urandom tty; do test -c "/dev/\$device"; done
echo discard > /dev/null
test "\$(head -c 3 /dev/zero | wc -c)" = 3
test -L /dev/fd && test -L /dev/stdout && test -L /dev/ptmx && test -d /dev/pts
echo to-stdout
echo to-stderr >&2
EOF

# Inherited descriptors (fd 9 is a host directory) must not reach the
# workload; neither may runtime setup descriptors. Inspect after exec with no
# shell redirection, so the shell's saved stdio and script descriptors are
# gone: ls (PID 1 after exec) may hold only fds 0-2 and its own directory
# handle for /proc/1/fd. The caller checks the listing.
cat > "$rootfs/fds.sh" <<'EOF'
set -eu
test ! -e "/proc/$$/fd/9"
exec /bin/ls -l /proc/self/fd
EOF
# check_fds LISTING: every numbered descriptor above 2 must be ls's /proc/1/fd handle.
check_fds() {
    awk '
        $(NF - 1) == "->" && $(NF - 2) ~ /^[0-9]+$/ {
            fd = $(NF - 2); target = $NF
            if (fd + 0 > 2 && target != "/proc/1/fd") { print "leaked descriptor: " $0; bad = 1 }
            if (fd + 0 > 2 && target == "/proc/1/fd") own++
            entries++
        }
        END { if (entries < 3 || own > 1) { print "unexpected descriptor listing"; bad = 1 }; exit bad }
    ' "$1" >&2
}

mounts='[
  {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
  {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
  {"destination": "/dev/pts", "type": "devpts", "source": "devpts", "options": ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5"]}
]'

# write_config DIR PROCESS_JSON [EXTRA_TOP_LEVEL_JSON] [MOUNTS_JSON] [ROOT_PATH]
write_config() {
    mkdir -p "$1"
    cat > "$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "${5:-$rootfs}"},
  "process": $2,
  "hostname": "ocibox",
  "mounts": ${4:-$mounts},
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}${3:-}
}
EOF
}
default_env='["PATH=/bin"]'
process() { # process ARGS_JSON [ENV_JSON] [CWD]
    printf '{"terminal": false, "user": {"uid": 0, "gid": 0}, "args": %s, "env": %s, "cwd": "%s"}' \
        "$1" "${2:-$default_env}" "${3:-/}"
}

# The main bundle uses a relative root.path; the others use the absolute rootfs.
# Duplicate names: the last occurrence wins, including empty values and values containing '='.
probe_env='["PATH=/bin", "FOO=first", "EMPTY=nonempty", "EQ=a", "FOO=bar baz", "EMPTY=", "EQ=x=y=z"]'
write_config "$bundle" "$(process '["/bin/sh", "/probe.sh"]' "$probe_env" /work/sub)" "" "" rootfs
write_config "$scratch/fds" "$(process '["/bin/sh", "/fds.sh"]')"
write_config "$scratch/exit42" "$(process '["/bin/sh", "-c", "exit 42"]')"
write_config "$scratch/missing" "$(process '["/does/not/exist"]')"

run_ours() { "$runtime" run --bundle "$1" "$2"; }
run_runc() { runc --root "$scratch/runc-state" run --bundle "$1" "$2"; }

# Present in the runtime's environment; the workload must not see it.
export HOST_ONLY=leak

shared_checks() {
    name=$1 runner=$2
    # Each runtime must create the missing cwd itself.
    rm -rf "$rootfs/work"
    $runner "$bundle" "probe-$name" > "$scratch/out" 2> "$scratch/err"
    test "$(cat "$scratch/out")" = to-stdout
    test "$(cat "$scratch/err")" = to-stderr
    $runner "$scratch/fds" "fds-$name" 9< "$scratch" > "$scratch/fds-$name"
    check_fds "$scratch/fds-$name"

    set +e
    $runner "$scratch/exit42" "exit-$name"
    status=$?
    $runner "$scratch/missing" "missing-$name" 2> "$scratch/err"
    missing=$?
    set -e
    test "$status" = 42
    test "$missing" != 0
    test "$(hostname)" = "$before_hostname"
    test "$(mount_count)" = "$before_mounts"
    echo "$name: PID 1, rootfs, hostname, cwd, env, devices, descriptors, stdout/stderr, exit 42, missing exec ok"
}

shared_checks swift run_ours
if [ "$compare" = 1 ]; then
    shared_checks runc run_runc
fi

# Runtime-specific behavior.
set +e
"$runtime" run --bundle "$scratch/missing" missing 2> "$scratch/err"
status=$?
set -e
test "$status" = 125
grep -q 'exec workload:' "$scratch/err"

# Unlike runc, HOME is not synthesized from /etc/passwd.
write_config "$scratch/home" "$(process '["/bin/sh", "-c", "test -z \"${HOME+x}\""]')"
"$runtime" run --bundle "$scratch/home" home

# A relative bundle path resolves against the caller's cwd.
(cd "$bundle" && "$runtime" run --bundle . relative > /dev/null 2>&1)

# expect_setup_failure BUNDLE MESSAGE: fails with 125, never runs the
# workload (which would create /ran), and leaves the host unchanged.
expect_setup_failure() {
    rm -f "$rootfs/ran"
    set +e
    "$runtime" run --bundle "$1" setup-failure > "$scratch/out" 2> "$scratch/err"
    status=$?
    set -e
    test "$status" = 125 || { echo "expected 125 from $1, got $status" >&2; cat "$scratch/err" >&2; exit 1; }
    grep -q "$2" "$scratch/err" || { echo "expected '$2' from $1" >&2; cat "$scratch/err" >&2; exit 1; }
    test ! -s "$scratch/out"
    test ! -e "$rootfs/ran"
    test "$(hostname)" = "$before_hostname"
    test "$(mount_count)" = "$before_mounts"
}
touch_ran=$(process '["/bin/touch", "/ran"]')

write_config "$scratch/terminal" '{"terminal": true, "args": ["/bin/touch", "/ran"], "cwd": "/"}'
expect_setup_failure "$scratch/terminal" 'process.terminal is not implemented'
write_config "$scratch/seccomp" "$touch_ran" ', "unknownField": {}'
expect_setup_failure "$scratch/seccomp" 'unsupported field(s): unknownField'
write_config "$scratch/oomscore" '{"args": ["/bin/touch", "/ran"], "cwd": "/", "oomScoreAdj": 100}'
expect_setup_failure "$scratch/oomscore" 'unsupported field(s): process.oomScoreAdj'
write_config "$scratch/caps" '{"args": ["/bin/touch", "/ran"], "cwd": "/", "capabilities": {"bounding": ["CAP_NOPE"]}}'
expect_setup_failure "$scratch/caps" 'unknown capability "CAP_NOPE"'
write_config "$scratch/bind" "$touch_ran" "" '[{"destination": "/host", "type": "bind", "source": "/", "options": ["rbind", "rshared"]}]'
expect_setup_failure "$scratch/bind" 'rshared is not implemented'
write_config "$scratch/norootfs" "$touch_ran" "" "" "$scratch/absent"
expect_setup_failure "$scratch/norootfs" 'resolve root.path'

# Mount destinations must not follow symlinks out of the rootfs, whether
# absolute or relative, and must not create anything on the host.
mkdir "$scratch/hostdir"
ln -s "$scratch/hostdir" "$rootfs/absolute-escape"
ln -s ../../hostdir "$rootfs/relative-escape"
for link in absolute-escape relative-escape; do
    write_config "$scratch/$link" "$touch_ran" "" "$(printf '%s' "$mounts" | sed '$d'), {\"destination\": \"/$link/sub\", \"type\": \"tmpfs\"}]"
    expect_setup_failure "$scratch/$link" "resolve mount destination /$link/sub"
    test -z "$(ls -A "$scratch/hostdir")"
done
rm "$rootfs/absolute-escape" "$rootfs/relative-escape"

# The final component is checked too: /proc itself as a symlink to the host.
mv "$rootfs/proc" "$rootfs/proc.real"
ln -s "$scratch/hostdir" "$rootfs/proc"
write_config "$scratch/proc-link" "$touch_ran"
expect_setup_failure "$scratch/proc-link" 'resolve mount destination /proc'
test -z "$(ls -A "$scratch/hostdir")"
rm "$rootfs/proc"
mv "$rootfs/proc.real" "$rootfs/proc"

# A failure after proc, /dev, and /dev/pts are mounted leaves no host mounts.
touch "$rootfs/not-a-directory"
write_config "$scratch/late" "$touch_ran" "" "$(printf '%s' "$mounts" | sed '$d'), {\"destination\": \"/not-a-directory/x\", \"type\": \"tmpfs\"}]"
expect_setup_failure "$scratch/late" 'resolve mount destination /not-a-directory/x: Not a directory'
rm "$rootfs/not-a-directory"

# The executable path is resolved inside the rootfs: a host-only program is missing.
test -x /usr/bin/env
write_config "$scratch/hostexec" "$(process '["/usr/bin/env"]')"
expect_setup_failure "$scratch/hostexec" 'exec workload:'

set +e
"$runtime" run --bundle "$scratch/exit42" exit
status=$?
set -e
test "$status" = 42

"$runtime" run --help > "$scratch/help"
grep -q -- --bundle "$scratch/help"

comparison=skipped
test "$compare" = 1 && comparison=runc
printf '%s\n' "OCI integration checks passed (comparison: $comparison): PID 1, rootfs isolation, hostname, cwd, env replacement, devices, stdio, exit status, missing exec, rejected config, symlink escapes, inherited descriptors, setup-failure cleanup."
