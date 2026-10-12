"""Private prior-snapshot cache contracts, using only .invalid fixtures."""
import json
import os
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive, ArchiveError
from main import dispatch, process_request
import mail_body_cache as cache_module
from mail_body_cache import MailBodyCache
import test_archive as fixtures


def record(number=1, **changes):
    result = {'accountID': 'account@fixture.invalid', 'mailboxPath': ['Archive', 'Sent'],
              'nativeID': str(number), 'messageID': f'{number}@fixture.invalid',
              'subject': 'Fictional sent message', 'sender': 'Owner <owner@fixture.invalid>',
              'dateSent': '2026-10-12T00:00:00Z', 'dateReceived': '2026-10-12T00:00:01Z',
              'messageSize': 1024, 'role': 'sent', 'isLocal': False,
              'scanID': 'fixture-scan.invalid', 'body': f'Fictional complete body {number}.',
              'headers': f'Message-ID: <{number}@fixture.invalid>\nReferences: <prior@fixture.invalid>\n',
              'attachmentCount': 0, 'bodyStatus': 'captured'}
    result.update(changes)
    return result


def locator(value):
    return {key: item for key, item in value.items() if key in cache_module.LOCATOR_FIELDS}


class MailBodyCacheTests(unittest.TestCase):
    setUp = fixtures.ArchiveTests.setUp
    tearDown = fixtures.ArchiveTests.tearDown

    def cache(self):
        return MailBodyCache(self.a)

    def global_snapshot(self):
        tables = ('mail_index_state', 'mail_index_mailboxes', 'mail_index_catalog',
                  'mail_index_versions', 'messages', 'search', 'locations', 'sources',
                  'style_profiles', 'style_corpus_profile')
        return {name: [tuple(row) for row in self.a.db.execute('SELECT * FROM '+name)] for name in tables}

    def assert_totals(self):
        actual = tuple(self.a.db.execute('SELECT count(*),coalesce(sum(payload_bytes),0) FROM mail_body_cache').fetchone())
        tracked = tuple(self.a.db.execute('SELECT entries,payload_bytes FROM mail_body_cache_totals WHERE id=1').fetchone())
        self.assertEqual(actual, tracked)
        self.assertLessEqual(actual[0], cache_module.MAX_ENTRIES)
        self.assertLessEqual(actual[1], cache_module.MAX_BYTES)

    def test_hit_is_prior_snapshot_scan_rebound_ordered_and_not_live(self):
        cache = self.cache()
        before, revision = self.global_snapshot(), self.a.revision()
        originals = [record(1), record(2)]
        saved = cache.store(originals)
        self.assertEqual((saved['stored'], saved['skipped'], saved['entries']), (2, 0, 2))
        request = [locator(record(2, scanID='next-scan.invalid')),
                   locator(record(3)), locator(record(1, scanID='next-scan.invalid'))]
        result = cache.lookup(request)
        self.assertEqual((result['hits'], result['misses']), (2, 1))
        self.assertIsNone(result['slots'][1])
        for index, original in ((0, originals[1]), (2, originals[0])):
            value = result['slots'][index]
            self.assertEqual(value['body'], original['body'])
            self.assertEqual(value['headers'], original['headers'])
            self.assertEqual(value['scanID'], 'next-scan.invalid')
            self.assertEqual(value['snapshotOrigin'], cache_module.ORIGIN)
            self.assertTrue(value['snapshotHashVerified'])
            self.assertFalse(value['liveVerified'])
            self.assertIn('cachedAt', value)
            self.assertFalse(any('hash' in key.lower() for key in value if key != 'snapshotHashVerified'))
        self.assertEqual(before, self.global_snapshot())
        self.assertEqual(revision, self.a.revision())
        self.assert_totals()

    def test_metadata_fingerprint_changes_miss_instead_of_reusing_other_content(self):
        changes = ({'subject': 'Changed fictional subject'}, {'sender': 'other@fixture.invalid'},
                   {'messageID': 'changed@fixture.invalid'}, {'messageSize': 2048},
                   {'dateSent': '2026-10-13T00:00:00Z'}, {'dateReceived': None},
                   {'role': 'draft'}, {'mailboxPath': ['Other', 'Sent']},
                   {'accountID': 'other@fixture.invalid'}, {'nativeID': '2'},
                   {'accountID': '__harborreply_local__', 'isLocal': True})
        for change in changes:
            with self.subTest(fields=sorted(change)):
                cache = self.cache()
                cache.store([record()])
                result = cache.lookup([locator(record(**change))])
                self.assertEqual(result, {'slots': [None], 'hits': 0, 'misses': 1})
                self.assert_totals()

    def test_equal_date_instants_and_new_scan_id_reuse_without_refreshing_ttl(self):
        cache = self.cache()
        with patch.object(cache_module.time, 'time', return_value=1_000_000.0):
            cache.store([record()])
        with patch.object(cache_module.time, 'time', return_value=1_000_100.0):
            hit = cache.lookup([locator(record(dateSent='2026-10-12T09:00:00+09:00', scanID='new.invalid'))])
        self.assertEqual(hit['hits'], 1)
        row = self.a.db.execute('SELECT captured_at,expires_at,last_accessed FROM mail_body_cache').fetchone()
        self.assertEqual(tuple(row), (1_000_000.0, 1_000_000.0+cache_module.TTL_SECONDS, 1_000_100.0))
        with patch.object(cache_module.time, 'time', return_value=1_000_000.0+cache_module.TTL_SECONDS):
            self.assertEqual(cache.lookup([locator(record())])['hits'], 0)
        self.assert_totals()
        self.assertEqual(self.a.db.execute('SELECT count(*) FROM mail_body_cache').fetchone()[0], 0)

    def test_future_capture_clock_and_invalid_expiry_fail_closed(self):
        cache = self.cache()
        for updates in ({'captured_at': time.time()+3600}, {'expires_at': time.time()+7200}):
            cache.store([record()])
            with self.a.db:
                for field, value in updates.items():
                    self.a.db.execute('UPDATE mail_body_cache SET '+field+'=?', (value,))
            self.assertEqual(cache.lookup([locator(record())])['hits'], 0)
            self.assert_totals()

    def test_payload_metadata_body_headers_and_hash_corruption_are_misses(self):
        cache = self.cache()
        changes = ({'payload': '{broken fictional json'},
                   {'payload': json.dumps(record(body='Changed fictional body.'))},
                   {'payload': json.dumps(record(headers='Changed fictional headers.'))},
                   {'payload_hash': 'invalid'}, {'body_hash': 'invalid'},
                   {'headers_hash': 'invalid'}, {'fingerprint': 'invalid'})
        for change in changes:
            with self.subTest(column=next(iter(change))):
                cache.store([record()])
                with self.a.db:
                    for field, value in change.items():
                        self.a.db.execute('UPDATE mail_body_cache SET '+field+'=?', (value,))
                self.assertEqual(cache.lookup([locator(record())]), {'slots': [None], 'hits': 0, 'misses': 1})
                self.assert_totals()

    def test_oversized_corrupt_value_is_not_loaded_or_returned(self):
        cache = self.cache()
        cache.store([record()])
        with self.a.db:
            self.a.db.execute('UPDATE mail_body_cache SET payload=?', ('X'*(cache_module.MAX_RECORD_BYTES+1),))
        self.assertEqual(cache.lookup([locator(record())])['hits'], 0)
        self.assert_totals()

    def test_invalid_records_reject_entire_batch_before_cache_writes(self):
        cache = self.cache()
        wrong = (record(nativeID='not-native.invalid'), record(nativeID='0'), record(nativeID='9'*30),
                 record(scanID=''), record(accountID=''), record(isLocal=True),
                 record(messageSize=True), record(mailboxPath=[]), record(mailboxPath=['']),
                 record(dateSent='not-a-date.invalid'), record(dateReceived=True),
                 record(role='inbox'), record(body=12), record(headers=12),
                 record(attachmentCount=True), record(snapshotOrigin=cache_module.ORIGIN))
        for value in wrong:
            with self.subTest(field_types=tuple(type(x).__name__ for x in value.values())):
                with self.assertRaises(ArchiveError):
                    cache.store([record(2), value])
                self.assertEqual(self.a.db.execute('SELECT count(*) FROM mail_body_cache').fetchone()[0], 0)
        missing = record()
        del missing['headers']
        with self.assertRaises(ArchiveError): cache.store([missing])
        self.assert_totals()

    def test_only_complete_captured_records_are_retained_and_no_reuse_timestamp_relabel(self):
        cache = self.cache()
        unavailable = record(2, bodyStatus='unreadable', failure='MAIL_INDEX_READ_UNAVAILABLE')
        saved = cache.store([record(), unavailable, record(3, bodyStatus='too_large')])
        self.assertEqual((saved['stored'], saved['skipped']), (1, 2))
        response = cache.lookup([locator(record()), locator(record(2))])
        with self.assertRaisesRegex(ArchiveError, 'MAIL_BODY_CACHE_RECORD_INVALID'):
            cache.store([response['slots'][0]])
        self.assert_totals()

    def test_duplicate_batch_and_input_byte_caps_are_explicit(self):
        cache = self.cache()
        for call, values in ((cache.store, [record()]*2), (cache.lookup, [locator(record())]*2)):
            with self.assertRaisesRegex(ArchiveError, 'MAIL_BODY_CACHE_DUPLICATE_RECORD'):
                call(values)
        with self.assertRaisesRegex(ArchiveError, 'MAIL_BODY_CACHE_BATCH_LIMIT'):
            cache.store([record(i+1) for i in range(21)])
        with self.assertRaisesRegex(ArchiveError, 'MAIL_BODY_CACHE_BATCH_LIMIT'):
            cache.lookup([locator(record(i+1)) for i in range(21)])
        with self.assertRaisesRegex(ArchiveError, 'MAIL_BODY_CACHE_INPUT_LIMIT'):
            cache.store([record(i+1, body='あ'*200_000) for i in range(3)])
        self.assertEqual(cache.lookup([]), {'slots': [], 'hits': 0, 'misses': 0})
        self.assert_totals()

    def test_lookup_response_bytes_are_capped_without_deleting_valid_excess_hits(self):
        cache = self.cache()
        values = [record(i+1, body='あ'*200_000) for i in range(3)]
        for value in values: cache.store([value])
        result = cache.lookup([locator(value) for value in values])
        self.assertEqual((result['hits'], result['misses']), (2, 1))
        self.assertLessEqual(len(cache_module.canonical_json(result).encode()), cache_module.MAX_REQUEST_BYTES)
        self.assertLessEqual(len(json.dumps({'ok': True, 'result': result}, ensure_ascii=False).encode()),
                             cache_module.MAX_REQUEST_BYTES)
        self.assertIsNone(result['slots'][2])
        self.assertEqual(cache.lookup([locator(values[2])])['hits'], 1)
        self.assert_totals()

    def test_count_bound_and_recency_eviction_use_indexed_order(self):
        cache = self.cache()
        stamp = 1_000_000.0
        for first in range(1, 513, 20):
            with patch.object(cache_module.time, 'time', return_value=stamp+first):
                cache.store([record(i) for i in range(first, min(first+20, 513))])
        with patch.object(cache_module.time, 'time', return_value=stamp+600):
            self.assertEqual(cache.lookup([locator(record(1))])['hits'], 1)
        with patch.object(cache_module.time, 'time', return_value=stamp+601):
            saved = cache.store([record(513)])
        self.assertEqual((saved['entries'], saved['evicted']), (512, 1))
        with patch.object(cache_module.time, 'time', return_value=stamp+602):
            # Same-batch timestamps tie; the fixed textual-native-ID order
            # makes ID 10 the oldest after ID 1 is touched.
            result = cache.lookup([locator(record(1)), locator(record(10)), locator(record(513))])
        self.assertEqual([value is not None for value in result['slots']], [True, False, True])
        plan = [row[3] for row in self.a.db.execute('''EXPLAIN QUERY PLAN SELECT account_id,mailbox_path,native_id,payload_bytes
                  FROM mail_body_cache ORDER BY last_accessed,account_id,mailbox_path,native_id LIMIT 1''')]
        self.assertTrue(any('mail_body_cache_eviction' in item for item in plan))
        self.assertFalse(any('TEMP B-TREE' in item for item in plan))
        self.assert_totals()

    def test_byte_bound_replacement_and_expiry_have_consistent_totals(self):
        cache = self.cache()
        with patch.object(cache_module, 'MAX_BYTES', 8_000):
            saved = cache.store([record(i+1, body='Fictional.'*80) for i in range(20)])
            self.assertGreater(saved['evicted'], 0)
            self.assertLessEqual(saved['payloadBytes'], 8_000)
            cache.store([record(20, body='Fictional replacement.')])
            self.assert_totals()
            with patch.object(cache_module.time, 'time', return_value=time.time()+cache_module.TTL_SECONDS+1):
                expired = cache.store([])
            self.assertEqual((expired['entries'], expired['payloadBytes']), (0, 0))
            self.assertGreater(expired['evicted'], 0)
            self.assert_totals()

    def test_cache_survives_worker_reopen_in_private_database_only(self):
        database = self.root/'state'/'db.sqlite'
        response = dispatch({'db': str(database), 'command': 'mail_body_cache_store', 'records': [record()]})
        self.assertEqual(response['stored'], 1)
        reopened = dispatch({'db': str(database), 'command': 'mail_body_cache_lookup', 'locators': [locator(record(scanID='reopened.invalid'))]})
        self.assertEqual(reopened['hits'], 1)
        self.assertEqual(reopened['slots'][0]['scanID'], 'reopened.invalid')
        self.assertEqual(os.stat(database.parent).st_mode & 0o777, 0o700)
        for path in database.parent.iterdir():
            self.assertTrue(path.is_file())
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertFalse((database.parent/'mail-snapshots').exists())

    def test_worker_required_fields_and_failures_never_echo_input(self):
        database = self.root/'state'/'db.sqlite'
        for command in ('mail_body_cache_lookup', 'mail_body_cache_store'):
            value = process_request(json.dumps({'db': str(database), 'command': command}).encode())
            self.assertEqual(value, {'ok': False, 'error': 'IPC_REQUEST_INVALID'})
        value = process_request(json.dumps({'db': str(database), 'command': 'mail_body_cache_store',
                                           'records': [record(nativeID='private-body@fixture.invalid')]}).encode())
        self.assertEqual(value, {'ok': False, 'error': 'MAIL_BODY_CACHE_RECORD_INVALID'})
        self.assertNotIn('private-body', json.dumps(value))

    def test_synthetic_scaling_has_indexed_lookup_and_bounded_vm_operations(self):
        measurements = []
        cache = self.cache()
        for count in (16, 128, 512):
            existing = self.a.db.execute('SELECT entries FROM mail_body_cache_totals').fetchone()[0]
            for first in range(existing+1, count+1, 20):
                cache.store([record(i) for i in range(first, min(first+20, count+1))])
            query = 'SELECT payload FROM mail_body_cache WHERE account_id=? AND mailbox_path=? AND native_id=?'
            key = ('account@fixture.invalid', '["Archive","Sent"]', str(count))
            plan = [row[3] for row in self.a.db.execute('EXPLAIN QUERY PLAN '+query, key)]
            self.assertTrue(any('SEARCH mail_body_cache USING INDEX' in item for item in plan))
            self.assertFalse(any('SCAN mail_body_cache' in item for item in plan))
            steps = []
            self.a.db.set_progress_handler(lambda: steps.append(1) or 0, 1)
            started = time.perf_counter()
            try:
                result = cache.lookup([locator(record(count)), locator(record(count+1))])
            finally:
                elapsed = time.perf_counter()-started
                self.a.db.set_progress_handler(self.a._sql_progress, 100)
            self.assertEqual((result['hits'], result['misses']), (1, 1))
            measurements.append({'entries': count, 'requested': 2, 'hits': 1, 'sql_vm_steps': len(steps),
                                 'wall_seconds': elapsed, 'payload_bytes': self.a.db.execute('SELECT payload_bytes FROM mail_body_cache_totals').fetchone()[0]})
            self.assertLess(len(steps), 250)
        self.assertLessEqual(measurements[-1]['sql_vm_steps'], measurements[0]['sql_vm_steps']+40)
        print('SYNTHETIC_MAIL_BODY_CACHE_SCALING '+json.dumps(measurements, separators=(',', ':')))


if __name__ == '__main__':
    unittest.main()
