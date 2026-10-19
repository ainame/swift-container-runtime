# Runtime benchmarks

The initial baseline measures a foreground OCI `/bin/true` container, including
runtime startup, namespace/rootfs setup, workload execution, wait and state
cleanup. It is a small launch benchmark, not a Docker or application throughput
benchmark.

## 2026-10-19 ARM64 baseline

Apple `container` machine `srunc-dev`: 5 vCPUs, 32 GiB configured RAM, Ubuntu
26.04.1, Linux 6.12.28, aarch64. srunc source: `7e63ab9`; Swift 6.4.1,
release optimization, static Swift standard library, stripped executable.
Only benchmark scripts/documentation were uncommitted during measurement.

Each runtime gets 10 warmups followed by 20 measured runs. Runtime order is
shuffled per round with a recorded seed; all use the same static BusyBox and
OCI bundle on the guest's local `/var/tmp` filesystem. Each invocation must
exit successfully and leave its private state root empty.

| Runtime | Median run (ms) | Median peak process RSS (MiB) | Binary size (MB) |
| --- | ---: | ---: | ---: |
| srunc `7e63ab9` | 7.795 | 17.648 | 59.494 |
| Ubuntu runc 1.4.0-0ubuntu1 | 6.124 | 11.840 | 10.925 |
| Upstream runc 1.5.2 | 6.286 | 10.188 | 10.092 |

srunc took approximately 24% longer than runc 1.5.2 on this workload. Its
stripped binary is substantially larger. These measurements establish a
baseline for future profiling; they do not identify which setup step or linked
component accounts for the differences.

A single clean srunc release compilation/link took **26.16 seconds**, after
dependency resolution and with warm filesystem caches. This is an observation,
not a 20-build median or a cross-language build-time comparison. The scratch
directory had resolved dependencies but no previous build products.

[Raw measurements](benchmarks/2026-10-19-arm64.json) retain all 60 measured
samples, executable hashes/versions/linkage, environment, bundle configuration
and build command/timing. MB means decimal megabytes; MiB means 1,048,576 bytes.

### Relationship to the kontainer presentation

The supplied slides use 10 warmups, 20 measurements and medians, with static
x86-64 executables on a 4-vCPU AMD VM. Our bundle follows the minimal
`bench/run/bundles/minimal/config.json` workload in the local kontainer-runtime
checkout at `357b8f295a7fad450c822c61e79cf22f75546640`: `/bin/true`, a read-only
BusyBox rootfs, proc/dev mounts and PID/mount/UTS/IPC namespaces. We use the
installed ARM64 static BusyBox rather than its x86-64 rootfs download. The
slides do not establish which bundle produced their charts, so this does not
reproduce their exact experiment.

Other limits:

- srunc statically links the Swift runtime but still dynamically links libc,
  libseccomp, libm, libstdc++ and libgcc. Ubuntu runc dynamically links libc and
  libseccomp; the upstream runc 1.5.2 executable is static. Binary sizes exclude
  shared libraries. A fully static comparison remains future work.
- Peak RSS uses Linux `wait4().ru_maxrss`: the largest individual process
  high-water mark reported through waited descendants, not a sum of concurrent
  runtime/container memory. A small native parent avoids imposing Python's
  interpreter RSS on the child. The timing interval starts in that native
  parent immediately before fork and ends after wait4.
- Warm caches, a shared development VM, no CPU affinity/frequency isolation,
  one short sampling session. Small differences need more controlled follow-up.
- Kontainer, youki and crun were not measured. No runtime tuning was applied.

## Reproduce

Run on a rootful Linux VM with namespace/mount privileges. Requirements: Swift
6.4.1, libseccomp development headers, static BusyBox, Python 3, clang, binutils
(`readelf`/`strip`), `ldd`, `lscpu`, `free`, git and the comparison binaries.
No new Swift package dependencies are needed.

Build outside the sampling interval. For a clean build timing, choose a new
guest-local scratch directory, resolve dependencies first, then time only the
build command. Do not reuse a populated build directory as a clean build.

```sh
swift package resolve --scratch-path /var/tmp/srunc-benchmark-build
swift build -c release --product srunc --static-swift-stdlib \
  --disable-automatic-resolution --scratch-path /var/tmp/srunc-benchmark-build
mkdir -p /var/tmp/srunc-benchmark-bin
cp /var/tmp/srunc-benchmark-build/release/srunc /var/tmp/srunc-benchmark-bin/srunc
strip /var/tmp/srunc-benchmark-bin/srunc
sudo python3 scripts/benchmark-runtime.py \
  --runtime srunc=/var/tmp/srunc-benchmark-bin/srunc \
  --runtime runc=/usr/sbin/runc \
  --output .build/benchmarks/results.json
```

Add more `--runtime NAME=/absolute/path` arguments for other installed runtimes.
They must accept the runc-compatible `--root PATH run --bundle PATH ID` command
and the same bundle. Binary preparation/stripping and build/link options are the
caller's responsibility; the runner records exactly the executables supplied.
`--warmups` and `--runs` override the defaults. `--build-report PATH` optionally
embeds a separately collected JSON build report without timing it again.

On macOS, invoke the runner inside `srunc-dev`; VM startup and the macOS
`container machine run` client stay outside the measured interval:

```sh
container machine run -n srunc-dev --root -- \
  python3 scripts/benchmark-runtime.py \
  --runtime srunc=/var/tmp/srunc-benchmark-bin/srunc \
  --runtime runc=/usr/sbin/runc \
  --output .build/benchmarks/results.json
```
