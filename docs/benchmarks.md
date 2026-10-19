# Runtime benchmarks

The initial baseline measures a foreground OCI `/bin/true` container, including
runtime startup, namespace/rootfs setup, workload execution, wait and state
cleanup. It is a small launch benchmark, not a Docker or application throughput
benchmark.

## Current comparison: srunc, kontainer, runc, crun and youki

Measured on 2026-10-19 using the same ARM64 `srunc-dev` VM (5 vCPUs, 32 GiB,
Ubuntu 26.04.1, Linux 6.12.28), static BusyBox `/bin/true` bundle, native probe,
10 warmups and 20 measured runs per runtime. All six executables were
interleaved in one session, with no builds running.

| Runtime | Median run (ms) | Median peak process RSS (MiB) | Binary size (MB) |
| --- | ---: | ---: | ---: |
| srunc `d75ffd3` (FoundationEssentials) | 7.438 | 12.742 | 15.483 |
| kontainer-runtime 0.6.1 | 3.483 | 5.043 | 4.107 |
| Ubuntu runc 1.4.0-0ubuntu1 | 6.306 | 11.955 | 10.925 |
| Upstream runc 1.5.2 | 6.565 | 10.188 | 10.092 |
| crun 1.30.1 | 1.652 | 2.168 | 3.364 |
| youki 0.7.0 | 5.663 | 4.129 | 6.812 |

[Raw samples, versions, linkage and hashes](benchmarks/2026-10-19-arm64-all.json)
retain all 120 measurements. The srunc executable uses Swift 6.4.1 release
optimization, static Swift libraries, FoundationEssentials, and `strip`; it
still dynamically links the system libraries listed in the report. The
Ubuntu runc package also uses shared libraries. Kontainer, upstream runc,
crun and youki are fully static. Sizes exclude shared dependencies; this is
still not a uniformly fully static comparison.

The additional binaries are upstream release artifacts, with downloaded file
SHA-256 verified against GitHub's asset digests (also retained in the report):

- [crun 1.30.1 ARM64](https://github.com/containers/crun/releases/tag/1.30.1),
  standard `crun-1.30.1-linux-arm64` asset with systemd support enabled.
- [youki 0.7.0 ARM64 musl](https://github.com/youki-dev/youki/releases/tag/v0.7.0),
  `youki-0.7.0-aarch64-musl.tar.gz`; the table measures its extracted executable,
  not the compressed archive.

Use the reproduction command below with these additional arguments to include
both installed executables:

```sh
--runtime crun=/path/to/crun-1.30.1-linux-arm64 \
--runtime youki=/path/to/extracted/youki \
--allow-empty-state-directory crun=.empty-directory
```

crun leaves an empty `.empty-directory` support directory in its private state
root. As with kontainer's `.exeseal` below, the allowance permits only that
explicitly declared empty directory; container state must still be removed.

## Historical four-runtime comparison, including kontainer

Rerun on the same ARM64 VM after all build experiments finished, using 10
warmups and 20 measured runs per runtime with the same bundle and native probe:

| Runtime | Median run (ms) | Median peak process RSS (MiB) | Binary size (MB) |
| --- | ---: | ---: | ---: |
| srunc `7e63ab9` | 7.657 | 17.652 | 59.494 |
| kontainer-runtime 0.6.1 | 3.408 | 5.027 | 4.107 |
| Ubuntu runc 1.4.0-0ubuntu1 | 6.194 | 11.814 | 10.925 |
| Upstream runc 1.5.2 | 6.341 | 10.188 | 10.092 |

The srunc executable is byte-identical to the original baseline. The runner's
source commit is `1088476`; the runtime source is still `7e63ab9`.
[Raw samples and binary identities](benchmarks/2026-10-19-arm64-kontainer.json)
retain all 80 measurements. No build was running during this sampling session.

Kontainer is the upstream [0.6.1 ARM64 release asset](https://github.com/ternbusty/kontainer-runtime/releases/tag/v0.6.1),
commit `1cddebadcdce181626749241c7ef0ab13d97d40a`, fully static and stripped.
Its SHA-256 matches GitHub's asset digest:
`77e936f076a079a8a7052ba2e812d0e9acd4caa261962c3edd8bfe75396e6850`.
The tag's `gradle.properties` sets `kotlin.native.binary.pagedAllocator=false`,
so this includes the allocator tuning described in the supplied slides.

Kontainer leaves an empty `.exeseal` directory under its state root for its
executable-sealing overlayfs lowerdir. The runner now allows explicitly named,
empty support directories; any nonempty, symlinked or undeclared entry still
fails cleanup verification. This directory persists through warmups and samples
and is removed with the benchmark's private temporary root afterwards.

To include the downloaded binary in a run, add:

```sh
--runtime kontainer-runtime=/path/to/kontainer-runtime_0.6.1_linux_arm64 \
--allow-empty-state-directory kontainer-runtime=.exeseal
```

## Why srunc's binary is large

ELF/symbol inspection of the original binary identifies **33,976,096 bytes
(33.98 MB)** in the single ICU data symbol `icudt76_dat`: approximately **57% of
the entire stripped executable**. Its `.rodata` section totals 37.20 MB, and
`.text` totals 15.29 MB. These are embedded bytes, not peak resident memory.

At the baseline revision, two files unconditionally imported full Foundation:
`Sources/RuntimeCLI/RuntimeLog.swift` and
`Sources/ContainerRuntime/Lifecycle/ContainerLifecycle.swift`. In this static
Swift build, their Foundation dependency brings in internationalization/ICU
and other Foundation code. Most other files already prefer FoundationEssentials
where available.

A controlled experiment in a separate guest-local source copy changed only
those two imports to `FoundationEssentials`, then rebuilt with the same release
and static-Swift settings and stripped the executable. Size fell from
**59,494,168 to 15,483,000 bytes**, a **44.01 MB / 74% reduction**. No tracked
runtime sources were changed. This establishes a removable Foundation dependency
cost; it is not a claim that all remaining size belongs to our runtime code.
The remainder still includes the Swift standard library, FoundationEssentials,
ArgumentParser, swift-system, metadata and unwind information.

The experiment initially passed compilation only. The two runtime imports now
use the existing `canImport(FoundationEssentials)` conditional, preserving a
Foundation fallback where needed. With that change, macOS and Linux debug unit
tests and Linux debug logging, OCI and lifecycle integrations passed. The
release/static-Swift build again measured **15,483,000 bytes after stripping**;
symbol inspection confirmed that `icudt76_dat` and full Foundation Swift symbols
are absent. The current comparison above measures startup and RSS after this
change; the historical tables retain the original executable's measurements.

[Size evidence and exact experimental import changes](benchmarks/2026-10-19-binary-size.json)
record the two binary hashes and section sizes. Debug information is not the
explanation for the reported 59.49 MB: the original unstripped binary is larger,
and all benchmarked srunc sizes were measured after `strip`.

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
- This original session did not measure kontainer, youki or crun. The later
  four-runtime session above adds kontainer. No srunc tuning was applied.

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
