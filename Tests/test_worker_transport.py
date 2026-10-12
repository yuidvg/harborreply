"""Persistent transport stays equivalent to independent worker requests."""
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

WORKER = Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'
sys.path.insert(0, str(WORKER))
import main


class WorkerTransportTests(unittest.TestCase):
    def test_fixed_contract_does_not_open_database(self):
        with patch.object(main, 'Archive', side_effect=AssertionError('unnecessary DB')):
            result = main.dispatch({'db': '/unused.invalid/db', 'command': 'contract'})
        self.assertIn('schema', result)

    def test_one_child_handles_errors_writes_and_fresh_reads(self):
        with tempfile.TemporaryDirectory() as root:
            db = str(Path(root) / 'fixture.invalid.sqlite')
            child = subprocess.Popen([sys.executable, '-B', str(WORKER / 'main.py'), '--serve'],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            def call(command, **args):
                raw = json.dumps(dict(db=db, command=command, **args)).encode() + b'\n'
                child.stdin.write(raw); child.stdin.flush()
                return json.loads(child.stdout.readline())
            try:
                self.assertTrue(call('case_create', label='fixture.invalid')['ok'])
                self.assertFalse(call('unknown.invalid')['ok'])
                self.assertEqual(len(call('cases')['result']), 1)
                # A separate writer is visible; no request-level data cached.
                main.dispatch(dict(db=db, command='case_create', label='second.invalid'))
                self.assertEqual(len(call('cases')['result']), 2)
                self.assertIsNone(child.poll())
                child.stdin.close()
                self.assertEqual(child.wait(timeout=5), 0)
                self.assertEqual(child.stderr.read(), b'')
            finally:
                if child.poll() is None: child.kill(); child.wait()
                child.stdout.close(); child.stderr.close()

    def test_malformed_frame_does_not_poison_next_request(self):
        sink = io.StringIO()
        raw = b'no json\n' + json.dumps(dict(db='/unused.invalid/db', command='contract')).encode() + b'\n'
        main.serve(io.BytesIO(raw), sink)
        values = [json.loads(line) for line in sink.getvalue().splitlines()]
        self.assertFalse(values[0]['ok']); self.assertTrue(values[1]['ok'])

    def test_oversized_frame_stops_without_dispatching_tail(self):
        sink = io.StringIO()
        with patch.object(main, 'dispatch', side_effect=AssertionError('must not dispatch')):
            main.serve(io.BytesIO(b' ' * (2 * 1024 * 1024 + 2) + b'\n{}\n'), sink)
        self.assertEqual(len(sink.getvalue().splitlines()), 1)
        self.assertEqual(json.loads(sink.getvalue())['error'], 'IPC_INPUT_LIMIT')
