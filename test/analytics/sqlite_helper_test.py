"""Real isolated helper policy/protocol tests; no unconfined SQL execution."""
import importlib.util
import json
import os
import pathlib
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest


def load_module(path):
    spec = importlib.util.spec_from_file_location('analytics_launcher', path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sandbox_worker(mode):
    helper = load_module('/production.py')
    helper.controls()
    if mode == 'stdout':
        os.write(1, b'x' * 9000)
    elif mode == 'stderr':
        os.write(2, b'x' * 2048)
    elif mode == 'malformed':
        os.write(1, b'{} trailing bytes')
    elif mode == 'die':
        os.kill(os.getpid(), signal.SIGKILL)
    elif mode == 'memory':
        try:
            bytearray(256 * 1024**2)
        except MemoryError:
            print(json.dumps({'version': 1, 'ok': True, 'columns': ['bounded'], 'rows': [[1]]}))
    elif mode.startswith('network:'):
        with socket.socket() as client:
            assert client.connect_ex(('127.0.0.1', int(mode.split(':')[1]))) != 0
        print(json.dumps({'version': 1, 'ok': True, 'columns': ['isolated'], 'rows': [[1]]}))
    elif mode == 'filesystem':
        assert not pathlib.Path('/home').exists()
        assert not list(pathlib.Path('/tmp').iterdir())
        mounts = pathlib.Path('/proc/mounts').read_text()
        assert ' /tmp tmpfs ' in mounts and 'size=1024k' in mounts
        print(json.dumps({'version': 1, 'ok': True, 'columns': ['isolated'], 'rows': [[1]]}))
    else:
        while True:
            pass


if len(sys.argv) == 3 and sys.argv[1] == 'worker':
    sandbox_worker(sys.argv[2])
    sys.exit(0)

ROOT = pathlib.Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / 'priv/analytics/helper_launcher.py'
ROW = [1, '2026-10-20T00:00:00Z', '2026-10-20', 'manual', 'six_count',
       'logged', 30, 100, 600, 1200, 600, 0, 20.0, 60]


def query(sql, rows=None):
    data = json.dumps({'version': 1, 'rows': [ROW] if rows is None else rows, 'sql': sql}).encode()
    with subprocess.Popen(['/usr/bin/python3', '-I', str(LAUNCHER)],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        assert process.stdin is not None and process.stdout is not None
        process.stdin.write(struct.pack('>I', len(data)) + data)
        process.stdin.flush()
        result = json.loads(process.stdout.readline())
        process.wait(timeout=3)
        return result


def synthetic_launcher(mode):
    # Exercise the real launcher's pipe supervisor with a controlled worker INSIDE
    # the same bwrap boundary. No production test switch or unconfined SQL path.
    code = ("import importlib.util; "
            f"s=importlib.util.spec_from_file_location('launcher',{str(LAUNCHER)!r}); "
            "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);a=m.command(); "
            "i=a.index('/helper.py'); "
            f"a[i-1]={str(pathlib.Path(__file__).resolve())!r}; "
            f"j=a.index('--clearenv');a[j:j]=['--ro-bind',{str(LAUNCHER.with_name('sqlite_helper.py'))!r},'/production.py']; "
            f"a+=['worker',{mode!r}];m.command=lambda:a; "
            "print(m.json.dumps(m.supervise()),flush=True)")
    return subprocess.Popen(['/usr/bin/python3', '-I', '-c', code],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def send_frame(process, payload=b'{}'):
    assert process.stdin is not None
    process.stdin.write(struct.pack('>I', len(payload)) + payload)
    process.stdin.flush()


def worker_pidfd(parent):
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        pending = [parent]
        while pending:
            pid = pending.pop()
            try:
                children = pathlib.Path(f'/proc/{pid}/task/{pid}/children').read_text().split()
                pending.extend(map(int, children))
                cmdline = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\x00')
                if b'/helper.py' in cmdline and b'--ro-bind' not in cmdline:
                    return os.pidfd_open(pid)
            except (FileNotFoundError, ProcessLookupError):
                continue
    raise AssertionError('sandbox worker was not observed')


def assert_exited(test, fd):
    poller = select.poll()
    poller.register(fd, select.POLLIN)
    test.assertTrue(poller.poll(1500), 'sandbox worker survived')


class SqliteHelperTest(unittest.TestCase):
    def test_allowed_aggregation(self):
        result = query('SELECT sum(reps_actual) AS reps, count(*) AS n FROM sessions')
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['rows'], [[30, 1]])

    def test_mutations_metadata_recursion_and_functions_are_denied(self):
        for sql in ["ATTACH ':memory:' AS other", 'PRAGMA database_list',
                    'DELETE FROM sessions', 'CREATE TABLE evil(x)',
                    'SELECT * FROM sqlite_master', 'SELECT * FROM pragma_database_list',
                    "SELECT load_extension('/secret')", 'SELECT randomblob(100000000)',
                    'SELECT zeroblob(100)', "SELECT date('now')",
                    'WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n) SELECT sum(x) FROM n']:
            with self.subTest(sql=sql):
                self.assertFalse(query(sql)['ok'])

    def test_single_statement_semantics_not_semicolon_splitting(self):
        for sql in ["SELECT ';' AS punctuation; -- trailing comment", "SELECT ';' AS punctuation /* ; */"]:
            self.assertEqual(query(sql)['rows'], [[';']])
        for sql in ['SELECT 1; SELECT 2', 'SELECT 1; -- x\n ATTACH \'/tmp/db\' AS x', 'SELECT 1\x00']:
            self.assertFalse(query(sql)['ok'])

    def test_result_bounds_and_nonfinite(self):
        for sql in ['SELECT 1 AS x, 2 AS x', 'SELECT 1e999 AS x',
                    "SELECT '" + 'x' * 1025 + "' AS x"]:
            self.assertEqual(query(sql)['code'], 'result_too_large')
        rows = [ROW] * 101
        self.assertEqual(query('SELECT session_id FROM sessions', rows)['code'], 'result_too_large')
        self.assertTrue(query('SELECT count(*) AS n FROM sessions', rows)['ok'])

    def test_invalid_protocol(self):
        for data in [b'', b'\x00\x00', struct.pack('>I', 2097153), struct.pack('>I', 2) + b'{']:
            process = subprocess.run(['/usr/bin/python3', '-I', str(LAUNCHER)], input=data,
                                     capture_output=True, timeout=3)
            self.assertFalse(json.loads(process.stdout)['ok'])

    def test_exact_1024_utf8_byte_cell_is_allowed(self):
        result = query("SELECT '" + 'x' * 1024 + "' AS x")
        self.assertTrue(result['ok'], result)

    def test_valid_near_limit_result_is_not_limited_to_stderr_cap(self):
        result = query("SELECT '" + 'x' * 90 + "' AS x FROM sessions", [ROW] * 80)
        self.assertTrue(result['ok'], result)
        self.assertGreater(len(json.dumps(result)), 7500)
        self.assertEqual(query("SELECT '" + 'x' * 100 + "' AS x FROM sessions", [ROW] * 100)['code'],
                         'result_too_large')

    def test_actual_launcher_independently_bounds_pipes_and_malformed_output(self):
        for mode in ['stdout', 'stderr', 'malformed', 'die']:
            with self.subTest(mode=mode), synthetic_launcher(mode) as process:
                send_frame(process)
                assert process.stdout is not None
                result = json.loads(process.stdout.readline())
                self.assertFalse(result['ok'])
                process.wait(timeout=3)

    def test_memory_and_filesystem_controls_inside_actual_sandbox(self):
        # A real, securely allocated host temp marker must not appear in private /tmp.
        with tempfile.NamedTemporaryFile(prefix='analytics-host-marker-'):
            for mode in ['memory', 'filesystem']:
                with self.subTest(mode=mode), synthetic_launcher(mode) as process:
                    send_frame(process)
                    assert process.stdout is not None
                    self.assertTrue(json.loads(process.stdout.readline())['ok'])
                    process.wait(timeout=3)

    def test_network_namespace_cannot_reach_host_listener(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            with synthetic_launcher('network:' + str(listener.getsockname()[1])) as process:
                send_frame(process)
                assert process.stdout is not None
                self.assertTrue(json.loads(process.stdout.readline())['ok'])
                process.wait(timeout=3)

    def test_cpu_hard_limit_without_wall_watchdog(self):
        module = load_module(LAUNCHER)
        argv = module.command()
        index = argv.index('/helper.py')
        argv[index - 1] = str(pathlib.Path(__file__).resolve())
        index = argv.index('--clearenv')
        argv[index:index] = ['--ro-bind', str(LAUNCHER.with_name('sqlite_helper.py')), '/production.py']
        result = subprocess.run(argv + ['worker', 'cpu'], capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 128 + signal.SIGKILL, result.stderr)

    def test_wall_timeout_kills_and_reaps_actual_worker(self):
        with synthetic_launcher('cpu') as process:
            send_frame(process)
            fd = worker_pidfd(process.pid)
            try:
                assert process.stdout is not None
                self.assertEqual(json.loads(process.stdout.readline())['code'], 'query_timeout')
                process.wait(timeout=3)
                assert_exited(self, fd)
            finally:
                os.close(fd)

    def test_caller_eof_and_launcher_death_kill_actual_worker(self):
        for mode in ['eof', 'kill']:
            with self.subTest(mode=mode), synthetic_launcher('cpu') as process:
                send_frame(process)
                fd = worker_pidfd(process.pid)
                try:
                    assert process.stdin is not None
                    if mode == 'eof':
                        process.stdin.close()
                    else:
                        process.kill()
                    process.wait(timeout=3)
                    assert_exited(self, fd)
                finally:
                    os.close(fd)

    def test_os_parent_death_kills_launcher_and_sandbox(self):
        code = (f"import subprocess; p=subprocess.Popen(['/usr/bin/python3','-I',{str(LAUNCHER)!r}]); "
                "print(p.pid,flush=True);p.wait()")
        with subprocess.Popen(['/usr/bin/python3', '-I', '-c', code], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as parent:
            assert parent.stdout is not None
            launcher_pid = int(parent.stdout.readline())
            data = json.dumps({'version': 1, 'rows': [ROW] * 1000,
                               'sql': 'SELECT sum(a.reps_actual*b.reps_actual*c.reps_actual) '
                                      'FROM sessions a, sessions b, sessions c'}).encode()
            send_frame(parent, data)
            worker_fd = worker_pidfd(launcher_pid)
            launcher_fd = os.pidfd_open(launcher_pid)
            try:
                parent.kill()
                parent.wait(timeout=3)
                assert_exited(self, launcher_fd)
                assert_exited(self, worker_fd)
            finally:
                os.close(worker_fd)
                os.close(launcher_fd)

    def test_parent_death_before_guard_registration_refuses(self):
        child_code = ("import os,signal,runpy;os.kill(os.getpid(),signal.SIGSTOP);"
                      f"runpy.run_path({str(LAUNCHER)!r},run_name='__main__')")
        code = (f"import os,subprocess;p=subprocess.Popen(['/usr/bin/python3','-I','-c',{child_code!r}]);"
                "os.waitpid(p.pid,os.WUNTRACED);print(p.pid,flush=True);p.wait()")
        with subprocess.Popen(['/usr/bin/python3', '-I', '-c', code], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as parent:
            assert parent.stdout is not None
            child = int(parent.stdout.readline())
            fd = os.pidfd_open(child)
            try:
                parent.kill()
                parent.wait(timeout=3)
                os.kill(child, signal.SIGCONT)
                result = json.loads(parent.stdout.readline())
                self.assertFalse(result['ok'])
                assert_exited(self, fd)
            finally:
                os.close(fd)

    def test_missing_controls_fail_closed_without_fallback(self):
        code = ("import importlib.util;"
                f"s=importlib.util.spec_from_file_location('launcher',{str(LAUNCHER)!r});"
                "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
                "m.command=lambda:['/nonexistent-bwrap'];print(m.json.dumps(m.supervise()))")
        with subprocess.Popen(['/usr/bin/python3', '-I', '-c', code], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            send_frame(process)
            assert process.stdout is not None
            self.assertEqual(json.loads(process.stdout.readline())['code'], 'executor_unavailable')
            process.wait(timeout=3)

    def test_wrong_expected_parent_refuses(self):
        result = subprocess.run(['/usr/bin/python3', '-I', str(LAUNCHER), '1'],
                                input=b'{}', capture_output=True, timeout=3)
        self.assertFalse(json.loads(result.stdout)['ok'])

    def test_limits_and_null_actuals(self):
        row = ROW.copy()
        row[6] = row[8] = row[12] = row[13] = None
        self.assertEqual(query('SELECT reps_actual, reps_planned, pace_sec FROM sessions', [row])['rows'],
                         [[None, 100, None]])
        for sql in ['SELECT ? AS x', 'SELECT ' + '1+' * 70 + '1', 'SELECT ' + 'x' * 4096]:
            self.assertFalse(query(sql)['ok'])


if __name__ == '__main__':
    unittest.main()
