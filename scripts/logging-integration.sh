#!/bin/sh
# Consumer-facing diagnostics; no privileged kernel operations are needed.
set -eu
runtime=${1:-.build/debug/swift-container-runtime}
case "$runtime" in /*) ;; *) runtime="$PWD/$runtime" ;; esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
fail() { echo "logging: $*" >&2; exit 1; }

cat > "$scratch/check.swift" <<'SWIFT'
import Foundation
struct Record: Decodable { let level: String; let msg: String; let time: Date }
let arguments = CommandLine.arguments
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let lines = try String(contentsOfFile: arguments[1], encoding: .utf8).split(separator: "\n")
let records = try lines.map { try decoder.decode(Record.self, from: Data($0.utf8)) }
guard let last = records.last(where: { $0.level == "error" }),
      last.msg.contains(arguments[2]), records.count == Int(arguments[3]) else {
    fatalError("missing last error or unexpected record count")
}
SWIFT
swiftc -strict-memory-safety -warnings-as-errors "$scratch/check.swift" -o "$scratch/check"

# Replay go-runc's global prefix. Missing state/bundle fails before launching,
# leaving stdout empty and no container state, while errors append to one log.
log=$scratch/log.json
root=$scratch/state
mkdir "$scratch/missing"
expect_failure() {
    expected=$1
    shift
    set +e
    "$runtime" --root "$root" --log "$log" --log-format json "$@" > "$scratch/out" 2> "$scratch/err"
    status=$?
    set -e
    [ "$status" -eq "$expected" ] || fail "unexpected status $status for $*"
    [ ! -s "$scratch/out" ] || fail "diagnostics contaminated stdout"
    [ -s "$scratch/err" ] || fail "missing stderr diagnosis"
}
expect_failure 1 create --bundle "$scratch/missing" --pid-file "$scratch/init.pid" box
"$scratch/check" "$log" "config.json" 1
[ ! -e "$scratch/init.pid" ] || fail "failed create published a PID"
expect_failure 1 start box
"$scratch/check" "$log" "does not exist" 2
expect_failure 1 exec --process "$scratch/missing-process.json" --detach --pid-file "$scratch/exec.pid" box
"$scratch/check" "$log" "does not exist" 3
[ ! -e "$scratch/exec.pid" ] || fail "failed exec published a PID"

# Rejected command flags still reach the shim's log reader.
expect_failure 64 kill --unsupported box KILL
"$scratch/check" "$log" "--unsupported" 4
expect_failure 125 run --bundle "$scratch/missing" box
"$scratch/check" "$log" "config.json" 5

# Debug diagnostics go to the log; command JSON stays independently decodable.
"$runtime" --log "$log" --log-format json --debug features > "$scratch/features.json"
"$scratch/check" "$log" "config.json" 6
[ -s "$scratch/features.json" ] || fail "missing features output"
"$runtime" --log "$log" --log-format json --version > "$scratch/version"
grep -q '^swift-container-runtime version ' "$scratch/version" || fail "version format"

# Open failure must prevent spec from writing its output.
mkdir "$scratch/bundle"
if "$runtime" --log "$scratch/no-directory/log" spec --bundle "$scratch/bundle" > "$scratch/out" 2> "$scratch/err"; then
    fail "unwritable log accepted"
fi
[ ! -e "$scratch/bundle/config.json" ] || fail "command ran after log open failure"
grep -q 'cannot open log file' "$scratch/err" || fail "missing log open diagnosis"

# Plain diagnostics keep the existing stderr contract; text logging escapes newlines.
if "$runtime" --root "$root" start box > "$scratch/out" 2> "$scratch/err"; then fail "missing state accepted"; fi
grep -q '^swift-container-runtime: container box does not exist' "$scratch/err" || fail "plain stderr changed"
if "$runtime" --root "$root" --log "$scratch/log.txt" start box 2>/dev/null; then fail "missing state accepted"; fi
grep -q 'level=error msg="container box does not exist"' "$scratch/log.txt" || fail "text log missing"
# A newly opened log must never stand in for a missing preserved caller FD.
set +e
"$runtime" --log "$scratch/fd.json" --log-format json create --preserve-fds 1 --bundle "$scratch/missing" box 3>&- > "$scratch/out" 2> "$scratch/err"
status=$?
set -e
[ "$status" -eq 1 ] || fail "missing preserved descriptor accepted"
"$scratch/check" "$scratch/fd.json" "descriptor 3 is not open" 1
echo "logging: PASS"
