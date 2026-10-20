"""One-query, memory-only SQLite worker. Launched only inside the OS sandbox."""
import json
import math
import os
import resource
import sqlite3
import struct
import sys
import time

COLUMNS = ('session_id', 'completed_at', 'local_date', 'source_kind', 'burpee_type',
           'capture_mode', 'reps_actual', 'reps_planned', 'duration_sec_actual',
           'duration_sec_planned', 'credited_seconds', 'warmup', 'pace_sec', 'reps_per_20_min')
TYPES = ('INTEGER', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'INTEGER', 'INTEGER',
         'INTEGER', 'INTEGER', 'INTEGER', 'INTEGER', 'REAL', 'INTEGER')
FUNCTIONS = {'sum', 'count', 'avg', 'min', 'max', 'round', 'abs', 'coalesce', 'nullif'}
LIMITS = {'LENGTH': 65536, 'SQL_LENGTH': 4096, 'COLUMN': 16, 'EXPR_DEPTH': 64,
          'COMPOUND_SELECT': 8, 'VDBE_OP': 25000, 'ATTACHED': 0,
          'VARIABLE_NUMBER': 0, 'WORKER_THREADS': 0}


def encode(value):
    return json.dumps(value, allow_nan=False, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def error(code):
    return {'version': 1, 'ok': False, 'code': code}


def read_exact(size):
    data = bytearray()
    while len(data) < size:
        part = sys.stdin.buffer.read(size - len(data))
        if not part:
            raise ValueError('truncated')
        data.extend(part)
    return bytes(data)


def controls():
    if sys.version_info < (3, 11) or sqlite3.sqlite_version_info < (3, 40):
        raise RuntimeError('unsupported runtime')
    for name, value in [('AS', 128 * 1024**2), ('CPU', 1), ('CORE', 0), ('NOFILE', 32), ('FSIZE', 0)]:
        key = getattr(resource, 'RLIMIT_' + name)
        resource.setrlimit(key, (value, value))
        if resource.getrlimit(key) != (value, value):
            raise RuntimeError('missing control')


def valid_rows(rows):
    if not isinstance(rows, list) or len(rows) > 5000 or len(encode(rows)) > 1048576:
        return False
    for row in rows:
        if not isinstance(row, list) or len(row) != len(COLUMNS):
            return False
        for value, kind in zip(row, TYPES, strict=True):
            if value is None:
                continue
            if kind == 'TEXT':
                if not isinstance(value, str) or len(value.encode('utf-8')) > 128:
                    return False
            elif (type(value) not in (int, float) or not math.isfinite(value)
                  or (kind == 'INTEGER' and (type(value) is not int or not -(2**63) <= value < 2**63))):
                return False
    return True


def execute(request):
    if (not isinstance(request, dict) or set(request) != {'version', 'rows', 'sql'}
            or request['version'] != 1 or not valid_rows(request['rows'])):
        return error('invalid_input')
    sql = request['sql']
    if not isinstance(sql, str) or not sql.strip() or '\x00' in sql or len(sql.encode('utf-8')) > 4096:
        return error('invalid_input')
    db = sqlite3.connect(':memory:')
    db.enable_load_extension(False)
    db.execute('PRAGMA trusted_schema=OFF')
    db.execute('PRAGMA temp_store=MEMORY')
    if db.execute('PRAGMA trusted_schema').fetchone() != (0,) or db.execute('PRAGMA temp_store').fetchone() != (2,):
        raise RuntimeError('missing control')
    db.execute('CREATE TABLE sessions(session_id INTEGER, completed_at TEXT, local_date TEXT, '
               'source_kind TEXT, burpee_type TEXT, capture_mode TEXT, reps_actual INTEGER, '
               'reps_planned INTEGER, duration_sec_actual INTEGER, duration_sec_planned INTEGER, '
               'credited_seconds INTEGER, warmup INTEGER, pace_sec REAL, reps_per_20_min INTEGER)')
    db.executemany('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)', request['rows'])
    db.commit()
    for name, value in LIMITS.items():
        key = getattr(sqlite3, 'SQLITE_LIMIT_' + name)
        db.setlimit(key, value)
        if db.getlimit(key) != value:
            raise RuntimeError('missing control')
    denied = False

    def authorize(action, arg1, arg2, database, _trigger):
        nonlocal denied
        allowed = (action == sqlite3.SQLITE_SELECT
                   or (action == sqlite3.SQLITE_READ and arg1 == 'sessions'
                       and ((database == 'main' and arg2 in COLUMNS)
                            or (database in ('main', None) and arg2 == '')))
                   or (action == sqlite3.SQLITE_FUNCTION and arg2 in FUNCTIONS))
        if not allowed:
            denied = True
        return sqlite3.SQLITE_OK if allowed else sqlite3.SQLITE_DENY

    deadline = time.monotonic() + 0.9
    db.set_authorizer(authorize)
    db.set_progress_handler(lambda: time.monotonic() >= deadline, 100)
    try:
        # Deliberately untrusted SQL: default-deny authorizer and limits are installed above.
        cursor = db.execute(sql)
        if cursor.description is None:
            return error('sql_denied')
        columns = [column[0] for column in cursor.description]
        if len(columns) > 16 or len(set(columns)) != len(columns):
            return error('result_too_large')
        result = {'version': 1, 'ok': True, 'columns': columns, 'rows': []}
        for row in cursor:
            if len(result['rows']) >= 100:
                return error('result_too_large')
            if any((isinstance(v, float) and not math.isfinite(v)) or len(v.encode('utf-8') if isinstance(v, str) else encode(v)) > 1024 for v in row):
                return error('result_too_large')
            result['rows'].append(list(row))
            if len(encode(result)) > 8192:
                return error('result_too_large')
        if any(len(c.encode('utf-8')) > 1024 for c in columns) or len(encode(result)) > 8192:
            return error('result_too_large')
        return result
    except sqlite3.Error as exc:
        if denied:
            return error('sql_denied')
        if getattr(exc, 'sqlite_errorcode', None) == sqlite3.SQLITE_INTERRUPT:
            return error('query_timeout')
        return error('sql_error')
    except MemoryError:
        return error('result_too_large')
    finally:
        db.close()


def main():
    try:
        controls()
        size = struct.unpack('>I', read_exact(4))[0]
        if size > 2097152:
            raise ValueError('oversized')
        request = json.loads(read_exact(size))
        result = execute(request)
    except (ValueError, TypeError, OverflowError, UnicodeError):
        result = error('invalid_input')
    except Exception:
        result = error('executor_unavailable')
    os.write(1, encode(result))


if __name__ == '__main__':
    main()
