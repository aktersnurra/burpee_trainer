"""Trusted framing/pipe supervisor. Never executes SQL outside bubblewrap."""
import ctypes
import json
import os
import pathlib
import selectors
import signal
import stat
import struct
import subprocess
import sys
import time

MAX_INPUT = 2097152


def process_identity(pid):
    data = pathlib.Path(f'/proc/{pid}/stat').read_text()
    fields = data[data.rindex(')') + 2:].split()
    return int(fields[1]), fields[19], os.readlink(f'/proc/{pid}/exe')


def parent_guard(expected):
    parent = os.getppid()
    before = process_identity(parent)
    expected_identity = process_identity(expected)
    if parent != expected:
        beam = pathlib.Path(expected_identity[2])
        child_setup = str(beam.with_name('erl_child_setup'))
        if (beam.name != 'beam.smp' or before[0] != expected
                or before[2] != child_setup):
            raise RuntimeError('unknown ancestry')
        trusted_file(child_setup)
        trusted_file(str(beam))
    libc = ctypes.CDLL(None, use_errno=True)
    if (parent <= 1 or expected <= 1 or libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0
            or os.getppid() != parent or process_identity(parent) != before
            or process_identity(expected) != expected_identity):
        raise RuntimeError('parent lost')


def trusted_file(path):
    resolved = pathlib.Path(path).resolve(strict=True)
    for part in (resolved, *resolved.parents):
        info = part.stat()
        if info.st_uid not in (0, os.getuid()) or info.st_mode & 0o022:
            raise RuntimeError('untrusted runtime')
    if not stat.S_ISREG(resolved.stat().st_mode):
        raise RuntimeError('not a file')
    return str(resolved)


def command():
    if sys.platform != 'linux':
        raise RuntimeError('unsupported')
    trusted_file('/usr/bin/bwrap')
    trusted_file('/usr/bin/python3')
    trusted_file(__file__)
    helper = trusted_file(pathlib.Path(__file__).with_name('sqlite_helper.py'))
    return ['/usr/bin/bwrap', '--unshare-all', '--die-with-parent', '--new-session',
            '--cap-drop', 'ALL', '--ro-bind', '/usr', '/usr', '--symlink', 'usr/lib', '/lib',
            '--symlink', 'usr/lib64', '/lib64', '--proc', '/proc', '--dev', '/dev',
            '--size', '1048576', '--tmpfs', '/tmp', '--ro-bind', helper, '/helper.py',
            '--clearenv', '/usr/bin/python3', '-I', '/helper.py']


def response(code):
    return {'version': 1, 'ok': False, 'code': code}


def remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError
    return value


def read_frame(selector, deadline):
    data = bytearray()
    size = None
    while size is None or len(data) < size + 4:
        if not selector.select(remaining(deadline)):
            raise TimeoutError
        chunk = os.read(0, 65536)
        if not chunk:
            raise ValueError('truncated')
        data.extend(chunk)
        if size is None and len(data) >= 4:
            size = struct.unpack('>I', data[:4])[0]
            if size > MAX_INPUT:
                raise ValueError('oversized')
        if size is not None and len(data) > size + 4:
            raise ValueError('extra input')
    return data


def supervise():
    deadline = time.monotonic() + 1.0
    process = None
    selector = selectors.DefaultSelector()
    selector.register(0, selectors.EVENT_READ, 'caller')
    try:
        parent_guard(int(sys.argv[1]) if len(sys.argv) == 2 else os.getppid())
        argv = command()
        frame = read_frame(selector, deadline)
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, close_fds=True, env={})
        assert process.stdin is not None and process.stdout is not None and process.stderr is not None
        streams = {'input': process.stdin, 'stdout': process.stdout, 'stderr': process.stderr}
        for stream in streams.values():
            os.set_blocking(stream.fileno(), False)
        selector.register(process.stdin, selectors.EVENT_WRITE, 'input')
        selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
        selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
        buffers = {'stdout': bytearray(), 'stderr': bytearray()}
        sent = 0
        open_outputs = 2
        while open_outputs:
            events = selector.select(remaining(deadline))
            for key, _mask in events:
                if key.data == 'caller':
                    # EOF is cancellation once the single complete frame was accepted.
                    raise ValueError('caller gone or extra data')
                if key.data == 'input':
                    sent += os.write(key.fd, frame[sent:])
                    if sent == len(frame):
                        selector.unregister(key.fileobj)
                        process.stdin.close()
                    continue
                data = os.read(key.fd, 8193)
                if not data:
                    selector.unregister(key.fileobj)
                    streams[key.data].close()
                    open_outputs -= 1
                    continue
                buffers[key.data].extend(data)
                cap = 8192 if key.data == 'stdout' else 1024
                if len(buffers[key.data]) > cap:
                    raise ValueError('output overflow')
        process.wait(timeout=remaining(deadline))
        if process.returncode != 0 or buffers['stderr']:
            return response('executor_unavailable')
        result = json.loads(buffers['stdout'])
        if not isinstance(result, dict) or result.get('version') != 1 or type(result.get('ok')) is not bool:
            raise ValueError('invalid response')
        return result
    except (TimeoutError, subprocess.TimeoutExpired):
        return response('query_timeout')
    except (ValueError, UnicodeError, struct.error):
        return response('invalid_input')
    except Exception:
        return response('executor_unavailable')
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        selector.close()


if __name__ == '__main__':
    output = json.dumps(supervise(), allow_nan=False, separators=(',', ':'), ensure_ascii=False).encode()
    if len(output) > 8192:
        output = json.dumps(response('result_too_large')).encode()
    try:
        while output:
            output = output[os.write(1, output):]
    except BrokenPipeError:
        pass
