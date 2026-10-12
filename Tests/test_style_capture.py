"""Fictional address-scoped Sent snapshots, budgets and cancellation races."""
import copy
import json
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive, ArchiveError, packed
from context import build_context
from main import dispatch
import style_capture
import style_corpus
import test_archive as fixtures


def sent(number=0, body=None, **changes):
    record = {'accountID': 'fixture', 'mailboxPath': ['Sent'], 'nativeID': str(number),
              'messageID': f'style{number}@fixture.invalid', 'subject': 'Fictional Sent',
              'sender': 'Operator <operator@fixture.invalid>', 'dateSent': '2026-10-10T00:00:00+00:00',
              'direction': 'sent', 'isLocal': False, 'messageSize': 128, 'attachmentCount': 0,
              'body': body if body is not None else f'Thank you for your message.\n\nPlease check fictional item {number}.\n\nKind regards,',
              'bodyStatus': 'captured'}
    record.update(changes)
    return record


class StyleCaptureTests(unittest.TestCase):
    setUp = fixtures.ArchiveTests.setUp
    tearDown = fixtures.ArchiveTests.tearDown

    def start(self, **changes):
        self.capture = style_capture.StyleCapture(self.a)
        arguments = {'account_id': 'fixture', 'selected_address': 'operator@fixture.invalid',
                     'own_addresses': ['operator@fixture.invalid', 'alias@fixture.invalid'],
                     'author_confirmed': True}
        arguments.update(changes)
        return self.capture.start(**arguments)

    def page(self, state, records, checked=None, **changes):
        arguments = {'capture_id': state['capture_id'], 'expected_checkpoint': state['checkpoint'],
                     'checkpoint': {'sequence': state['pages']+1}, 'records': records,
                     'candidates_checked': len(records) if checked is None else checked}
        arguments.update(changes)
        return self.capture.page(**arguments)

    def publish(self, count=6, **changes):
        state = self.start(**changes)
        for first in range(0, count, 20):
            state = self.page(state, [sent(i) for i in range(first, min(first+20, count))])
        self.capture.finish(state['capture_id'], source_exhausted=True)
        return state, self.capture.extract(state['capture_id'])

    def global_snapshot(self):
        tables = ('mail_index_state', 'mail_index_mailboxes', 'mail_index_catalog',
                  'mail_index_versions', 'messages', 'search', 'locations', 'sources')
        return {table: [tuple(row) for row in self.a.db.execute('SELECT * FROM '+table)] for table in tables}

    def test_extract_without_global_index_keeps_index_and_search_untouched(self):
        before = self.global_snapshot()
        revision = self.a.revision()
        state = self.start()
        state = self.page(state, [sent(i) for i in range(12)], checked=128)
        self.assertEqual(before, self.global_snapshot())
        self.assertEqual(self.a.revision(), revision)
        self.assertIsNone(style_corpus.summary(self.a))
        self.capture.finish(state['capture_id'], source_exhausted=True)
        result = self.capture.extract(state['capture_id'])
        self.assertEqual(result['example_count'], 12)
        self.assertEqual(before, self.global_snapshot())
        self.assertGreater(self.a.revision(), revision)
        self.assertEqual(result['sample_info']['coverage']['scope'], 'selected_address_native_sent')
        self.assertEqual(result['sample_info']['coverage']['strategy'], 'bounded_mail_order')
        self.assertEqual(result['source_address'], 'operator@fixture.invalid')
        self.assertEqual(result['source_account_id'], 'fixture')
        self.assertEqual(result['description_origin'], 'observed_format_traits')
        self.assertEqual(result['source_phrases'], ['Thank you for your message.', 'Kind regards,'])
        self.assertNotIn('examples', result)
        self.assertNotIn('example_origin', result)
        self.assertNotIn('合成例', result['description'])
        self.assertNotIn('[recipient]', result['description'])
        self.assertTrue(result['sample_info']['coverage']['candidate_window_exhausted'])
        examples = self.a.selected_style_messages()
        self.assertEqual(len(examples), 3)
        self.assertEqual(self.a.style_summary(verify=True), result)
        self.assertTrue(all(m['snapshot_hash_verified'] and not m['range_verified'] and not m['live_verified']
                            and m['origin'] == style_capture.ORIGIN for m in examples))
        context = build_context(self.a, {'id': 'fictional', 'messageID': 'new@fixture.invalid',
                                       'body': 'Please reply.', 'subject': 'Fictional'})
        self.assertEqual(context['style_summary']['example_count'], 12)
        self.assertEqual(len(context['style_examples']), 3)

    def test_selected_alias_only_and_strict_sent_account_are_required(self):
        for change, error in (({'accountID': 'other'}, 'STYLE_CAPTURE_WRONG_ACCOUNT'),
                              ({'direction': 'received'}, 'STYLE_CAPTURE_SENT_REQUIRED'),
                              ({'direction': 'draft'}, 'STYLE_CAPTURE_SENT_REQUIRED'),
                              ({'direction': 'unknown'}, 'STYLE_CAPTURE_SENT_REQUIRED'),
                              ({'isLocal': True}, 'STYLE_CAPTURE_SENT_REQUIRED'),
                              ({'sender': 'alias@fixture.invalid'}, 'STYLE_CAPTURE_WRONG_ADDRESS'),
                              ({'sender': 'operator@fixture.invalid, other@fixture.invalid'}, 'STYLE_CAPTURE_WRONG_ADDRESS')):
            with self.subTest(change=change):
                state = self.start()
                with self.assertRaisesRegex(ArchiveError, error):
                    self.page(state, [sent(**change)])
                self.assertEqual(self.capture.status()['counts']['captured'], 0)
        state = self.start(selected_address='alias@fixture.invalid')
        state = self.page(state, [sent(sender='Alias <alias@fixture.invalid>')])
        self.capture.finish(state['capture_id'])
        self.assertEqual(self.capture.extract(state['capture_id'])['example_count'], 1)
        author = json.loads(self.a.db.execute('SELECT author FROM style_corpus_profile').fetchone()[0])
        self.assertEqual(author['own_addresses'], ['alias@fixture.invalid'])

    def test_address_selection_is_confirmation_and_shared_addresses_are_excluded(self):
        for confirmed in (False, 1, 'true', None):
            with self.subTest(confirmed=confirmed), self.assertRaisesRegex(ArchiveError, 'STYLE_SENT_AUTHOR_REQUIRED'):
                self.start(author_confirmed=confirmed)
        for change in ({'selected_address': 'outside@fixture.invalid'},
                       {'shared_addresses': ['operator@fixture.invalid']},
                       {'selected_address': 'operator@fixture.invalid\nInjected: true'}):
            with self.subTest(change=change), self.assertRaisesRegex(ArchiveError, 'STYLE_PERSONAL_ADDRESS_REQUIRED'):
                self.start(**change)
        aliases = [f'alias{i}@fixture.invalid' for i in range(31)] + ['operator@fixture.invalid']
        self.assertEqual(self.start(own_addresses=aliases)['address'], 'operator@fixture.invalid')

    def test_quotes_duplicates_and_old_facts_are_excluded_from_retained_text(self):
        state = self.start()
        english = 'Thank you for your message.\n\nPlease check the fictional report.\n\nKind regards,'
        japanese = 'お世話になっております。\n\n架空の資料をご確認ください。\n\nよろしくお願いいたします。'
        state = self.page(state, [sent(0, english+'\n\n> OLD-FICTIONAL-FACT 999'),
                                  sent(1, english+'\n\n> OTHER-FICTIONAL-FACT 888'),
                                  sent(2, '> Received quote only.'), sent(3, japanese)])
        self.assertEqual(state['counts']['captured'], 2)
        self.assertEqual(state['skipped']['duplicate'], 1)
        self.assertEqual(state['skipped']['empty'], 1)
        stored = packed([json.loads(row[0]) for row in self.a.db.execute('SELECT payload FROM style_capture_samples')])
        self.assertNotIn('OLD-FICTIONAL-FACT', stored)
        self.assertNotIn('OTHER-FICTIONAL-FACT', stored)
        self.capture.finish(state['capture_id'])
        result = self.capture.extract(state['capture_id'])
        self.assertEqual(result['language'], 'Mixed')
        self.assertNotIn('999', packed(result))
        self.assertNotIn('888', packed(result))
        self.assertTrue(all(m['snapshot']['quoted_text_excluded'] for m in self.a.selected_style_messages()))

    def test_complete_utf8_budget_skips_large_samples_without_truncation(self):
        text = 'ご確認をお願いいたします。'
        budget = style_corpus.conservative_units(text)
        state = self.start(token_budget=budget)
        state = self.page(state, [sent(0, '架空の長文です。'*100), sent(1, text)])
        self.assertEqual(state['counts']['captured'], 1)
        self.assertEqual(state['counts']['token_estimate'], budget)
        self.assertEqual(state['skipped']['over_budget'], 1)
        self.assertTrue(state['budget_reached'])
        self.capture.finish(state['capture_id'])
        result = self.capture.extract(state['capture_id'])
        self.assertEqual(result['sample_info']['token_estimate'], budget)
        self.assertFalse(result['sample_info']['token_estimate_is_exact'])
        self.assertEqual(self.a.selected_style_messages()[0]['body_text'], text)
        state = self.start(token_budget=64)
        state = self.page(state, [sent(2, 'X'*200)])
        self.capture.finish(state['capture_id'])
        with self.assertRaisesRegex(ArchiveError, 'STYLE_INDEXED_SENT_EXAMPLES_REQUIRED'):
            self.capture.extract(state['capture_id'])
        self.assertEqual(self.a.style_summary(verify=True), result)

    def test_unfillable_framing_remainder_stops_and_preserves_retry_and_profile(self):
        text = 'X' * (4096 - style_corpus.SAMPLE_FRAMING_UNITS * 2)
        state = self.start(token_budget=4096)
        args = {'capture_id': state['capture_id'], 'expected_checkpoint': None,
                'checkpoint': {'sequence': 1}, 'records': [sent(0, text)],
                'candidates_checked': 128}
        state = self.capture.page(**args)
        self.assertEqual(4096 - state['counts']['token_estimate'], style_corpus.SAMPLE_FRAMING_UNITS)
        self.assertTrue(state['budget_reached'])
        self.assertTrue(state['should_stop'])
        self.assertEqual(state['stop_reason'], 'token_budget')
        self.assertEqual(self.capture.page(**args), state)
        self.assertEqual(state['counts']['captured'], 1)
        self.capture.finish(state['capture_id'], source_exhausted=False)
        result = self.capture.extract(state['capture_id'])
        self.assertEqual(result['sample_info']['token_estimate'], style_corpus.conservative_units(text))
        self.assertLess(result['sample_info']['token_estimate'], result['sample_info']['token_budget'])
        self.assertTrue(result['sample_info']['coverage']['selection_capped'])
        self.assertFalse(result['sample_info']['coverage']['candidate_window_exhausted'])
        stored = self.a.db.execute('SELECT message_id FROM style_capture_samples WHERE capture_id=?',
                                   (state['capture_id'],)).fetchone()[0]
        self.assertEqual(style_capture.message(self.a, stored)['body_text'], text)
        self.assertEqual(self.a.selected_style_messages(), [])  # Complete, but over the provider's 2KiB per-example cap.
        self.assertEqual(self.a.style_summary(verify=True), result)

    def test_exact_minimum_sample_remainder_continues_and_accepts_complete_shorter_text(self):
        text = 'X' * (4096 - style_corpus.SAMPLE_FRAMING_UNITS * 2 - 1)
        state = self.start(token_budget=4096)
        state = self.page(state, [sent(0, text)])
        self.assertEqual(4096 - state['counts']['token_estimate'], style_corpus.SAMPLE_FRAMING_UNITS + 1)
        self.assertFalse(state['budget_reached'])
        self.assertFalse(state['should_stop'])
        self.assertEqual(state['stop_reason'], '')
        state = self.page(state, [sent(1, 'ZZ'), sent(2, 'Y')])
        self.assertEqual(state['counts']['captured'], 2)
        self.assertEqual(state['counts']['token_estimate'], 4096)
        self.assertEqual(state['skipped']['over_budget'], 1)
        self.assertTrue(state['budget_reached'])
        self.capture.finish(state['capture_id'], source_exhausted=False)
        result = self.capture.extract(state['capture_id'])
        self.assertEqual(result['sample_info']['token_estimate'], 4096)
        stored = [style_capture.message(self.a, row[0])['body_text'] for row in self.a.db.execute(
            'SELECT message_id FROM style_capture_samples WHERE capture_id=? ORDER BY sequence', (state['capture_id'],))]
        self.assertEqual(stored, [text, 'Y'])
        self.assertEqual([m['body_text'] for m in self.a.selected_style_messages()], ['Y'])
        self.assertEqual(self.a.style_summary(verify=True), result)

    def test_metadata_cap_accepts_remaining_body_subchunks_with_zero_header_delta(self):
        state = self.start()
        for _ in range(31):
            state = self.page(state, [], checked=128)
        state = self.page(state, [sent(0)], checked=128)
        self.assertEqual(state['counts']['candidates_checked'], 4096)
        self.assertEqual(state['stop_reason'], 'candidate_limit')
        self.assertFalse(state['budget_reached'])
        state = self.page(state, [sent(1)], checked=0)
        self.assertEqual(state['counts']['captured'], 2)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_CANDIDATE_LIMIT'):
            self.page(state, [], checked=1)
        self.capture.finish(state['capture_id'], source_exhausted=False)
        result = self.capture.extract(state['capture_id'])
        self.assertTrue(result['sample_info']['coverage']['selection_capped'])
        self.assertFalse(result['sample_info']['coverage']['candidate_window_exhausted'])

    def test_checkpoint_retries_are_idempotent_and_changed_retry_fails(self):
        state = self.start()
        args = {'capture_id': state['capture_id'], 'expected_checkpoint': None,
                'checkpoint': {'sequence': 1}, 'records': [sent()], 'candidates_checked': 128}
        result = self.capture.page(**args)
        self.assertEqual(self.capture.page(**args), result)
        changed = copy.deepcopy(args)
        changed['records'][0]['body'] = 'A changed fictional body.'
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_RETRY_CHANGED'):
            self.capture.page(**changed)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_CHECKPOINT_CHANGED'):
            self.page(result, [], expected_checkpoint={'sequence': 999})
        self.assertEqual(self.capture.status()['pages'], 1)

    def test_checkpoint_and_retry_accept_semantically_equal_dictionary_key_order(self):
        state = self.start()
        args = {'capture_id': state['capture_id'], 'expected_checkpoint': None,
                'checkpoint': {'mailbox': ['Sent'], 'offset': 1, 'nested': {'a': 1, 'b': 2}},
                'records': [sent()], 'candidates_checked': 1}
        result = self.capture.page(**args)
        retry = copy.deepcopy(args)
        retry['checkpoint'] = {'nested': {'b': 2, 'a': 1}, 'offset': 1, 'mailbox': ['Sent']}
        retry['records'] = [dict(reversed(list(args['records'][0].items())))]
        self.assertEqual(self.capture.page(**retry), result)
        following = self.page(result, [sent(1)], expected_checkpoint=retry['checkpoint'])
        self.assertEqual(following['counts']['captured'], 2)

    def test_reopened_profile_uses_retained_authored_snapshots_without_global_index(self):
        _, previous = self.publish(count=24)
        path = self.root / 'state' / 'db.sqlite'
        self.a.db.close()
        self.a = Archive(path)
        self.assertEqual(self.a.style_summary(verify=True), previous)
        self.assertEqual(self.a.db.execute('SELECT count(*) FROM mail_index_catalog').fetchone()[0], 0)
        self.assertEqual(self.a.db.execute('SELECT count(*) FROM messages').fetchone()[0], 0)
        context = build_context(self.a, {'id': 'fictional', 'messageID': 'new@fixture.invalid',
                                       'body': 'Please reply.', 'subject': 'Fictional'})
        self.assertEqual(context['style_summary']['source_address'], 'operator@fixture.invalid')
        self.assertEqual(context['style_summary']['example_count'], 24)
        self.assertEqual(len(context['style_examples']), 3)
        self.assertNotIn('OLD-FICTIONAL-FACT', packed(context))

    def test_pause_resume_and_partial_cancel_preserve_previous_profile(self):
        _, previous = self.publish()
        revision = self.a.revision()
        state = self.start()
        state = self.page(state, [sent(100)])
        self.capture.finish(state['capture_id'], status='paused')
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_INCOMPLETE'):
            self.capture.extract(state['capture_id'])
        resumed = self.start(restart=False)
        self.assertEqual(resumed['capture_id'], state['capture_id'])
        self.assertEqual(resumed['checkpoint'], state['checkpoint'])
        self.capture.finish(state['capture_id'], status='cancelled')
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_INCOMPLETE'):
            self.capture.extract(state['capture_id'])
        self.assertEqual(self.a.style_summary(verify=True), previous)
        self.assertEqual(self.a.revision(), revision)
        replacement = self.start(restart=False, selected_address='alias@fixture.invalid')
        self.assertNotEqual(replacement['capture_id'], state['capture_id'])
        self.assertEqual(replacement['address'], 'alias@fixture.invalid')
        self.assertEqual(replacement['counts']['captured'], 0)
        self.assertEqual(self.a.style_summary(verify=True), previous)

    def test_cancelled_capture_reopens_with_exact_page_and_body_position(self):
        state = self.start()
        checkpoint = {'version': 1, 'mailbox_index': 0, 'mailbox': ['Sent'],
                      'page_cursor': {'accountID': 'fixture', 'mailboxPath': ['Sent'], 'offset': 0,
                                      'expectedCount': 128, 'scanID': 'fixture-scan', 'isLocal': False, 'role': 'sent'},
                      'page_native_ids': [str(i) for i in range(128)], 'next_body_offset': 20,
                      'page_completed': False, 'page_headers_counted': True}
        state = self.page(state, [sent(i) for i in range(20)], checked=128, checkpoint=checkpoint)
        self.capture.finish(state['capture_id'], status='cancelled')
        self.a.db.close()
        self.a = Archive(self.root / 'state' / 'db.sqlite')
        resumed = self.start(restart=False)
        self.assertEqual(resumed['capture_id'], state['capture_id'])
        self.assertEqual(resumed['checkpoint'], checkpoint)
        self.assertEqual(resumed['counts'], state['counts'])
        self.assertEqual(resumed['pages'], 1)
        self.assertEqual(resumed['status'], 'running')
        self.assertTrue(resumed['resume_available'])
        self.assertFalse(resumed['acquisition_done'])
        next_checkpoint = dict(checkpoint, next_body_offset=40)
        following = self.page(resumed, [sent(i) for i in range(20, 40)], checked=0,
                              checkpoint=next_checkpoint)
        self.assertEqual(following['counts']['captured'], 40)
        self.assertEqual(following['counts']['records_received'], 40)
        self.assertEqual(following['counts']['candidates_checked'], 128)
        self.assertEqual(following['skipped']['duplicate'], 0)

    def test_lost_page_response_retry_after_resume_does_not_duplicate_counts(self):
        state = self.start()
        args = {'capture_id': state['capture_id'], 'expected_checkpoint': None,
                'checkpoint': {'version': 1, 'page_native_ids': ['0'], 'next_body_offset': 1},
                'records': [sent()], 'candidates_checked': 128}
        committed = self.capture.page(**args)  # Simulate a response lost after commit.
        self.capture.finish(state['capture_id'], status='cancelled')
        resumed = self.start(restart=False)
        self.assertEqual(resumed['checkpoint'], committed['checkpoint'])
        self.assertEqual(self.capture.page(**args), resumed)
        self.assertEqual(self.capture.status()['counts'], committed['counts'])
        self.assertEqual(self.capture.status()['pages'], 1)
        self.assertEqual(self.capture.status()['skipped']['duplicate'], 0)

    def test_unpublished_completed_acquisition_retries_analysis_without_mail(self):
        for ending in ('complete', 'cancelled'):
            with self.subTest(ending=ending):
                state = self.start()
                state = self.page(state, [sent()], checked=1)
                completed = self.capture.finish(state['capture_id'], source_exhausted=True)
                self.assertTrue(completed['acquisition_done'])
                if ending == 'cancelled':
                    self.capture.finish(state['capture_id'], status='cancelled')
                resumed = self.start(restart=False)
                self.assertEqual(resumed['capture_id'], state['capture_id'])
                self.assertEqual(resumed['counts'], state['counts'])
                self.assertEqual(resumed['checkpoint'], state['checkpoint'])
                self.assertEqual(resumed['status'], 'complete')
                self.assertTrue(resumed['coverage']['source_exhausted'])
                self.assertTrue(resumed['acquisition_done'])
                self.assertEqual(self.capture.extract(state['capture_id'])['example_count'], 1)

    def test_published_extract_retry_is_read_only_and_explicit_reextract_starts_fresh(self):
        state, published = self.publish()
        revision = self.a.revision()
        self.assertEqual(self.capture.extract(state['capture_id']), published)
        self.assertEqual(self.a.revision(), revision)
        self.assertFalse(self.capture.status()['resume_available'])
        fresh = self.start(restart=False)
        self.assertNotEqual(fresh['capture_id'], state['capture_id'])
        self.assertIsNone(fresh['checkpoint'])
        self.assertEqual(fresh['counts']['captured'], 0)
        self.assertEqual(self.a.style_summary(verify=True), published)
        self.assertEqual(self.a.revision(), revision)

    def test_finish_retry_preserves_completion_and_rejects_changed_coverage(self):
        state = self.start()
        state = self.page(state, [sent()])
        completed = self.capture.finish(state['capture_id'], source_exhausted=True)
        self.assertEqual(self.capture.finish(state['capture_id'], source_exhausted=True), completed)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_FINISH_CHANGED'):
            self.capture.finish(state['capture_id'], source_exhausted=False)
        self.assertEqual(self.capture.status(), completed)

    def test_resume_configuration_change_starts_fresh_without_mixing_author_or_budget(self):
        _, previous = self.publish()
        for changes in ({'selected_address': 'alias@fixture.invalid'}, {'account_id': 'other-fixture'},
                        {'token_budget': 4096}):
            with self.subTest(changes=changes):
                state = self.start()
                state = self.page(state, [sent()])
                self.capture.finish(state['capture_id'], status='paused')
                fresh = self.start(restart=False, **changes)
                self.assertNotEqual(fresh['capture_id'], state['capture_id'])
                self.assertEqual(fresh['counts']['captured'], 0)
                self.assertEqual(fresh['counts']['token_estimate'], 0)
                self.assertIsNone(fresh['checkpoint'])
                self.assertEqual(self.a.style_summary(verify=True), previous)

    def test_shared_or_unconfirmed_configuration_never_resumes_private_journal(self):
        state = self.start()
        state = self.page(state, [sent()])
        self.capture.finish(state['capture_id'], status='paused')
        for changes, error in (({'shared_addresses': ['operator@fixture.invalid']}, 'STYLE_PERSONAL_ADDRESS_REQUIRED'),
                               ({'author_confirmed': False}, 'STYLE_SENT_AUTHOR_REQUIRED')):
            with self.subTest(changes=changes):
                with self.assertRaisesRegex(ArchiveError, error):
                    self.start(restart=False, **changes)
                self.assertEqual(self.capture.status()['capture_id'], state['capture_id'])
                self.assertEqual(self.capture.status()['status'], 'paused')

    def test_changed_journal_snapshot_or_counters_fails_resume_without_reset(self):
        for change in ('body', 'identity', 'author', 'delete', 'sequence', 'tokens', 'count', 'page', 'skipped'):
            with self.subTest(change=change):
                state = self.start()
                state = self.page(state, [sent()])
                self.capture.finish(state['capture_id'], status='paused')
                row = self.a.db.execute('SELECT * FROM style_capture_samples WHERE capture_id=?',
                                        (state['capture_id'],)).fetchone()
                with self.a.db:
                    if change in ('body', 'identity', 'author'):
                        value = json.loads(row['payload'])
                        field = {'body': 'body_text', 'identity': 'id', 'author': 'from'}[change]
                        value[field] = 'Changed private fixture.'
                        self.a.db.execute('UPDATE style_capture_samples SET payload=? WHERE message_id=?',
                                          (packed(value), row['message_id']))
                    elif change == 'delete':
                        self.a.db.execute('DELETE FROM style_capture_samples WHERE message_id=?', (row['message_id'],))
                    elif change == 'sequence':
                        self.a.db.execute('UPDATE style_capture_samples SET sequence=2 WHERE message_id=?', (row['message_id'],))
                    elif change == 'page':
                        self.a.db.execute('DELETE FROM style_capture_pages WHERE capture_id=?', (state['capture_id'],))
                    elif change == 'skipped':
                        self.a.db.execute("UPDATE style_capture_state SET skipped='{}' WHERE id=1")
                    else:
                        field = {'tokens': 'token_estimate', 'count': 'captured'}[change]
                        self.a.db.execute('UPDATE style_capture_state SET '+field+'='+field+'+1 WHERE id=1')
                with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_JOURNAL_CHANGED'):
                    self.start(restart=False)
                self.assertEqual(self.capture.status()['capture_id'], state['capture_id'])
                self.assertEqual(self.capture.status()['status'], 'paused')

    def test_resume_checkpoint_preserves_bounds_and_rejects_unbounded_page_witness(self):
        state = self.start()
        checkpoint = {'page_native_ids': ['9'*128 for _ in range(128)], 'next_body_offset': 0,
                      'page_cursor': {'accountID': 'fixture', 'mailboxPath': ['Sent'], 'offset': 0}}
        state = self.page(state, [], checked=128, checkpoint=checkpoint)
        self.capture.finish(state['capture_id'], status='paused')
        self.assertEqual(self.start(restart=False)['checkpoint'], checkpoint)
        oversized = dict(checkpoint, page_native_ids=['9'*1024 for _ in range(128)])
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_CHECKPOINT_LIMIT'):
            self.page(state, [], checked=0, checkpoint=oversized)
        self.assertEqual(self.capture.status()['counts'], state['counts'])

    def test_late_cancel_after_publication_invalidates_only_that_profile_once(self):
        state, _ = self.publish()
        revision = self.a.revision()
        self.capture.finish(state['capture_id'], status='cancelled')
        self.assertEqual(self.a.style_summary(verify=True)['extraction_status'], 'stale')
        self.assertEqual(self.a.selected_style_messages(), [])
        self.assertGreater(self.a.revision(), revision)
        cancelled_revision = self.a.revision()
        self.capture.finish(state['capture_id'], status='cancelled')
        self.assertEqual(self.a.revision(), cancelled_revision)
        newer, profile = self.publish()
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_CHANGED'):
            self.capture.finish(state['capture_id'], status='cancelled')
        self.assertEqual(self.capture.status()['capture_id'], newer['capture_id'])
        self.assertEqual(self.a.style_summary(verify=True), profile)

    def test_cancel_between_finish_and_extract_prevents_publication(self):
        state = self.start()
        state = self.page(state, [sent()])
        self.capture.finish(state['capture_id'])
        self.capture.finish(state['capture_id'], status='cancelled')
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_INCOMPLETE'):
            self.capture.extract(state['capture_id'])
        self.assertFalse(style_corpus.has_profile(self.a))

    def test_new_start_wins_against_old_extract_even_without_revision_change(self):
        state = self.start()
        state = self.page(state, [sent()])
        self.capture.finish(state['capture_id'])
        revision = self.a.revision()
        describe = self.a.describe_style
        replacement = []
        def start_new(summary):
            replacement.append(self.start())
            return describe(summary)
        with patch.object(self.a, 'describe_style', side_effect=start_new):
            with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_CHANGED'):
                self.capture.extract(state['capture_id'])
        self.assertEqual(self.a.revision(), revision)
        self.assertEqual(self.capture.status()['capture_id'], replacement[0]['capture_id'])
        self.assertFalse(style_corpus.has_profile(self.a))

    def test_changed_revision_during_extraction_preserves_prior_profile(self):
        _, previous = self.publish()
        state = self.start()
        state = self.page(state, [sent(100)])
        self.capture.finish(state['capture_id'])
        describe = self.a.describe_style
        def change_revision(summary):
            self.a.case_create('Fictional concurrent change')
            return describe(summary)
        with patch.object(self.a, 'describe_style', side_effect=change_revision):
            with self.assertRaisesRegex(ArchiveError, 'STYLE_CHANGED_DURING_EXTRACTION'):
                self.capture.extract(state['capture_id'])
        self.assertEqual(self.a.style_summary(verify=True), previous)

    def test_snapshot_body_change_and_deleted_source_fail_closed(self):
        for change in ('body', 'delete', 'identity'):
            with self.subTest(change=change):
                self.publish()
                example = self.a.selected_style_messages()[0]
                with self.a.db:
                    if change == 'delete':
                        self.a.db.execute('DELETE FROM style_capture_samples WHERE message_id=?', (example['id'],))
                    else:
                        row = self.a.db.execute('SELECT payload FROM style_capture_samples WHERE message_id=?', (example['id'],)).fetchone()
                        value = json.loads(row[0])
                        value['body_text' if change == 'body' else 'id'] = 'Changed fictional snapshot.'
                        self.a.db.execute('UPDATE style_capture_samples SET payload=? WHERE message_id=?', (packed(value), example['id']))
                with self.assertRaisesRegex(ArchiveError, 'STYLE_SOURCE_UNAVAILABLE'):
                    self.a.selected_style_messages()
                self.assertEqual(self.a.style_summary(verify=True)['extraction_status'], 'stale')

    def test_global_index_finish_does_not_expire_direct_sent_profile(self):
        _, previous = self.publish()
        index = self.a.mail_index
        state = index.start()
        index.discovery(state['scan_id'], state['epoch'], None, {'finished': True}, [], True, [])
        index.finish(state['scan_id'], state['epoch'])
        self.assertEqual(self.a.style_summary(verify=True), previous)

    def test_source_changed_with_same_locator_rejects_page_atomically(self):
        state = self.start()
        state = self.page(state, [sent()])
        with self.assertRaisesRegex(ArchiveError, 'STYLE_CAPTURE_SOURCE_CHANGED'):
            self.page(state, [sent(body='Changed fictional content.')])
        self.assertEqual(self.capture.status()['checkpoint'], state['checkpoint'])
        self.assertEqual(self.capture.status()['counts']['captured'], 1)

    def test_generation_rehashes_only_bounded_provider_examples(self):
        _, profile = self.publish(count=24)
        verified = []
        original = style_capture.message
        def observed(archive, mid, verify=True):
            if verify: verified.append(mid)
            return original(archive, mid, verify)
        with patch.object(style_capture, 'message', side_effect=observed):
            result = self.a.style_summary(verify=True)
        self.assertEqual(result, profile)
        self.assertEqual(len(verified), 3)
        self.assertEqual(profile['sample_info']['selected_messages'], 24)
        self.assertLessEqual(profile['sample_info']['provider_example_bytes'], 4096)

    def test_validation_uses_scoped_profile_instead_of_stale_old_legacy_style(self):
        _, old_id, source = fixtures.ArchiveTests.add(self, fixtures.mail('Fictional legacy wording.'),
                                                     direction='sent')
        self.a.style_add(old_id, True)
        self.publish(count=24)
        context = fixtures.ArchiveTests.context(self)
        self.assertEqual(context['style_summary']['example_count'], 24)
        source.write_bytes(b'Changed obsolete fictional legacy source.')
        result = dispatch({'db': str(self.root / 'state' / 'db.sqlite'), 'command': 'validate',
                           'context': context, 'output': fixtures.output_fixture()})
        self.assertIsInstance(result, dict)

    def test_validation_rechecks_scoped_provider_hash_after_generation(self):
        self.publish()
        context = fixtures.ArchiveTests.context(self)
        example = self.a.selected_style_messages()[0]
        with self.a.db:
            row = self.a.db.execute('SELECT payload FROM style_capture_samples WHERE message_id=?',
                                    (example['id'],)).fetchone()
            value = json.loads(row[0])
            value['body_text'] = 'Changed fictional captured source after generation.'
            self.a.db.execute('UPDATE style_capture_samples SET payload=? WHERE message_id=?',
                              (packed(value), example['id']))
        with self.assertRaisesRegex(ArchiveError, 'STYLE_SOURCE_CHANGED'):
            dispatch({'db': str(self.root / 'state' / 'db.sqlite'), 'command': 'validate',
                      'context': context, 'output': fixtures.output_fixture()})

    def test_sample_storage_and_operation_work_have_constant_caps(self):
        measurements = []
        for count in (64, 256, 600):
            state = self.start(token_budget=131072)
            started = time.perf_counter()
            for first in range(0, count, 20):
                state = self.page(state, [sent(i, f'Please check fictional item {i}.')
                                          for i in range(first, min(first+20, count))])
            self.capture.finish(state['capture_id'])
            profile = self.capture.extract(state['capture_id'])
            sizes = self.a.db.execute('SELECT count(*),sum(length(payload)) FROM style_capture_samples WHERE capture_id=?',
                                     (state['capture_id'],)).fetchone()
            measurements.append({'headers': count, 'retained_samples': sizes[0], 'stored_payload_chars': sizes[1],
                                 'source_verifications': profile['sample_info']['source_verifications'],
                                 'wall_seconds': time.perf_counter()-started})
            self.assertEqual(sizes[0], min(count, 512))
            self.assertEqual(profile['sample_info']['source_verifications'], min(count, 512))
            self.assertLessEqual(profile['sample_info']['token_estimate'], 131072)
        self.assertEqual(measurements[-1]['retained_samples'], 512)
        self.assertTrue(all(item['wall_seconds'] > 0 for item in measurements))
        # Only one completed and one unfinished capture are retained.
        newest = self.start()
        newest = self.page(newest, [sent(1000)])
        self.assertLessEqual(self.a.db.execute('SELECT count(*) FROM style_capture_samples').fetchone()[0], 513)
        print('FICTIONAL_DIRECT_STYLE_BOUNDS '+json.dumps(measurements, separators=(',', ':')))


if __name__ == '__main__':
    unittest.main()
