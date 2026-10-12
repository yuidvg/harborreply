"""Fixed error contracts; only fictional temporary state and injected failures."""
import ast
import errno
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

WORKER = Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'
sys.path.insert(0, str(WORKER))
import main
from archive import ArchiveError

NEW_CODES = frozenset((
    'IPC_INVALID_JSON', 'IPC_REQUEST_INVALID', 'SQLITE_DATABASE_CORRUPT',
    'SQLITE_DATABASE_BUSY', 'SQLITE_DATABASE_PERMISSION', 'SQLITE_DATABASE_ERROR',
    'OS_SOURCE_PERMISSION', 'OS_SOURCE_UNAVAILABLE', 'LOCAL_OPERATION_FAILED',
    'WORKER_RESOURCE_MISSING',
))
PRIVATE_TEXT = '架空メール本文 private@fixture.invalid /fictional/private.invalid/message.eml'
NUMERIC_SQLITE_ERRORS = hasattr(sqlite3, 'SQLITE_ERROR')  # Numeric exception attributes are Python 3.11+.


class WorkerFailureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='harbor-failure-fixture-')
        self.root = Path(self.temporary.name).resolve()
        self.database = self.root / 'fixture.invalid.sqlite'

    def tearDown(self):
        self.temporary.cleanup()

    def launch(self, raw, script=None):
        process = subprocess.run([sys.executable, '-s', '-B', str(script or WORKER / 'main.py')],
                                 input=raw, capture_output=True, timeout=15)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(process.stderr, b'')
        value = json.loads(process.stdout)
        self.assertEqual(set(value), {'ok', 'result'} if value['ok'] else {'ok', 'error'})
        if not value['ok']:
            self.assertIn(value['error'], main.FAILURE_CODES)
            self.assertNotIn('private@fixture.invalid', process.stdout.decode())
            self.assertNotIn(str(self.root), process.stdout.decode())
        return value

    def request(self, command, **fields):
        return json.dumps(dict(db=str(self.database), command=command, **fields)).encode()

    def test_allowlist_covers_all_internal_literals_defaults_and_dynamic_callers(self):
        """New internal errors require a reviewed public entry; arbitrary text never qualifies."""
        codes = set(NEW_CODES)
        helpers = {'text': 2, 'metadata_text': 1}
        for path in sorted(WORKER.glob('*.py')):
            tree = ast.parse(path.read_text())
            for node in ast.walk(tree):
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                    if node.func.id == 'ArchiveError':
                        self.assertEqual(len(node.args), 1)
                        value = node.args[0]
                        if isinstance(value, ast.Constant) and type(value.value) is str:
                            codes.add(value.value)
                        else:
                            # Only the two reviewed metadata validators forward an error argument.
                            self.assertEqual(path.name, 'mail_index.py')
                            self.assertIsInstance(value, ast.Name)
                            self.assertEqual(value.id, 'error')
                    if path.name == 'mail_index.py' and node.func.id in helpers:
                        position = helpers[node.func.id]
                        forwarded = list(node.args[position:position+1]) + [k.value for k in node.keywords if k.arg == 'error']
                        for value in forwarded:
                            if isinstance(value, ast.Constant) and type(value.value) is str:
                                codes.add(value.value)
                            else:
                                self.assertIsInstance(value, ast.Name)
                                self.assertEqual(value.id, 'error')
                if path.name == 'mail_index.py' and isinstance(node, ast.FunctionDef) and node.name in helpers:
                    for argument, default in zip(node.args.args[-len(node.args.defaults):], node.args.defaults):
                        if argument.arg == 'error':
                            self.assertIsInstance(default, ast.Constant)
                            codes.add(default.value)
        resource = json.loads((WORKER / 'failure_codes.json').read_bytes())
        self.assertEqual(resource['version'], 1)
        self.assertEqual(resource['codes'], sorted(codes))
        self.assertIn('INDEX_WARNING_LIMIT', codes)
        self.assertEqual(main.FAILURE_CODES, frozenset(codes))

    def test_launched_invalid_json_and_format_never_echo_input_or_create_db(self):
        for raw in (b'{"private@fixture.invalid":', b'\xff', b'{"db":NaN}',
                    b'{"db":"first.invalid","db":"second.invalid"}',
                    b'[' * 1500 + b']' * 1499):
            with self.subTest(raw_length=len(raw)):
                self.assertEqual(self.launch(raw), {'ok': False, 'error': 'IPC_INVALID_JSON'})
        for request in (None, [], {'db': str(self.database)}, {'db': str(self.database), 'command': 12},
                        {'db': str(self.database), 'command': 'message'},
                        {'db': str(self.database), 'command': 'prepare', 'input': {'private@fixture.invalid': PRIVATE_TEXT}},
                        {'db': str(self.database) + '\0', 'command': 'status'}):
            with self.subTest(request_type=type(request).__name__):
                self.assertEqual(self.launch(json.dumps(request).encode()), {'ok': False, 'error': 'IPC_REQUEST_INVALID'})
        self.assertFalse(self.database.exists())
        self.assertEqual(self.launch(b'x' * (2 * 1024 * 1024 + 1)), {'ok': False, 'error': 'IPC_INPUT_LIMIT'})

    def test_launched_success_and_known_domain_errors_keep_existing_contract(self):
        success = self.launch(self.request('overview'))
        self.assertTrue(success['ok'])
        self.assertIn('coverage', success['result'])
        self.assertIn('style_summary', success['result'])
        for command, fields, expected in (
                ('style_extract', {}, 'STYLE_EXAMPLES_REQUIRED'),
                ('message', {'id': 'absent@fixture.invalid'}, 'MESSAGE_NOT_FOUND'),
                ('source_message_ids', {'source_id': 'absent@fixture.invalid'}, 'SOURCE_NOT_FOUND'),
                ('unknown@fixture.invalid', {}, 'UNKNOWN_COMMAND')):
            with self.subTest(command=command):
                self.assertEqual(self.launch(self.request(command, **fields)), {'ok': False, 'error': expected})

    def test_launched_corrupt_database_and_unopenable_database_are_distinct(self):
        self.database.write_bytes(b'fictional.invalid corrupted database' * 20)
        expected = 'SQLITE_DATABASE_CORRUPT' if NUMERIC_SQLITE_ERRORS else 'SQLITE_DATABASE_ERROR'
        self.assertEqual(self.launch(self.request('status')), {'ok': False, 'error': expected})
        directory = self.root / 'directory.invalid'
        directory.mkdir()
        raw = json.dumps({'db': str(directory), 'command': 'status'}).encode()
        self.assertEqual(self.launch(raw), {'ok': False, 'error': 'SQLITE_DATABASE_ERROR'})

    def test_real_sqlite_busy_and_readonly_classify_by_number_without_text(self):
        first = sqlite3.connect(self.database)
        second = sqlite3.connect(self.database, timeout=0.01)
        try:
            first.execute('CREATE TABLE fictional(id INTEGER)')
            first.commit()
            first.execute('BEGIN EXCLUSIVE')
            with self.assertRaises(sqlite3.OperationalError) as busy:
                second.execute('SELECT * FROM fictional').fetchall()
            expected = 'SQLITE_DATABASE_BUSY' if NUMERIC_SQLITE_ERRORS else 'SQLITE_DATABASE_ERROR'
            self.assertEqual(main.failure_response(busy.exception), {'ok': False, 'error': expected})
            first.rollback()
            second.execute('PRAGMA query_only=ON')
            with self.assertRaises(sqlite3.OperationalError) as readonly:
                second.execute('INSERT INTO fictional VALUES(1)')
            expected = 'SQLITE_DATABASE_PERMISSION' if NUMERIC_SQLITE_ERRORS else 'SQLITE_DATABASE_ERROR'
            self.assertEqual(main.failure_code(readonly.exception), expected)
        finally:
            first.close()
            second.close()

    def test_private_exception_strings_unknown_codes_and_extended_sqlite_errors_are_sanitized(self):
        class PrivateArchiveError(ArchiveError):
            def __str__(self):
                raise AssertionError('Never format this exception')
        errors = (
            (ArchiveError('SOURCE_CHANGED'), 'SOURCE_CHANGED'),
            (ArchiveError('INDEX_WARNING_LIMIT'), 'INDEX_WARNING_LIMIT'),
            (ArchiveError('PRIVATE_MAIL_BODY'), 'LOCAL_OPERATION_FAILED'),
            (ArchiveError(PRIVATE_TEXT), 'LOCAL_OPERATION_FAILED'),
            (ArchiveError('SOURCE_CHANGED', PRIVATE_TEXT), 'LOCAL_OPERATION_FAILED'),
            (PrivateArchiveError('SOURCE_CHANGED'), 'SOURCE_CHANGED'),
            (RuntimeError(PRIVATE_TEXT), 'LOCAL_OPERATION_FAILED'),
            (KeyError(PRIVATE_TEXT), 'LOCAL_OPERATION_FAILED'),
            (sqlite3.OperationalError('database locked: ' + PRIVATE_TEXT), 'SQLITE_DATABASE_ERROR'),
            (PermissionError(errno.EACCES, PRIVATE_TEXT, '/fictional/private.invalid/message.eml'), 'OS_SOURCE_PERMISSION'),
            (OSError(errno.EPERM, PRIVATE_TEXT), 'OS_SOURCE_PERMISSION'),
            (FileNotFoundError(errno.ENOENT, PRIVATE_TEXT, '/fictional/private.invalid/message.eml'), 'OS_SOURCE_UNAVAILABLE'),
            (OSError(errno.EIO, PRIVATE_TEXT), 'OS_SOURCE_UNAVAILABLE'),
        )
        for error, code in errors:
            with self.subTest(error_type=type(error).__name__, expected=code), patch.object(main, 'dispatch', side_effect=error):
                response = main.process_request(self.request('status'))
                self.assertEqual(response, {'ok': False, 'error': code})
                self.assertNotIn(PRIVATE_TEXT, json.dumps(response))
        for number, code in ((11 | (1 << 8), 'SQLITE_DATABASE_CORRUPT'),
                             (5 | (2 << 8), 'SQLITE_DATABASE_BUSY'),
                             (8 | (4 << 8), 'SQLITE_DATABASE_PERMISSION'),
                             (1, 'SQLITE_DATABASE_ERROR')):
            error = sqlite3.DatabaseError(PRIVATE_TEXT)
            error.sqlite_errorcode = number
            self.assertEqual(main.failure_code(error), code)

    def test_missing_or_malformed_resource_fails_closed_without_db_or_stderr(self):
        standalone = self.root / 'standalone.invalid'
        standalone.mkdir()
        for source in WORKER.glob('*.py'):
            shutil.copy2(source, standalone / source.name)
        self.assertEqual(self.launch(self.request('status'), standalone / 'main.py'),
                         {'ok': False, 'error': 'WORKER_RESOURCE_MISSING'})
        self.assertFalse(self.database.exists())
        resource = standalone / 'failure_codes.json'
        for value in ({'version': True, 'codes': ['LOCAL_OPERATION_FAILED', 'WORKER_RESOURCE_MISSING']},
                      {'version': 1, 'codes': [PRIVATE_TEXT]},
                      {'version': 1, 'codes': ['LOCAL_OPERATION_FAILED', 'WORKER_RESOURCE_MISSING', 'LOCAL_OPERATION_FAILED']}):
            resource.write_text(json.dumps(value))
            self.assertEqual(self.launch(self.request('status'), standalone / 'main.py'),
                             {'ok': False, 'error': 'WORKER_RESOURCE_MISSING'})
        resource.write_bytes(b'[' * 1500 + b']' * 1500)
        self.assertEqual(self.launch(self.request('status'), standalone / 'main.py'),
                         {'ok': False, 'error': 'WORKER_RESOURCE_MISSING'})
        with patch.object(Path, 'open', side_effect=PermissionError(errno.EACCES, PRIVATE_TEXT)):
            self.assertIsNone(main._load_failure_codes())
            # Normal error response never reopens the resource after import.
            self.assertEqual(main.failure_code(ArchiveError('SOURCE_CHANGED')), 'SOURCE_CHANGED')
        self.assertFalse(self.database.exists())


if __name__ == '__main__':
    unittest.main()
