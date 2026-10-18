#!/bin/sh
# spec, features, and version checks. Run inside a disposable Linux VM or
# container; root is needed only to also generate specs as an unprivileged user.
# RUNC_COMPARE=auto (default) compares generated specs with runc spec when runc
# is installed; 1 requires runc; 0 skips the comparison.
set -eu
runtime=${1:-.build/debug/srunc}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
compare=${RUNC_COMPARE:-auto}
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
chmod 755 "$scratch"
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

fail() { echo "metadata: $*" >&2; exit 1; }
case "$compare" in
auto) if command -v runc >/dev/null 2>&1; then compare=1; else compare=0; fi ;;
1) command -v runc >/dev/null || fail "RUNC_COMPARE=1 but runc is not installed" ;;
esac

# A JSON canonicalizer: sorted keys, compact, minus the fields expected to differ
# (ociVersion tracks each runtime's vendored spec; hostname is runtime-branded).
cat > "$scratch/canon.swift" <<'EOF'
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2, let data = FileManager.default.contents(atPath: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: canon <file.json>\n".utf8))
    exit(2)
}
do {
    var object = try JSONSerialization.jsonObject(with: data)
    if var dictionary = object as? [String: Any] {
        dictionary["ociVersion"] = nil
        dictionary["hostname"] = nil
        object = dictionary
    }
    let output = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(output + Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("invalid JSON in \(arguments[1]): \(error)\n".utf8))
    exit(1)
}
EOF
swiftc -strict-memory-safety -warnings-as-errors "$scratch/canon.swift" -o "$scratch/canon"
canon() { "$scratch/canon" "$1"; }

# --- help and version ---------------------------------------------------------
help=$("$runtime" --help)
for command in spec features; do
    printf '%s\n' "$help" | grep -q "^ *$command " || fail "--help does not list $command"
done
version=$("$runtime" --version)
printf '%s\n' "$version" | head -n 1 | grep -q '^srunc version ..*' \
    || fail "unexpected --version output: $version"
printf '%s\n' "$version" | tail -n 1 | grep -q '^spec: 1\.[0-9][0-9]*\.[0-9][0-9]*$' \
    || fail "--version lacks the spec line: $version"
test "$("$runtime" -v)" = "$version" || fail "-v and --version differ"
"$runtime" spec --help | grep -q -- '--rootless' || fail "spec --help lacks --rootless"

# --- features -------------------------------------------------------------------
"$runtime" features > "$scratch/features.json"
canon "$scratch/features.json" > "$scratch/features.canon" || fail "features is not valid JSON"
for expected in '"ociVersionMin":"1.0.0"' '"hooks":["prestart","createRuntime","createContainer","startContainer","poststart","poststop"]' '"v2":true' '"v1":false' '"systemd":false' \
    '"seccomp":{"enabled":true}' '"idmap":{"enabled":false}' '"apparmor":{"enabled":true}' '"selinux":{"enabled":true}' '"CAP_CHOWN"' '"pid"' '"network","cgroup","user"]'; do
    grep -qF "$expected" "$scratch/features.canon" || fail "features lacks $expected"
done
for unexpected in '"annotations"' '"potentiallyUnsafeConfigAnnotations"' '"user"'; do
    if grep -qF "$unexpected" "$scratch/features.canon"; then fail "features claims $unexpected"; fi
done

# --- spec: generated fields match runc -------------------------------------------
# as_user USER CMD...: run as root or, for "1000", as an unprivileged user.
as_user() {
    who=$1; shift
    if test "$who" = root; then "$@"; else
        setpriv --reuid "$who" --regid "$who" --clear-groups "$@"
    fi
}
users=root
if test "$(id -u)" = 0; then
    command -v setpriv >/dev/null || fail "setpriv (util-linux) is required"
    users="root 1000"
fi
for who in $users; do
    for flags in "" --rootless; do
        label="$who${flags:+ $flags}"
        ours=$scratch/ours-$who$flags
        mkdir "$ours"
        test "$who" = root || chown "$who:$who" "$ours"
        # shellcheck disable=SC2086 # flags is empty or one word
        as_user "$who" "$runtime" spec -b "$ours" $flags || fail "spec failed ($label)"
        canon "$ours/config.json" > "$ours.canon" || fail "spec wrote invalid JSON ($label)"
        if test "$flags" = --rootless; then
            grep -qF "\"hostID\":$(as_user "$who" id -u)," "$ours.canon" || fail "rootless uid map is not the caller ($label)"
        fi
        if test "$compare" = 1; then
            theirs=$scratch/runc-$who$flags
            mkdir "$theirs"
            test "$who" = root || chown "$who:$who" "$theirs"
            # shellcheck disable=SC2086
            as_user "$who" runc spec -b "$theirs" $flags || fail "runc spec failed ($label)"
            canon "$theirs/config.json" > "$theirs.canon"
            diff -u "$theirs.canon" "$ours.canon" || fail "spec differs from runc ($label)"
            test "$(stat -c %a "$ours/config.json")" = "$(stat -c %a "$theirs/config.json")" \
                || fail "config.json mode differs from runc ($label)"
        fi
    done
done

# --- spec: bundle resolution and working directory ----------------------------------
mkdir "$scratch/cwd" "$scratch/cwd-empty" "$scratch/target"
(cd "$scratch/cwd" && "$runtime" spec) || fail "spec without --bundle failed"
test -f "$scratch/cwd/config.json" || fail "spec without --bundle did not write to the working directory"
(cd "$scratch/cwd-empty" && "$runtime" spec -b "") || fail "spec -b '' failed"
test -f "$scratch/cwd-empty/config.json" || fail "spec -b '' did not write to the working directory"
(cd "$scratch/target" && "$runtime" spec -b ../cwd/../target) || fail "relative --bundle failed"
test -f "$scratch/target/config.json" || fail "relative --bundle wrote elsewhere"

# Missing bundles fail for both runtimes and create nothing.
if "$runtime" spec -b "$scratch/absent" 2>/dev/null; then fail "spec accepted a missing bundle"; fi
test ! -e "$scratch/absent" || fail "spec created a missing bundle"
if test "$compare" = 1 && runc spec -b "$scratch/absent" 2>/dev/null; then
    fail "runc accepted a missing bundle; comparison assumptions are stale"
fi

# --- spec: never overwrite -------------------------------------------------------------
# refuse NAME TOOL...: the tool must fail in a bundle whose config.json already exists.
refuse() {
    name=$1; shift
    if "$@" 2>"$scratch/refuse.err"; then fail "$name: overwrote an existing config.json"; fi
    grep -q 'exists' "$scratch/refuse.err" || fail "$name: unexpected error: $(cat "$scratch/refuse.err")"
}
tools="ours"
test "$compare" = 1 && tools="ours runc"
for tool in $tools; do
    if test "$tool" = ours; then run_spec() { "$runtime" spec -b "$1"; }; else run_spec() { runc spec -b "$1"; }; fi
    base=$scratch/exist-$tool
    mkdir -p "$base/file" "$base/dir/config.json" "$base/link" "$base/dangling"
    echo keep > "$base/file/config.json"
    echo keep > "$base/link/target"
    ln -s target "$base/link/config.json"

    refuse "$tool regular file" run_spec "$base/file"
    test "$(cat "$base/file/config.json")" = keep || fail "$tool changed an existing file"
    refuse "$tool directory" run_spec "$base/dir"
    { test -d "$base/dir/config.json" && test -z "$(ls -A "$base/dir/config.json")"; } || fail "$tool changed a directory"
    refuse "$tool symlink" run_spec "$base/link"
    { test "$(readlink "$base/link/config.json")" = target && test "$(cat "$base/link/target")" = keep; } \
        || fail "$tool changed a symlink or its target"
done

# runc stats config.json and so writes through a dangling symlink; this runtime
# creates exclusively and refuses it, which is the intended divergence.
mkdir "$scratch/dangling"
ln -s missing "$scratch/dangling/config.json"
refuse "ours dangling symlink" "$runtime" spec -b "$scratch/dangling"
test ! -e "$scratch/dangling/missing" || fail "spec wrote through a dangling symlink"
test "$(readlink "$scratch/dangling/config.json")" = missing || fail "spec replaced a dangling symlink"

echo "metadata integration passed"
