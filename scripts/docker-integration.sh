#!/bin/sh
# Opt-in Docker acceptance gate (docs/docker-integration.md gates 3 and 4) on a
# disposable rootful host with the cgroupfs driver. RUNTIME names a registered
# Docker runtime; run it once with runc to validate the gate itself.
# Usage: sudo sh scripts/docker-integration.sh RUNTIME IMAGE@sha256:DIGEST
# The image must provide BusyBox applets (Alpine does) and be pulled already.
set -eu
[ "$#" -eq 2 ] || { echo "Usage: $0 RUNTIME IMAGE@sha256:DIGEST" >&2; exit 2; }
runtime=$1 image=$2
case "$image" in *@sha256:*) ;; *) echo 'Use a pinned image digest' >&2; exit 2 ;; esac
command -v script > /dev/null || { echo 'script(1) from util-linux is required' >&2; exit 2; }
command -v busybox > /dev/null || { echo 'BusyBox (host-side nc) is required' >&2; exit 2; }
prefix=sct-docker-$$
state_root=/run/docker/runtime-runc/moby
scratch=$(mktemp -d)
cleanup() {
    docker ps -aq --filter "name=$prefix" | xargs -r docker rm -f > /dev/null 2>&1 || :
    docker volume rm "$prefix-volume" > /dev/null 2>&1 || :
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { echo "docker-integration ($runtime): $*" >&2; exit 1; }
run() { docker run --runtime "$runtime" "$@"; }
pass() { echo "$runtime: $*"; }
# expect_equal ACTUAL EXPECTED WHAT
expect_equal() { [ "$1" = "$2" ] || fail "$3: got '$1', expected '$2'"; }

docker version --format 'docker {{.Server.Version}}, containerd {{range .Server.Components}}{{if eq .Name "containerd"}}{{.Version}}{{end}}{{end}}'
expect_equal "$(docker info --format '{{.CgroupDriver}}')" cgroupfs 'cgroup driver'

# Provenance: the container was created by the named runtime. Docker passes
# --root /run/docker/runtime-runc/moby to every runtime; only the Swift
# runtime writes a "format" field in its state.
run -d --name "$prefix-provenance" "$image" sleep 1000 > /dev/null
id=$(docker inspect --format '{{.Id}}' "$prefix-provenance")
expect_equal "$(docker inspect --format '{{.HostConfig.Runtime}}' "$id")" "$runtime" 'recorded runtime'
[ -f "$state_root/$id/state.json" ] || fail 'runtime state is missing'
if [ "$runtime" = runc ]; then
    if grep -q '"format"' "$state_root/$id/state.json"; then fail 'runc state has the Swift format'; fi
else
    grep -q '"format"' "$state_root/$id/state.json" || fail 'state was not written by the Swift runtime'
fi
docker rm -f "$prefix-provenance" > /dev/null
[ ! -e "$state_root/$id" ] || fail 'removed container left runtime state'
pass 'provenance and state cleanup'

# Nonterminal workloads, exit status, logs and a failing executable.
set +e
run --rm "$image" sh -c 'echo out; echo err >&2; exit 7' > "$scratch/out" 2> "$scratch/err"
status=$?
run --rm "$image" /no/such/program > /dev/null 2> "$scratch/missing"
missing=$?
set -e
expect_equal "$status" 7 'exit status'
expect_equal "$(cat "$scratch/out")" out 'stdout'
grep -qx err "$scratch/err" || fail 'stderr was not forwarded'
expect_equal "$missing" 127 'missing executable status'
pass 'stdout/stderr, exit 7 and missing executable 127'

# Default security: AppArmor, seccomp, capabilities and device rules.
run --rm "$image" sh -c 'cat /proc/self/attr/apparmor/current; grep ^Seccomp: /proc/self/status; grep ^CapEff: /proc/self/status
mknod /tmp/mem c 1 1 && (head -c1 /tmp/mem > /dev/null 2>&1 && echo mem=readable || echo mem=denied)' > "$scratch/security"
grep -qx 'docker-default (enforce)' "$scratch/security" || { cat "$scratch/security"; fail 'docker-default AppArmor profile missing'; }
grep -Eq '^Seccomp:[[:space:]]+2$' "$scratch/security" || fail 'seccomp filter missing'
grep -Eq '^CapEff:[[:space:]]+00000000a80425fb$' "$scratch/security" || { cat "$scratch/security"; fail 'default capabilities differ'; }
grep -qx 'mem=denied' "$scratch/security" || fail 'device rules did not deny /dev/mem'
pass 'docker-default AppArmor, seccomp mode 2, default capabilities and device denial'

# Bridge networking, DNS configuration, published ports and container-to-container TCP.
run -d --name "$prefix-server" -p 127.0.0.1:18080:8080 "$image" sh -c 'while :; do echo served | nc -l -p 8080; done' > /dev/null
server_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$prefix-server")
[ -n "$server_ip" ] || fail 'no bridge address'
for _ in $(seq 50); do reply=$(timeout 3 busybox nc 127.0.0.1 18080 < /dev/null 2>/dev/null || :); [ -z "$reply" ] || break; sleep 0.2; done
expect_equal "$reply" served 'published port reply'
expect_equal "$(run --rm "$image" sh -c "nc -w 3 $server_ip 8080")" served 'container-to-container reply'
run --rm "$image" sh -c 'grep -q ^nameserver /etc/resolv.conf && echo dns; ip -4 addr show eth0 | grep -q inet && echo eth0; cat /proc/sys/net/ipv4/ip_unprivileged_port_start' > "$scratch/net"
expect_equal "$(cat "$scratch/net")" "dns
eth0
0" 'network view'
docker rm -f "$prefix-server" > /dev/null
pass 'bridge address, resolv.conf, published port, container TCP and network sysctl'

# Volumes, read-only root and a non-root user with reduced privileges.
mkdir "$scratch/bind" && chmod 777 "$scratch/bind"
docker volume create "$prefix-volume" > /dev/null
run --rm --read-only --tmpfs /tmp -v "$scratch/bind:/bind" -v "$prefix-volume:/named" "$image" \
    sh -c 'echo bound > /bind/file; echo named > /named/file; touch /root-file 2>/dev/null && echo root=writable || echo root=readonly; touch /tmp/ok && echo tmp=writable' > "$scratch/volumes"
expect_equal "$(cat "$scratch/volumes")" "root=readonly
tmp=writable" 'read-only root view'
expect_equal "$(cat "$scratch/bind/file")" bound 'bind volume write'
expect_equal "$(run --rm -v "$prefix-volume:/named" "$image" cat /named/file)" named 'named volume persistence'
run --rm --user 1000:1000 --cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges "$image" \
    sh -c 'id -u; grep ^CapEff: /proc/self/status; grep ^NoNewPrivs: /proc/self/status' > "$scratch/user"
grep -qx 1000 "$scratch/user" || fail 'user was not applied'
grep -Eq '^CapEff:[[:space:]]+0000000000000000$' "$scratch/user" || { cat "$scratch/user"; fail 'non-root effective capabilities differ'; }
grep -Eq '^NoNewPrivs:[[:space:]]+1$' "$scratch/user" || fail 'no-new-privileges missing'
pass 'bind and named volumes, read-only root with tmpfs, non-root user, capability drop and no-new-privileges'

# Resource limits, live update, pause/unpause, stats and exec.
run -d --name "$prefix-limits" --memory 64m --cpus 0.5 --pids-limit 50 "$image" sleep 1000 > /dev/null
expect_equal "$(docker exec "$prefix-limits" cat /sys/fs/cgroup/memory.max)" 67108864 'memory limit'
expect_equal "$(docker exec "$prefix-limits" cat /sys/fs/cgroup/cpu.max)" '50000 100000' 'CPU limit'
expect_equal "$(docker exec "$prefix-limits" cat /sys/fs/cgroup/pids.max)" 50 'pids limit'
docker update --memory 128m --memory-swap 256m --pids-limit 60 "$prefix-limits" > /dev/null
expect_equal "$(docker exec "$prefix-limits" cat /sys/fs/cgroup/memory.max)" 134217728 'updated memory limit'
expect_equal "$(docker exec "$prefix-limits" cat /sys/fs/cgroup/pids.max)" 60 'updated pids limit'
docker pause "$prefix-limits" > /dev/null
expect_equal "$(docker inspect --format '{{.State.Status}}' "$prefix-limits")" paused 'paused state'
docker unpause "$prefix-limits" > /dev/null
docker stats --no-stream --format '{{.MemUsage}}' "$prefix-limits" | grep -q 'MiB' || fail 'stats unavailable'
set +e
docker exec "$prefix-limits" sh -c 'exit 5'
status=$?
set -e
expect_equal "$status" 5 'exec status'
docker exec -d "$prefix-limits" sleep 1000
pass 'memory/CPU/pids limits, update, pause/unpause, stats, exec status and detached exec'

# Terminals through the shim, with the caller's size.
set +e
script -qec "stty rows 30 cols 100; docker run --runtime $runtime --rm -it $image sh -c 'sleep 0.5; stty size; [ -t 0 ] && echo tty; exit 3'" "$scratch/tty" < /dev/null > /dev/null
status=$?
script -qec "stty rows 40 cols 120; docker exec -it $prefix-limits sh -c 'sleep 0.5; stty size; exit 4'" "$scratch/exec-tty" < /dev/null > /dev/null
exec_status=$?
set -e
expect_equal "$status" 3 'run -it status'
expect_equal "$exec_status" 4 'exec -it status'
# The terminal echoes a NUL as ^@ before the output, with runc too.
tr -d '\r' < "$scratch/tty" | sed 's/^\^@//' | grep -qx '30 100' || { cat "$scratch/tty"; fail 'run -it size'; }
tr -d '\r' < "$scratch/exec-tty" | sed 's/^\^@//' | grep -qx '40 120' || { cat "$scratch/exec-tty"; fail 'exec -it size'; }
pass 'run -it and exec -it terminals with resize and exit status'

# Stop timeout for a TERM-ignoring init, forced removal with descendants.
run -d --name "$prefix-stubborn" "$image" sh -c 'trap "" TERM; sleep 1000 & sleep 1000 & wait' > /dev/null
started=$(date +%s)
docker stop -t 2 "$prefix-stubborn" > /dev/null
elapsed=$(($(date +%s) - started))
[ "$elapsed" -ge 2 ] && [ "$elapsed" -le 10 ] || fail "stop took ${elapsed}s"
expect_equal "$(docker inspect --format '{{.State.ExitCode}}' "$prefix-stubborn")" 137 'killed exit code'
docker rm "$prefix-stubborn" > /dev/null
docker rm -f "$prefix-limits" > /dev/null
pgrep -f "^sleep 1000$" > /dev/null && fail 'workload processes leaked'
[ -z "$(ls "$state_root" 2>/dev/null)" ] || fail 'runtime state leaked'
pass 'stop timeout with SIGKILL, forced removal with descendants and no leaked state'
echo "docker-integration: PASS ($runtime)"
