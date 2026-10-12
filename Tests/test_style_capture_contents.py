"""Fictional text-only Sent capture; no native identity or Mail access."""
import copy
import json
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import ArchiveError, MAX_BODY, packed
from context import build_context
from main import dispatch
import style_capture
import style_corpus
import test_archive as fixtures
from test_style_capture import sent


_MISSING = object()


def contents(position=1, body=_MISSING, **changes):
    value = {'position': position, 'mailbox_path': ['Sent'],
             'sender': 'Operator <operator@fixture.invalid>',
             'body': body if body is not _MISSING else f'Thank you for your message.\n\nPlease check fictional item {position}.\n\nKind regards,'}
    value.update(changes)
    return value


class SentContentsCaptureTests(unittest.TestCase):
    setUp = fixtures.ArchiveTests.setUp
    tearDown = fixtures.ArchiveTests.tearDown

    def start(self, **changes):
        self.capture = style_capture.StyleCapture(self.a)
        arguments = {'account_id': 'fixture', 'selected_address': 'operator@fixture.invalid',
                     'own_addresses': ['operator@fixture.invalid', 'alias@fixture.invalid'],
                     'author_confirmed': True, 'restart': False}
        arguments.update(changes)
        return self.capture.start(**arguments)

    def arguments(self, state, records, **changes):
        arguments = {'capture_id': state['capture_id'], 'expected_checkpoint': state['checkpoint'],
                     'checkpoint': {'collection_mode': 'sent_contents', 'offset': state['pages']+1},
                     'records': records, 'candidates_checked': len(records)}
        arguments.update(changes)
        return arguments

    def page(self, state, records, **changes):
        return self.capture.content_page(**self.arguments(state, records, **changes))

    def rows(self):
        return [dict(row) for row in self.a.db.execute('SELECT * FROM style_capture_samples ORDER BY sequence')]

    def test_content_capture_never_invokes_native_record_parser_or_fabricates_metadata(self):
        state = self.start()
        revision = self.a.revision()
        with patch.object(self.a.mail_index, '_prepare_record', side_effect=AssertionError('native parser used')):
            state = self.page(state, [contents(1), contents(2)])
        self.assertEqual(self.a.revision(), revision)
        self.assertEqual(state['coverage']['strategy'], 'bounded_sent_contents')
        self.assertEqual(self.a.db.execute('SELECT count(*) FROM messages').fetchone()[0], 0)
        self.capture.finish(state['capture_id'], source_exhausted=True)
        summary = self.capture.extract(state['capture_id'])
        self.assertEqual(summary['example_count'], 2)
        self.assertEqual(summary['sample_info']['source_verifications'], 0)
        self.assertEqual(summary['sample_info']['snapshot_hash_verifications'], 2)
        self.assertEqual(summary['sample_info']['coverage']['identity_verification'], 'not_performed')
        messages = self.a.selected_style_messages()
        self.assertEqual(len(messages), 2)
        for value in messages:
            self.assertEqual(value['identity_verification'], 'not_performed')
            self.assertTrue(value['snapshot_hash_verified'])
            self.assertFalse(value['live_verified'])
            self.assertFalse(value['range_verified'])
            self.assertFalse(value['snapshot']['position_is_native_identity'])
            self.assertFalse(value['snapshot']['headers_fetched'])
            self.assertEqual(value['snapshot']['collection_mode'], 'sent_contents')
            for absent in ('native_id', 'message_id', 'subject', 'date', 'date_sent', 'date_received',
                           'attachment_count', 'attachments', 'references', 'message_size'):
                self.assertNotIn(absent, value)
        context = build_context(self.a, {'id': 'fictional', 'messageID': 'incoming@fixture.invalid',
                                       'subject': 'Fictional', 'body': 'Please reply.'})
        self.assertEqual(len(context['style_examples']), 2)
        self.assertEqual(self.a.style_summary(verify=True), summary)

    def test_exact_page_retry_is_read_only_and_changed_retry_is_rejected(self):
        state = self.start()
        arguments = self.arguments(state, [contents(1)], candidates_checked=5)
        first = self.capture.content_page(**arguments)
        before = self.rows()
        self.assertEqual(self.capture.content_page(**arguments), first)
        self.assertEqual(self.rows(), before)
        changed = copy.deepcopy(arguments)
        changed['records'][0]['body'] += '\nChanged.'
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_RETRY_CHANGED'):
            self.capture.content_page(**changed)
        self.assertEqual(self.capture.status(), first)

    def test_cancel_and_resume_preserve_capture_samples_and_counts(self):
        state = self.start()
        state = self.page(state, [contents(1), contents(2)])
        before = self.rows()
        self.capture.finish(state['capture_id'], status='cancelled')
        resumed = self.start()
        self.assertEqual(resumed['capture_id'], state['capture_id'])
        self.assertEqual(resumed['checkpoint'], state['checkpoint'])
        self.assertEqual(resumed['counts'], state['counts'])
        self.assertEqual(self.rows(), before)
        resumed = self.page(resumed, [contents(3)])
        self.assertEqual(resumed['counts']['captured'], 3)
        self.capture.finish(resumed['capture_id'])
        self.assertEqual(self.capture.extract(resumed['capture_id'])['example_count'], 3)

    def test_same_body_other_positions_or_mailbox_are_deduplicated(self):
        state = self.start()
        body = 'Please check the fictional report.'
        state = self.page(state, [contents(1, body), contents(2, body), contents(1, body, mailbox_path=['Sent', 'Other'])])
        self.assertEqual(state['counts']['records_received'], 3)
        self.assertEqual(state['counts']['captured'], 1)
        self.assertEqual(state['skipped']['duplicate'], 2)

    def test_slot_changed_or_duplicated_in_one_page_rejects_atomically(self):
        state = self.start()
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_DUPLICATE_RECORD'):
            self.page(state, [contents(1), contents(1)])
        state = self.page(state, [contents(1)])
        before = self.rows()
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_SOURCE_CHANGED'):
            self.page(state, [contents(2), contents(1, body='Changed fictional text.')])
        self.assertEqual(self.rows(), before)
        self.assertEqual(self.capture.status(), state)

    def test_exact_selected_sender_required_without_shared_or_unconfirmed_capture(self):
        for sender in ('alias@fixture.invalid', 'other@fixture.invalid',
                       'operator@fixture.invalid, other@fixture.invalid', 'operator@fixture.invalid\nInjected: yes'):
            with self.subTest(sender=sender):
                state = self.start(restart=True)
                with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_WRONG_ADDRESS'):
                    self.page(state, [contents(sender=sender)])
                self.assertEqual(self.capture.status()['counts']['captured'], 0)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_PERSONAL_ADDRESS_REQUIRED'):
            self.start(shared_addresses=['operator@fixture.invalid'])
        with self.assertRaisesRegex(ArchiveError, 'STYLE_SENT_AUTHOR_REQUIRED'):
            self.start(author_confirmed=False)

    def test_body_null_is_unavailable_and_timeout_code_does_not_poison_siblings(self):
        state = self.start()
        state = self.page(state, [contents(1), contents(2, body=None, nativeCode=-1712),
                                  contents(3, body=None, nativeCode=-1708)])
        self.assertEqual(state['counts']['captured'], 1)
        self.assertEqual(state['skipped']['source_unavailable'], 2)

    def test_empty_and_quote_only_bodies_are_excluded(self):
        state = self.start()
        state = self.page(state, [contents(1, body=''), contents(2, body='> Fictional quoted reply.')])
        self.assertEqual(state['counts']['captured'], 0)
        self.assertEqual(state['skipped']['empty'], 2)

    def test_complete_budget_is_kept_without_truncation(self):
        state = self.start(token_budget=64)
        state = self.page(state, [contents(1, body='a'*33), contents(2, body='b'*32)])
        self.assertEqual(state['counts']['token_estimate'], 64)
        self.assertEqual(state['counts']['captured'], 1)
        self.assertEqual(state['skipped']['over_budget'], 1)
        self.assertEqual(json.loads(self.rows()[0]['payload'])['body_text'], 'b'*32)

    def test_native_and_content_journals_cannot_mix(self):
        state = self.start()
        state = self.capture.page(state['capture_id'], None, {'page': 1}, [sent(1)], 1)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_SOURCE_CHANGED'):
            self.page(state, [contents(2)])
        state = self.start(restart=True)
        state = self.page(state, [contents(1)])
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_SOURCE_CHANGED'):
            self.capture.page(state['capture_id'], state['checkpoint'], {'page': 2}, [sent(2)], 1)

    def test_published_extract_retry_keeps_result_and_revision(self):
        state = self.start()
        state = self.page(state, [contents(1)], done=True)
        self.capture.finish(state['capture_id'])
        result = self.capture.extract(state['capture_id'])
        revision = self.a.revision()
        self.assertEqual(self.capture.extract(state['capture_id']), result)
        self.assertEqual(self.a.revision(), revision)
        self.assertEqual(len(self.rows()), 1)

    def test_private_content_checksum_changes_fail_resume_without_mail_calls(self):
        for field, value in (('position', 7), ('mailbox_path', ['Other']),
                             ('identity_verification', 'verified'), ('from', 'Changed <operator@fixture.invalid>')):
            with self.subTest(field=field):
                state = self.start(restart=True)
                state = self.page(state, [contents(1)])
                self.capture.finish(state['capture_id'], status='cancelled')
                row = self.rows()[0]
                payload = json.loads(row['payload'])
                payload[field] = value
                with self.a.db:
                    self.a.db.execute('UPDATE style_capture_samples SET payload=? WHERE message_id=?',
                                      (packed(payload), row['message_id']))
                with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_JOURNAL_CHANGED'):
                    self.start()

    def test_content_command_dispatch_and_required_fields(self):
        state = self.start()
        request = dict(db=str(self.root / 'state' / 'db.sqlite'), command='style_capture_content_page',
                       **self.arguments(state, [contents(1)]))
        result = dispatch(request)
        self.assertEqual(result['counts']['captured'], 1)
        with self.assertRaisesRegex(ArchiveError, 'IPC_REQUEST_INVALID'):
            dispatch(dict(db=str(self.root / 'state' / 'db.sqlite'), command='style_capture_content_page',
                          capture_id=state['capture_id']))

    def test_record_shapes_and_fabricated_native_fields_are_rejected(self):
        malformed = ({'position': 0}, {'position': True}, {'position': 2**31}, {'mailbox_path': []},
                     {'mailbox_path': ['']}, {'mailbox_path': ['x'*16_385]}, {'mailbox_path': ['Sent']*33},
                     {'body': 1}, {'nativeCode': -1728}, {'nativeCode': True}, {'nativeCode': -1712},
                     {'nativeID': 'fictional'}, {'subject': 'fabricated'}, {'date': '2026-10-12'},
                     {'attachmentCount': 0}, {'accountID': 'other'})
        for changes in malformed:
            with self.subTest(changes=changes):
                state = self.start(restart=True)
                with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_RECORD_INVALID'):
                    self.page(state, [contents(**changes)])
                self.assertEqual(self.capture.status()['counts']['captured'], 0)

    def test_body_and_aggregate_byte_limits_are_fail_closed(self):
        state = self.start()
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_INPUT_LIMIT'):
            self.page(state, [contents(body='x'*(MAX_BODY+1))])
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_INPUT_LIMIT'):
            self.page(state, [contents(index, 'あ'*MAX_BODY) for index in range(1, 4)])
        self.assertEqual(self.capture.status()['counts']['captured'], 0)

    def test_content_collection_has_zero_native_identity_work_and_bounded_local_operations(self):
        measurements = []
        for total in (64, 256, 600):
            state = self.start(restart=True, token_budget=131_072)
            operations = []
            self.a.db.set_trace_callback(operations.append)
            began = time.perf_counter()
            try:
                with patch.object(self.a.mail_index, '_prepare_record',
                                  side_effect=AssertionError('native identity parser used')) as native:
                    for first in range(1, total+1, 20):
                        state = self.page(state, [contents(position) for position in range(first, min(first+20, total+1))])
                    self.capture.finish(state['capture_id'], source_exhausted=True)
                    result = self.capture.extract(state['capture_id'])
                    self.assertEqual(native.call_count, 0)
            finally:
                self.a.db.set_trace_callback(None)
            accepted = min(total, style_corpus.MAX_SAMPLES)
            self.assertEqual(result['example_count'], accepted)
            self.assertEqual(result['sample_info']['source_verifications'], 0)
            self.assertEqual(result['sample_info']['snapshot_hash_verifications'], accepted)
            # Every acquired record performs fixed point/dedup writes; local
            # analysis is capped at 512 snapshots, with no archive scan.
            self.assertLessEqual(len(operations), 10*total+100)
            measurements.append({'candidates': total, 'retained_samples': accepted,
                                 'native_identity_operations': 0, 'local_sql_operations': len(operations),
                                 'wall_seconds': time.perf_counter()-began})
        print('FICTIONAL_CONTENT_COLLECTION_BOUNDS', packed(measurements))


if __name__ == '__main__':
    unittest.main()
