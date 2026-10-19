#!/usr/bin/env python3
"""Exercise exec races and slow attached readers against an existing test task.

The calling containerd gate owns the task, namespace and final shim cleanup.
Only the backpressure probe captures pipes: ordinary commands use regular files
so an inherited writer cannot hide command completion behind a missing EOF.
"""

import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time


class Probe:
    """Own ctr clients separately from the shim-owned container workloads."""

    def __init__(self, args, scratch, files):
        self.command = ['ctr', '--address', args.socket, '--namespace', args.namespace,
                        'tasks', 'exec']
        self.container = args.container
        self.bundle = args.bundle
        self.immediate_exit = args.immediate_exit
        self.scratch = scratch
        self.files = files
        self.clients = []

    def start(self, identifier, arguments, *, detached=False, pipes=False):
        """Keep each invocation's diagnostics private, including failed execs."""
        command = self.command + ['--exec-id', identifier]
        if detached:
            command.append('--detach')
        command += [self.container] + arguments
        output = subprocess.PIPE if pipes else self.files.enter_context(
            (self.scratch / (identifier + '.out')).open('wb'))
        errors = subprocess.PIPE if pipes else self.files.enter_context(
            (self.scratch / (identifier + '.err')).open('wb'))
        input_stream = subprocess.PIPE if pipes else subprocess.DEVNULL
        client = subprocess.Popen(command, stdin=input_stream, stdout=output,
                                  stderr=errors, start_new_session=True)
        self.clients.append(client)
        return client

    def expect(self, client, identifier, status):
        """Wait for the CLI, not EOF on descriptors a workload could inherit."""
        actual = client.wait(timeout=20)
        errors = (self.scratch / (identifier + '.err')).read_text(errors='replace')
        if (status is None and actual == 0) or (status is not None and actual != status):
            raise RuntimeError(f'{identifier}: exit {actual}, expected {status}: {errors}')
        return errors

    def fast_exits(self):
        """Race PID publication and exit delivery with both attached and detached exec."""
        cases = []
        for index in range(12):
            identifier = f'fast-{index}'
            status = (0, 42, None)[index % 3]
            arguments = ['/missing-process-probe'] if status is None else [
                '/bin/busybox', 'sh', '-c', f'echo {identifier}; exit {status}']
            cases.append((self.start(identifier, arguments), identifier, status))
        for client, identifier, status in cases:
            errors = self.expect(client, identifier, status)
            if status is None:
                if 'OCI runtime exec failed' not in errors:
                    raise RuntimeError(f'{identifier}: missing runtime diagnosis: {errors}')
            elif (self.scratch / (identifier + '.out')).read_bytes() != (identifier + '\n').encode():
                raise RuntimeError(f'{identifier}: final output lost or mixed with another exec')

        detached = [(self.start(f'quick-{index}', ['/bin/busybox', 'true'], detached=True),
                     f'quick-{index}') for index in range(8)]
        for client, identifier in detached:
            self.expect(client, identifier, 0)
            pid = int((self.bundle / (identifier + '.pid')).read_text())
            if pid <= 1:
                raise RuntimeError(f'{identifier}: invalid published PID {pid}')
            deadline = time.monotonic() + 20
            while Path(f'/proc/{pid}').exists():
                if time.monotonic() >= deadline:
                    raise RuntimeError(f'{identifier}: shim did not reap PID {pid}')
                time.sleep(0.02)
        print('containerd: concurrent fast exec exits, failures, PID files and reaping passed')

    def backpressure(self):
        """Hold both streams full, prove unrelated exec works, then drain through EOF."""
        size = 2 * 1024 * 1024
        script = (f'(/bin/busybox head -c {size} /dev/zero; echo stdout-tail) & '
                  f'(/bin/busybox head -c {size} /dev/zero; echo stderr-tail) >&2 & '
                  'wait; ' + ('' if self.immediate_exit else 'read release; ') + 'exit 23')
        client = self.start('slow-reader', ['/bin/busybox', 'sh', '-c', script], pipes=True)
        streams = {client.stdout: bytearray(), client.stderr: bytearray()}
        with selectors.DefaultSelector() as ready:
            self.files.enter_context(client.stdin)
            for stream in streams:
                self.files.enter_context(stream)
                os.set_blocking(stream.fileno(), False)
                ready.register(stream, selectors.EVENT_READ)
            if not ready.select(timeout=20):
                raise RuntimeError('slow reader: no initial output')
            # Each producer writes far more than pipe capacity. Leave the readers
            # stopped while an independent exec proves the shim stays responsive.
            time.sleep(0.2)
            if client.poll() is not None:
                raise RuntimeError('slow reader: producer exited before readers resumed')
            other = self.start('while-blocked', ['/bin/busybox', 'echo', 'responsive'])
            self.expect(other, 'while-blocked', 0)
            if (self.scratch / 'while-blocked.out').read_bytes() != b'responsive\n':
                raise RuntimeError('unrelated exec lost output while another stream was blocked')

            deadline = time.monotonic() + 30
            released = self.immediate_exit
            while ready.get_map():
                if time.monotonic() >= deadline:
                    raise RuntimeError('slow reader: timed out draining output or waiting for EOF')
                for key, _ in ready.select(timeout=0.1):
                    try:
                        chunk = os.read(key.fd, 8192)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        ready.unregister(key.fileobj)
                    else:
                        streams[key.fileobj].extend(chunk)
                        if len(streams[key.fileobj]) > size + 1024:
                            raise RuntimeError('slow reader: unexpected extra output')
                if not released and all(len(data) >= size + len(b'stdout-tail\n') for data in streams.values()):
                    # ctr 2.2.2 cancels output copying when the exec exits, even
                    # with runc. Acknowledge receipt before exit to isolate shim
                    # backpressure from that client-side final-drain defect.
                    client.stdin.write(b'release\n')
                    client.stdin.flush()
                    client.stdin.close()
                    released = True
                time.sleep(0.001)
        if client.wait(timeout=10) != 23:
            raise RuntimeError('slow reader: workload exit status was not 23')
        for stream, tail in ((client.stdout, b'stdout-tail\n'), (client.stderr, b'stderr-tail\n')):
            if streams[stream] != bytes(size) + tail:
                raise RuntimeError(f'slow reader: corrupted or truncated {tail.decode().strip()}: '
                                   f'{len(streams[stream])} bytes, tail={bytes(streams[stream][-160:])!r}')
        print('containerd: slow stdout/stderr readers, acknowledged tails, EOF and unrelated exec passed')

    def close(self):
        """Kill stuck clients without waiting on their inherited output pipes."""
        for client in self.clients:
            if client.poll() is None:
                try:
                    os.killpg(client.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            client.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('socket')
    parser.add_argument('namespace')
    parser.add_argument('container')
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--immediate-exit', action='store_true',
                        help='Reproduce ctr final-output loss without the reader acknowledgement')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='sct-process-') as scratch, ExitStack() as files:
        probe = Probe(args, Path(scratch), files)
        try:
            probe.fast_exits()
            probe.backpressure()
        finally:
            probe.close()


if __name__ == '__main__':
    main()
