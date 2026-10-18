#!/bin/sh
# Opt-in AppArmor confinement gate for a host with AppArmor enabled (for
# example Ubuntu). Loads two throwaway profiles, then compares init and exec
# confinement, exec overrides, recorded policy and an unknown profile with runc.
# Usage: sudo sh scripts/apparmor-integration.sh BINARY [RUNC]
set -eu
ours=$(realpath "$1")
theirs=${2:-$(command -v runc || true)}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
grep -q '^Y' /sys/module/apparmor/parameters/enabled 2>/dev/null || { echo "AppArmor is not enabled" >&2; exit 2; }
command -v apparmor_parser > /dev/null || { echo "apparmor_parser is required" >&2; exit 2; }
busybox=$(command -v busybox)

scratch=$(mktemp -d)
cleanup() {
    for rt in "$ours" ${theirs:+"$theirs"}; do
        for id in $($rt --root "$scratch/state-$(basename "$rt")" list -q 2>/dev/null); do
            $rt --root "$scratch/state-$(basename "$rt")" delete --force "$id" 2>/dev/null || true
        done
    done
    apparmor_parser -R "$scratch/profiles" 2>/dev/null || true
    rm -rf "$scratch"
}
trap cleanup EXIT
fail() { echo "apparmor-integration: $*" >&2; exit 1; }

# Two profiles that allow container setup; only sct-test denies /denied.
cat > "$scratch/profiles" <<'EOF'
abi <abi/4.0>,
profile sct-test flags=(attach_disconnected,mediate_deleted) {
  file, capability, network, unix, signal, ptrace, mount, umount, pivot_root, dbus,
  deny /denied r,
}
profile sct-alt flags=(attach_disconnected,mediate_deleted) {
  file, capability, network, unix, signal, ptrace, mount, umount, pivot_root, dbus,
}
EOF
apparmor_parser -r "$scratch/profiles"

rootfs=$scratch/rootfs
mkdir -p "$rootfs/bin" "$rootfs/proc" "$rootfs/dev"
cp "$busybox" "$rootfs/bin/busybox"
for applet in sh cat echo sleep; do ln -s busybox "$rootfs/bin/$applet"; done
echo secret > "$rootfs/denied"
chmod 644 "$rootfs/denied"
probe='["/bin/sh","-c","cat /proc/self/attr/apparmor/current; cat /denied >/dev/null 2>&1 && echo readable || echo denied"]'

# config TAG PROFILE USER NNP ARGS
config() {
    mkdir -p "$scratch/$1"
    profile=
    [ -z "$2" ] || profile=", \"apparmorProfile\": \"$2\""
    cat > "$scratch/$1/config.json" <<EOF
{
  "ociVersion": "1.0.2",
  "root": {"path": "$rootfs"},
  "process": {"terminal": false, "user": $3, "args": $5, "env": ["PATH=/bin"], "cwd": "/", "noNewPrivileges": $4$profile},
  "hostname": "aabox",
  "mounts": [{"destination": "/proc", "type": "proc", "source": "proc"},
             {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "mode=755"]}],
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "ipc"}, {"type": "uts"}]}
}
EOF
}
expect_output() {
    [ "$(cat "$1")" = "$2" ] || { echo "got:"; cat "$1"; fail "$3: expected '$2'"; }
}

# run_confined WHO USER NNP: a foreground init under sct-test.
run_confined() {
    tag=aa-run-$1-$impl
    config "$tag" sct-test "$2" "$3" "$probe"
    $rt run --bundle "$scratch/$tag" "$tag" > "$scratch/$tag.out" 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag failed"; }
    expect_output "$scratch/$tag.out" "sct-test (enforce)
denied" "$tag"
}

exercise() {
    impl=$1 rt="$2 --root $scratch/state-$(basename "$2")"
    root='{"uid": 0, "gid": 0}' user='{"uid": 1000, "gid": 1000}'
    # Init confinement for root and for a non-root no_new_privs workload.
    run_confined root "$root" false
    run_confined user "$user" true
    # No profile requested: the workload stays unconfined.
    tag=aa-none-$impl
    config "$tag" "" "$root" false "$probe"
    $rt run --bundle "$scratch/$tag" "$tag" > "$scratch/$tag.out" 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag failed"; }
    # Ubuntu's runc binary runs under its own unconfined-mode "runc" profile.
    case "$(head -n 1 "$scratch/$tag.out")" in unconfined|*" (unconfined)") ;; *) cat "$scratch/$tag.out"; fail "$tag: confined" ;; esac
    [ "$(sed -n 2p "$scratch/$tag.out")" = readable ] || fail "$tag: /denied unreadable without a profile"

    # Exec inherits the container's profile unless the process file
    # requests another one.
    tag=aa-exec-$impl
    config "$tag" sct-test "$root" false '["/bin/sleep","1000"]'
    $rt create --bundle "$scratch/$tag" "$tag" < /dev/null > /dev/null 2> "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag create failed"; }
    $rt start "$tag"
    sed 's/"apparmorProfile": "sct-test"/"apparmorProfile": "sct-alt"/' "$scratch/$tag/config.json" > "$scratch/edited"
    mv "$scratch/edited" "$scratch/$tag/config.json"
    # Swift keeps the recorded container policy; runc's command exec rereads
    # the edited bundle. An explicit --process profile applies in both.
    expected="sct-test (enforce)"
    [ "$impl" = swift ] || expected="sct-alt (enforce)"
    $rt exec "$tag" /bin/sh -c 'cat /proc/self/attr/apparmor/current' > "$scratch/$tag.out"
    expect_output "$scratch/$tag.out" "$expected" "$tag command exec"
    printf '{"args":["/bin/cat","/proc/self/attr/apparmor/current"],"cwd":"/","user":%s,"apparmorProfile":"sct-alt"}' "$root" > "$scratch/alt.json"
    $rt exec --process "$scratch/alt.json" "$tag" > "$scratch/$tag.out"
    expect_output "$scratch/$tag.out" "sct-alt (enforce)" "$tag override exec"
    printf '{"args":["/bin/cat","/proc/self/attr/apparmor/current"],"cwd":"/","user":%s}' "$root" > "$scratch/plain.json"
    $rt exec --process "$scratch/plain.json" "$tag" > "$scratch/$tag.out"
    # runc 1.4 does not persist the profile in its state, so such an exec
    # runs unconfined there; Swift applies the recorded container profile.
    case "$impl" in
        swift) expect_output "$scratch/$tag.out" "sct-test (enforce)" "$tag process exec" ;;
        *) echo "runc: process exec without a profile reported: $(cat "$scratch/$tag.out")" ;;
    esac
    $rt delete --force "$tag"

    # An unknown profile fails create before the workload or state remains.
    tag=aa-missing-$impl
    config "$tag" sct-missing "$root" false '["/bin/echo","must-not-run"]'
    if $rt create --bundle "$scratch/$tag" "$tag" < /dev/null > "$scratch/$tag.out" 2> "$scratch/$tag.err"; then fail "$tag: create succeeded"; fi
    grep -qi "apparmor" "$scratch/$tag.err" || { cat "$scratch/$tag.err"; fail "$tag: error does not name AppArmor"; }
    [ ! -s "$scratch/$tag.out" ] || fail "$tag: workload ran"
    if $rt state "$tag" > /dev/null 2>&1; then fail "$tag: failed create left state"; fi
    echo "$impl: root/nonroot+nnp init, unconfined default, recorded/overridden exec profile and unknown profile passed"
}
exercise swift "$ours"
if [ -n "$theirs" ]; then exercise runc "$theirs"; fi
echo 'AppArmor integration passed.'
