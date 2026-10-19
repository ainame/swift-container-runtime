#!/usr/bin/env python3
"""Measure rootful Linux OCI /bin/true runs, retaining every sample and binary identity."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import signal
import statistics
import subprocess
import tempfile
import time


def capture(*command):
    """Retain diagnostic output even for ldd's expected static-binary exit status."""
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return result.stdout.strip()


def measure(probe, command):
    """Use a small native parent so interpreter memory cannot contaminate RSS."""
    with subprocess.Popen([str(probe), *command], text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, start_new_session=True) as child:
        try:
            output, errors = child.communicate(timeout=30)
        except BaseException:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate()
            raise
        if child.returncode:
            raise RuntimeError(f'{command} exited {child.returncode}: {errors}')
    return json.loads(output)


def main():
    """Prepare one identical bundle, interleave runtimes, then save raw evidence."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', action='append', required=True, metavar='NAME=PATH')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--warmups', type=int, default=10)
    parser.add_argument('--runs', type=int, default=20)
    parser.add_argument('--busybox', type=Path, default=Path('/bin/busybox'))
    parser.add_argument('--build-report', type=Path)
    parser.add_argument('--allow-empty-state-directory', action='append', default=[],
                        metavar='NAME=DIRECTORY',
                        help='Allow one declared empty runtime support directory after cleanup')
    args = parser.parse_args()
    if platform.system() != 'Linux' or os.geteuid() != 0:
        parser.error('Run as root on Linux with namespace and mount privileges')
    if args.runs < 1 or args.warmups < 0:
        parser.error('runs must be positive and warmups nonnegative')
    if 'INTERP' in capture('readelf', '-l', str(args.busybox)):
        parser.error('BusyBox must be statically linked')
    runtimes = {}
    for item in args.runtime:
        name, path = item.split('=', 1)
        binary = Path(shutil.which(path) or path).resolve(strict=True)
        if name in runtimes:
            parser.error(f'duplicate runtime: {name}')
        runtimes[name] = {
            'path': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'size_bytes': binary.stat().st_size, 'version': capture(str(binary), '--version'),
            'elf_header': capture('readelf', '-h', str(binary)),
            'linkage': capture('ldd', str(binary)),
            'samples': [],
        }
    allowed_directories = {name: [] for name in runtimes}
    for item in args.allow_empty_state_directory:
        name, directory = item.split('=', 1)
        if name not in runtimes or Path(directory).name != directory or directory in ('.', '..'):
            parser.error(f'invalid support directory declaration: {item}')
        allowed_directories[name].append(directory)

    # Guest-local storage avoids measuring metadata operations over macOS virtiofs.
    with tempfile.TemporaryDirectory(prefix='srunc-bench-', dir='/var/tmp') as temporary:
        scratch = Path(temporary)
        probe = scratch / 'benchmark-probe'
        subprocess.run(['clang', '-O2', '-Wall', '-Wextra', '-Werror',
                        str(Path(__file__).parent / 'fixtures/benchmark-probe.c'),
                        '-o', str(probe)], check=True)
        bundle = scratch / 'bundle'
        rootfs = bundle / 'rootfs'
        for directory in ('bin', 'proc', 'dev'):
            (rootfs / directory).mkdir(parents=True)
        shutil.copy2(args.busybox, rootfs / 'bin/busybox')
        (rootfs / 'bin/true').symlink_to('busybox')
        config = {
            'ociVersion': '1.0.2',
            'process': {'terminal': False, 'user': {'uid': 0, 'gid': 0},
                        'args': ['/bin/true'], 'env': ['PATH=/bin'], 'cwd': '/',
                        'noNewPrivileges': True},
            'root': {'path': 'rootfs', 'readonly': True}, 'hostname': 'bench',
            'mounts': [
                {'destination': '/proc', 'type': 'proc', 'source': 'proc'},
                {'destination': '/dev', 'type': 'tmpfs', 'source': 'tmpfs',
                 'options': ['nosuid', 'strictatime', 'mode=755', 'size=65536k']},
            ],
            'linux': {'namespaces': [{'type': kind} for kind in ('pid', 'mount', 'uts', 'ipc')]},
        }
        (bundle / 'config.json').write_text(json.dumps(config, indent=2))
        # Private roots and unique IDs isolate this benchmark from existing containers.
        commands = {}
        for name, runtime in runtimes.items():
            state = scratch / ('state-' + str(len(commands)))
            commands[name] = [runtime['path'], '--root', str(state), 'run', '--bundle', str(bundle)]
        generator = random.Random(0)
        for index in range(args.warmups + args.runs):
            names = list(runtimes)
            generator.shuffle(names)
            for name in names:
                identifier = f'bench-{index}'
                try:
                    sample = measure(probe, commands[name] + [identifier])
                except BaseException:
                    subprocess.run([runtimes[name]['path'], '--root', commands[name][2],
                                    'delete', '--force', identifier], stdout=subprocess.DEVNULL)
                    raise
                if index >= args.warmups:
                    sample['round'] = index - args.warmups + 1
                    runtimes[name]['samples'].append(sample)
                print(f'{name}: {index + 1}/{args.warmups + args.runs}', flush=True)
            for name, command in commands.items():
                state = Path(command[2])
                if state.exists():
                    for entry in state.iterdir():
                        if (entry.name in allowed_directories[name] and not entry.is_symlink()
                                and entry.is_dir() and not any(entry.iterdir())):
                            continue
                        raise RuntimeError(f'Runtime left unexpected container state: {entry}')

    for runtime in runtimes.values():
        samples = runtime['samples']
        runtime['median_elapsed_ms'] = statistics.median(s['elapsed_ms'] for s in samples)
        runtime['median_max_rss_kib'] = statistics.median(s['max_rss_kib'] for s in samples)
    report = {
        'schema_version': 1, 'recorded_at_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'source_commit': capture('git', 'rev-parse', 'HEAD'),
        'source_dirty': bool(capture('git', 'status', '--porcelain')),
        'host': {'uname': platform.uname()._asdict(), 'cpu': capture('lscpu'),
                 'memory': capture('free', '-b'), 'os_release': Path('/etc/os-release').read_text()},
        'method': {'warmups': args.warmups, 'runs': args.runs, 'order_seed': 0,
                   'timing': 'native probe CLOCK_MONOTONIC fork through wait4; foreground OCI run including cleanup',
                   'rss': 'wait4 ru_maxrss (KiB); largest process high-water mark, not aggregate',
                   'storage': 'guest /var/tmp; warm caches; runtime order shuffled per round'},
        'allowed_empty_state_directories': allowed_directories,
        'bundle_config': config,
        'busybox_sha256': hashlib.sha256(args.busybox.read_bytes()).hexdigest(),
        'runtimes': runtimes,
    }
    if args.build_report:
        report['build'] = json.loads(args.build_report.read_text())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    for name, runtime in runtimes.items():
        print(f"{name}: {runtime['median_elapsed_ms']:.3f} ms, "
              f"{runtime['median_max_rss_kib'] / 1024:.3f} MiB RSS, "
              f"{runtime['size_bytes'] / 1_000_000:.3f} MB binary")


if __name__ == '__main__':
    main()
