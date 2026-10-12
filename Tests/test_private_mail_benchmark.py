"""Only synthetic fixtures; external real-Mail benchmarks stay explicit opt-in."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('private_mail_benchmark', ROOT / 'scripts/benchmark-private-mail.py')
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class PrivateMailBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='harborreply-live-state-')
        self.root = Path(self.temporary.name).resolve()
        os.chmod(self.root, 0o700)
        self.path = self.root / 'isolated.sqlite'
        self.private_marker = 'PRIVATE_FIXTURE_SENTINEL_NOT_FOR_OUTPUT'
        self.current = {'id': self.private_marker, 'account': 'account@fixture.invalid',
                        'messageID': 'selected@fixture.invalid', 'subject': 'AWS Free Tier usage',
                        'sender': 'alerts@fixture.invalid', 'body': self.private_marker, 'headers': ''}
        archive = benchmark.Archive(self.path)
        state = archive.mail_index.start()
        archive.mail_index.discovery(state['scan_id'], state['epoch'], None, None,
                                     [{'accountID': 'account@fixture.invalid', 'mailboxPath': ['Inbox'],
                                       'messageCount': 32, 'role': 'received', 'isLocal': False}], True)
        pending = archive.mail_index.next(state['scan_id'], state['epoch'])
        records = [{'id': str(number + 1), 'accountID': 'account@fixture.invalid', 'mailboxPath': ['Inbox'],
                    'messageID': str(number) + '@fixture.invalid', 'subject': 'AWS billing status ' + self.private_marker,
                    'sender': 'alerts@fixture.invalid', 'messageSize': 200, 'direction': 'received',
                    'dateSent': '2026-10-11T00:00:00Z', 'body': self.private_marker,
                    'headers': '', 'attachmentCount': 0} for number in range(32)]
        archive.mail_index.page(state['scan_id'], state['epoch'], pending['mailbox_id'], pending['cursor'], None, records, True)
        archive.mail_index.finish(state['scan_id'], state['epoch'])
        archive.db.close()

    def tearDown(self):
        self.temporary.cleanup()

    def request(self, **changes):
        value = {'db': str(self.path), 'current': self.current, 'samples': 3}
        value.update(changes)
        return json.dumps(value).encode()

    def test_shipping_read_methods_measure_without_content_or_database_writes(self):
        before = hashlib.sha256(self.path.read_bytes()).digest()
        result = benchmark.run(self.request())
        self.assertTrue(result['succeeded'], result)
        self.assertTrue(result['read_only'])
        self.assertFalse(result['mail_called'])
        self.assertFalse(result['actual_300gb_verified'])
        self.assertEqual(result['index_counts']['metadata'], 32)
        self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).digest())
        encoded = json.dumps(result)
        for secret in (self.private_marker, 'fixture.invalid', str(self.path), 'selected@'):
            self.assertNotIn(secret, encoded)
        operations = {row['operation']: row for row in result['operations']}
        self.assertEqual(set(operations), {'related', 'prepare', 'overview', 'search_ids'})
        self.assertEqual(operations['related']['result_count'], 32)
        self.assertLessEqual(operations['prepare']['result_count'], 20)
        for measured in operations.values():
            self.assertEqual(measured['samples'], 3)
            self.assertGreater(measured['p95_milliseconds'], 0)
            self.assertGreaterEqual(measured['p95_milliseconds'], measured['p50_milliseconds'])
            self.assertGreater(measured['sql_statement_count'], 0)
        self.assertTrue(result['query_plans']['fts_virtual_index'])
        self.assertTrue(result['query_plans']['metadata_point_index'])
        self.assertFalse(result['query_plans']['search_uses_temporary_sort'])

    def test_database_is_explicitly_read_only(self):
        archive = benchmark.open_read_only(benchmark.private_database(str(self.path)))
        try:
            with self.assertRaises(sqlite3.OperationalError):
                archive.db.execute('UPDATE meta SET value=0')
        finally:
            archive.db.close()

    def test_rejects_unbounded_malformed_and_non_private_inputs_without_echoing(self):
        invalid = [b'x' * (benchmark.MAX_INPUT + 1), b'{"current":NaN}', b'{"db":"private","db":"duplicate"}',
                   self.request(samples=True), self.request(samples=32), self.request(db=str(ROOT / 'CODEX_TASK.md')),
                   self.request(current=dict(self.current, other=self.private_marker))]
        for raw in invalid:
            result = benchmark.run(raw)
            self.assertEqual(result['failure'], 'PRIVATE_BENCHMARK_INPUT_INVALID')
            self.assertFalse(result['succeeded'])
            self.assertNotIn(self.private_marker, json.dumps(result))
        os.chmod(self.root, 0o755)
        self.assertEqual(benchmark.run(self.request())['failure'], 'PRIVATE_BENCHMARK_INPUT_INVALID')
        os.chmod(self.root, 0o700)

    def test_no_consent_exits_before_input_or_database_access(self):
        child = subprocess.run([sys.executable, str(ROOT / 'scripts/benchmark-private-mail.py')],
                               input=self.request(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(child.returncode, 64)
        self.assertEqual(child.stderr, b'')
        self.assertEqual(json.loads(child.stdout)['failure'], 'PRIVATE_BENCHMARK_CONSENT_REQUIRED')
        self.assertNotIn(self.private_marker.encode(), child.stdout)

    def test_private_operation_exception_is_fixed_not_raw(self):
        with patch.object(benchmark.Archive, 'related_candidates', side_effect=ValueError(self.private_marker)):
            result = benchmark.run(self.request())
        related = next(row for row in result['operations'] if row['operation'] == 'related')
        self.assertFalse(related['succeeded'])
        self.assertEqual(related['failure'], 'LOCAL_OPERATION_FAILED')
        self.assertNotIn(self.private_marker, json.dumps(result))

    def test_malformed_private_metric_cannot_be_serialized_as_text(self):
        db = sqlite3.connect(self.path)
        try:
            db.execute('UPDATE mail_index_state SET metadata_count=? WHERE id=1', (self.private_marker,))
            db.commit()
        finally:
            db.close()
        result = benchmark.run(self.request())
        self.assertFalse(result['succeeded'])
        self.assertEqual(result['failure'], 'PRIVATE_BENCHMARK_INPUT_INVALID')
        self.assertNotIn(self.private_marker, json.dumps(result))


if __name__ == '__main__':
    unittest.main()
