"""Resumable native catalog from fictional plaintext and metadata only."""
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive, ArchiveError, MAX_BODY
from context import build_context
from main import dispatch
import test_archive as fixtures


class MailIndexTests(unittest.TestCase):
    setUp = fixtures.ArchiveTests.setUp
    tearDown = fixtures.ArchiveTests.tearDown
    add = fixtures.ArchiveTests.add

    def start(self, count=3, role='received', path=None, restart=False):
        path = path or ['Archive', 'Inbox']
        state = self.a.mail_index.start(restart)
        box = {'accountID': 'account@fixture.invalid', 'mailboxPath': path, 'name': path[-1],
               'messageCount': count, 'role': role, 'isLocal': False}
        self.a.mail_index.discovery(state['scan_id'], state['epoch'], None, None, [box], True,
                                    [{'id': 'account@fixture.invalid', 'emailAddresses': ['owner@fixture.invalid']}])
        return state, self.a.mail_index.next(state['scan_id'], state['epoch'])

    def record(self, number=0, **changes):
        return dict({'id': str(number), 'accountID': 'account@fixture.invalid', 'mailboxPath': ['Archive', 'Inbox'],
                     'messageID': str(number)+'@history.invalid', 'subject': 'AWS billing overview',
                     'sender': 'service@provider.invalid', 'dateSent': '2026-10-09T01:00:00Z',
                     'messageSize': 1000, 'direction': 'received', 'body': 'Fictional historical text '+str(number),
                     'bodyStatus': 'captured', 'attachmentCount': 0}, **changes)

    def page(self, state, next_box, records, checkpoint=None, done=True):
        return self.a.mail_index.page(state['scan_id'], state['epoch'], next_box['mailbox_id'],
                                      next_box['cursor'], checkpoint, records, done)

    def test_changed_mailbox_rewind_preserves_snapshots_and_recounts_without_duplicates(self):
        state, box = self.start()
        checkpoint = dict(box['cursor'], offset=1)
        saved = self.page(state, box, [self.record()], checkpoint, False)
        mid = saved['message_ids'][0]
        request = dict(command='index_rewind_mailbox', db=str(self.root/'state/db.sqlite'),
                       scan_id=state['scan_id'], epoch=state['epoch'], mailbox_id=box['mailbox_id'],
                       expected_checkpoint=checkpoint)
        dispatch(request)
        pending = self.a.mail_index.next(state['scan_id'], state['epoch'])
        self.assertEqual(pending['cursor']['offset'], 0)
        self.assertIsNone(pending['cursor'].get('expectedCount'))
        self.assertEqual(self.a.message(mid)['source_status'], 'available')
        self.assertEqual(self.a.mail_index.status()['counts']['metadata'], 0)
        with self.assertRaisesRegex(ArchiveError, 'INDEX_CHECKPOINT_CHANGED'):
            dispatch(request)
        self.page(state, pending, [self.record(1)])
        final = self.a.mail_index.finish(state['scan_id'], state['epoch'])
        self.assertEqual(final['counts']['metadata'], 1)
        self.assertEqual(self.a.message(mid)['source_status'], 'missing_or_changed')

    def test_checkpoint_body_and_metadata_commit_atomically_and_exact_retries_are_idempotent(self):
        state, box = self.start()
        checkpoint = dict(box['cursor'], offset=1)
        response = self.page(state, box, [self.record()], checkpoint, False)
        revision = self.a.revision(); mid = response['message_ids'][0]
        retry = self.page(state, box, [self.record()], checkpoint, False)
        self.assertEqual(retry['counts'], response['counts']); self.assertEqual(retry['message_ids'], [mid])
        self.assertEqual(self.a.revision(), revision)
        with self.assertRaisesRegex(ArchiveError, 'INDEX_PAGE_RETRY_CHANGED'):
            self.page(state, box, [self.record(body='Changed retry data')], checkpoint, False)
        self.a.db.close(); self.a = Archive(self.root/'state/db.sqlite')
        resumed = self.a.mail_index.start()
        self.assertEqual((resumed['scan_id'], resumed['epoch']), (state['scan_id'], state['epoch']))
        self.assertEqual(self.a.mail_index.next(state['scan_id'], state['epoch'])['cursor'], checkpoint)
        self.assertEqual(self.a.message(mid)['source_status'], 'available')
        next_box = self.a.mail_index.next(state['scan_id'], state['epoch'])
        original = self.a.mail_index._upsert
        def fail_after_insert(record, old):
            original(record, old); raise ArchiveError('FICTIONAL_FAILED_TRANSACTION')
        with patch.object(self.a.mail_index, '_upsert', side_effect=fail_after_insert):
            with self.assertRaisesRegex(ArchiveError, 'FICTIONAL_FAILED_TRANSACTION'):
                self.page(state, next_box, [self.record(1)])
        self.assertEqual(self.a.mail_index.status()['counts'], response['counts'])
        self.assertEqual(self.a.mail_index.next(state['scan_id'], state['epoch'])['cursor'], checkpoint)
        self.assertEqual(self.a.db.execute('SELECT count(*) FROM mail_index_catalog').fetchone()[0], 1)

    def test_discovery_queue_nested_paths_pause_resume_and_epoch_guard(self):
        state = self.a.mail_index.start()
        boxes = [{'accountID': 'account@fixture.invalid', 'mailboxPath': [parent, 'Inbox'], 'messageCount': 0,
                  'role': 'received', 'isLocal': False} for parent in ('A', 'B')]
        following = {'scanID': state['scan_id'], 'accountOffset': 1, 'localPhase': False, 'stack': []}
        first = self.a.mail_index.discovery(state['scan_id'], state['epoch'], None, following, boxes, False)
        self.assertEqual(first['counts']['mailboxes'], 2)
        self.assertEqual(self.a.mail_index.discovery(state['scan_id'], state['epoch'], None, following, boxes, False)['counts']['mailboxes'], 2)
        with self.assertRaisesRegex(ArchiveError, 'INDEX_SCAN_INCOMPLETE'):
            self.a.mail_index.finish(state['scan_id'], state['epoch'])
        self.a.mail_index.finish(state['scan_id'], state['epoch'], following, 'paused', 'Fictional stop')
        resumed = self.a.mail_index.start(); self.assertEqual(resumed['discovery_checkpoint'], following)
        self.a.mail_index.discovery(state['scan_id'], state['epoch'], following, None, [], True)
        ids = []; paths = []
        for _ in range(2):
            box = self.a.mail_index.next(state['scan_id'], state['epoch']); ids.append(box['mailbox_id']); paths.append(box['mailbox']['mailboxPath'])
            self.page(state, box, [])
        self.assertEqual(len(set(ids)), 2); self.assertEqual({tuple(path) for path in paths}, {('A','Inbox'),('B','Inbox')})
        self.assertIsNone(self.a.mail_index.next(state['scan_id'], state['epoch'])['cursor'])
        self.assertEqual(self.a.mail_index.finish(state['scan_id'], state['epoch'])['status'], 'complete')
        new = self.a.mail_index.start(True)
        self.assertGreater(new['epoch'], state['epoch'])
        with self.assertRaisesRegex(ArchiveError, 'INDEX_SCAN_CHANGED'):
            self.a.mail_index.discovery(state['scan_id'], state['epoch'], None, None, [], True)

    def test_swift_dictionary_order_roundtrip_preserves_checkpoints_and_exact_retries(self):
        def reordered(value):
            if isinstance(value, dict):
                return {key: reordered(value[key]) for key in reversed(value)}
            if isinstance(value, list): return [reordered(item) for item in value]
            return value

        state = self.a.mail_index.start()
        box = {'accountID': 'local@fixture.invalid', 'mailboxPath': ['Local Notes'],
               'name': 'Local Notes', 'messageCount': 2, 'role': 'unknown', 'isLocal': True}
        following = {'scanID': state['scan_id'], 'accountOffset': 1, 'localPhase': True,
                     'stack': [{'accountID': 'account@fixture.invalid', 'parentPath': ['Archive'],
                                'nextChild': 0, 'expectedChildCount': 1, 'isLocal': False}]}
        accounts = [{'id': 'account@fixture.invalid', 'name': 'Fictional account',
                     'addresses': ['owner@fixture.invalid']}]
        first = self.a.mail_index.discovery(state['scan_id'], state['epoch'], None, following,
                                            [box], False, accounts)
        revision = self.a.revision()
        retried = self.a.mail_index.discovery(state['scan_id'], state['epoch'], None,
                                              reordered(following), reordered([box]), False, reordered(accounts))
        self.assertEqual(first['counts'], retried['counts']); self.assertEqual(self.a.revision(), revision)
        with self.assertRaisesRegex(ArchiveError, 'INDEX_PAGE_RETRY_CHANGED'):
            self.a.mail_index.discovery(state['scan_id'], state['epoch'], None, reordered(following),
                                        [dict(box, messageCount=3)], False, reordered(accounts))
        self.a.mail_index.discovery(state['scan_id'], state['epoch'], reordered(following), None, [], True)
        next_box = self.a.mail_index.next(state['scan_id'], state['epoch'])
        self.assertNotEqual(list(next_box['cursor']), list(reordered(next_box['cursor'])))
        next_box['cursor'] = reordered(next_box['cursor'])
        checkpoint = dict(next_box['cursor'], offset=1)
        record = self.record(accountID='local@fixture.invalid', mailboxPath=['Local Notes'],
                             direction='unknown', isLocal=True)
        response = self.page(state, next_box, [record], checkpoint, False)
        revision = self.a.revision()
        retried = self.page(state, reordered(next_box), reordered([record]), reordered(checkpoint), False)
        self.assertEqual(response['message_ids'], retried['message_ids'])
        self.assertEqual(response['counts'], retried['counts']); self.assertEqual(self.a.revision(), revision)
        with self.assertRaisesRegex(ArchiveError, 'INDEX_PAGE_RETRY_CHANGED'):
            self.page(state, reordered(next_box), [dict(record, body='Changed fictional body')], reordered(checkpoint), False)
        next_box = self.a.mail_index.next(state['scan_id'], state['epoch'])
        next_box['cursor'] = reordered(next_box['cursor'])
        result = self.page(state, next_box, [dict(record, id='1', messageID='1@history.invalid')])
        self.assertEqual(result['counts']['captured'], 2)
        self.assertEqual(self.a.mail_index.finish(state['scan_id'], state['epoch'])['status'], 'complete')

    def test_existing_noncanonical_development_cursors_resume_without_scan_rewrite(self):
        state = self.a.mail_index.start()
        box = {'accountID': 'account@fixture.invalid', 'mailboxPath': ['Archive', 'Inbox'],
               'messageCount': 1, 'role': 'received', 'isLocal': False}
        following = {'scanID': state['scan_id'], 'accountOffset': 1, 'localPhase': False,
                     'stack': [{'accountID': 'account@fixture.invalid', 'nextChild': 0}]}
        self.a.mail_index.discovery(state['scan_id'], state['epoch'], None, following, [box], False)
        with self.a.db:
            self.a.db.execute('UPDATE mail_index_state SET discovery_checkpoint=? WHERE id=1',
                              (json.dumps(following),))
        self.a.mail_index.finish(state['scan_id'], state['epoch'], following, 'paused')
        resumed = self.a.mail_index.start()
        self.assertEqual((resumed['scan_id'], resumed['epoch']), (state['scan_id'], state['epoch']))
        self.a.mail_index.discovery(state['scan_id'], state['epoch'], following, None, [], True)
        next_box = self.a.mail_index.next(state['scan_id'], state['epoch'])
        with self.a.db:
            self.a.db.execute('UPDATE mail_index_mailboxes SET cursor=? WHERE mailbox_id=?',
                              (json.dumps(dict(reversed(list(next_box['cursor'].items())))), next_box['mailbox_id']))
        self.assertEqual(self.page(state, next_box, [self.record()])['counts']['captured'], 1)

    def test_all_metadata_is_counted_but_unreadable_and_large_bodies_are_not_successes(self):
        state, box = self.start(4)
        records = [self.record(), self.record(1, bodyStatus='unreadable', body='', failure='ENCRYPTED'),
                   self.record(2, body='x'*(MAX_BODY+1)), self.record(3, bodyStatus='metadata_only', body='')]
        result = self.page(state, box, records)
        self.assertEqual(result['counts']['metadata'], 4)
        self.assertEqual(result['counts']['captured'], 1)
        self.assertEqual(result['counts']['unreadable'], 1)
        self.assertEqual(result['counts']['too_large'], 1)
        self.assertEqual(result['counts']['metadata_only'], 1)
        self.assertEqual(len(result['message_ids']), 1)
        rows = self.a.db.execute('SELECT body_status,failure FROM mail_index_catalog ORDER BY native_id').fetchall()
        self.assertEqual([tuple(row) for row in rows], [('captured',''),('unreadable','ENCRYPTED'),('too_large','BODY_LIMIT'),('metadata_only','')])
        self.assertEqual(self.a.mail_index.finish(state['scan_id'], state['epoch'])['status'], 'complete')
        self.assertFalse(self.a.snapshot_directory.exists())  # No full MIME/.eml copies.

    def test_same_native_id_in_different_paths_and_header_collision_keep_distinct_versions(self):
        state, box = self.start(1)
        first = self.page(state, box, [self.record()])['message_ids'][0]
        self.a.mail_index.finish(state['scan_id'], state['epoch'])
        second_state, second_box = self.start(1, path=['Other', 'Inbox'])
        second = self.page(second_state, second_box, [self.record(mailboxPath=['Other','Inbox'])])['message_ids'][0]
        self.assertNotEqual(first, second)
        self.a.mail_index.finish(second_state['scan_id'], second_state['epoch'])
        self.assertEqual(self.a.message(first)['source_status'], 'missing_or_changed')
        self.assertEqual(self.a.message(second)['source_status'], 'available')
        third_state, third_box = self.start(1, path=['Other', 'Inbox'])
        changed = self.page(third_state, third_box, [self.record(mailboxPath=['Other','Inbox'], body='Changed captured body')])['message_ids'][0]
        self.assertNotEqual(changed, second)
        self.assertEqual(self.a.message(second)['source_status'], 'missing_or_changed')
        self.assertEqual(self.a.message(changed)['body_text'], 'Changed captured body')
        self.assertEqual(self.a.db.execute('SELECT count(*) FROM mail_index_versions').fetchone()[0], 3)

    def test_rescan_refreshes_unchanged_fts_rows_so_stale_matches_do_not_starve_a_retained_mail(self):
        state, box = self.start(80)
        records = [self.record(i, subject='AWS Free Tier usage') for i in range(80)]
        target = self.page(state, box, records)['message_ids'][0]
        self.a.mail_index.finish(state['scan_id'], state['epoch'])
        prior_max = self.a.db.execute('SELECT max(search_rowid) FROM mail_index_catalog').fetchone()[0]
        next_state, next_box = self.start(1)
        response = self.page(next_state, next_box, [records[0]])
        self.assertEqual(response['message_ids'], [target])  # Same immutable body version.
        self.a.mail_index.finish(next_state['scan_id'], next_state['epoch'])
        catalog = self.a.db.execute('SELECT search_rowid FROM mail_index_catalog WHERE current_message=?', (target,)).fetchone()
        self.assertGreater(catalog[0], prior_max)
        current = {'id':'selected', 'subject':'AWS Free Tier limit alert', 'sender':'alerts@provider.invalid'}
        self.assertEqual([match['id'] for match in self.a.related_candidates(current)], [target])
        self.assertEqual(self.a.mail_index.status()['counts']['captured'], 1)

    def test_old_mail_beyond_native_window_is_retrieved_without_body_hydration(self):
        state, box = self.start(900)
        historical = self.record(subject='AWS Free Tier usage', body='Old relevant original body.')
        result = self.page(state, box, [historical], dict(box['cursor'], offset=1), False)
        target = result['message_ids'][0]
        for start in range(1, 900, 128):
            box = self.a.mail_index.next(state['scan_id'], state['epoch'])
            end = min(start+128, 900)
            self.page(state, box, [self.record(i, subject='Unrelated laundry notification') for i in range(start,end)],
                      None if end == 900 else dict(box['cursor'], offset=end), end == 900)
        self.a.mail_index.finish(state['scan_id'], state['epoch'])
        current = {'id':'current', 'subject':'AWS Free Tier limit alert', 'sender':'alerts@provider.invalid', 'body':'Current notification.', 'fictional':True}
        with patch.object(self.a, 'message', side_effect=AssertionError('CANDIDATE_BODY_HYDRATION')):
            self.assertEqual(self.a.related_candidates(current)[0]['id'], target)
            preview = self.a.candidate_previews([target])[0]
        self.assertEqual(preview['origin'], 'apple_mail_index_snapshot'); self.assertNotIn('body', packed_preview := json.dumps(preview))
        context = build_context(self.a, current)
        self.assertEqual(context['candidate_ids'], [target]); self.assertEqual(len(context['thread_evidence']), 1)
        case_id = self.a.case_create('Fictional manually confirmed history'); self.a.membership(case_id, target, True)
        context = build_context(self.a, current, case_id=case_id)
        self.assertEqual(context['thread_evidence'][1]['text'], historical['body'])
        self.assertIn('現在のMail原本は照合していません', ' '.join(context['local_warnings']))

    def test_limits_wrong_scope_hash_corruption_and_unrelated_source_deletion_fail_closed(self):
        state, box = self.start(1)
        for records in ([self.record(i) for i in range(129)], [self.record(accountID='wrong@fixture.invalid')],
                        [self.record(direction='sent')], [self.record(), self.record()]):
            with self.assertRaises(ArchiveError): self.page(state, box, records)
            self.assertEqual(self.a.mail_index.status()['counts']['metadata'], 0)
        mid = self.page(state, box, [self.record()])['message_ids'][0]
        parsed = self.a.message(mid)
        self.assertTrue(parsed['snapshot_hash_verified']); self.assertFalse(parsed['range_verified']); self.assertFalse(parsed['live_verified'])
        sid, _, _ = self.add(fixtures.mail(), 'legacy.eml')
        self.a.delete_source(sid)
        self.assertEqual(self.a.message(mid)['source_status'], 'available')
        payload = json.loads(self.a.db.execute('SELECT payload FROM messages WHERE id=?', (mid,)).fetchone()[0]); payload['body_text'] = 'Fictional tampered storage'
        with self.a.db: self.a.db.execute('UPDATE messages SET payload=? WHERE id=?', (json.dumps(payload), mid))
        self.assertEqual(self.a.message(mid)['source_status'], 'missing_or_changed')
        self.assertFalse(self.a.message(mid)['snapshot_hash_verified'])

    def test_large_valid_native_metadata_uses_utf8_bounds_and_can_be_ranked(self):
        path = ['架空'*600, 'Inbox']
        state, box = self.start(1, path=path)
        subject = 'AWS Free Tier usage ' + '架空'*1000
        sender = ('Fictional '*600)+'<notice@provider.invalid>'
        record = self.record(mailboxPath=path, subject=subject, sender=sender, messageID='x'*3000+'@history.invalid')
        result = self.page(state, box, [record])
        current = {'id':'selected', 'subject':'AWS Free Tier limit alert', 'sender':'alerts@provider.invalid'}
        self.assertEqual(self.a.related_candidates(current)[0]['id'], result['message_ids'][0])
        self.assertEqual(self.a.message(result['message_ids'][0])['subject'], subject)
        next_state, next_box = self.start(1, restart=True)
        with self.assertRaisesRegex(ArchiveError, 'INDEX_RECORD_INVALID'):
            self.page(next_state, next_box, [self.record(subject='架空'*3000)])
        self.assertEqual(self.a.mail_index.status()['counts']['metadata'], 0)

    def test_missing_sent_date_uses_received_date_and_both_dates_participate_in_version_identity(self):
        state, box = self.start(1)
        record = self.record(dateSent=None, dateReceived='2026-10-09T02:30:00Z')
        first = self.page(state, box, [record])['message_ids'][0]
        self.a.mail_index.finish(state['scan_id'], state['epoch'])
        message = self.a.message(first)
        self.assertEqual(message['date'], '2026-10-09T02:30:00+00:00')
        self.assertIsNone(message['date_sent'])
        self.assertEqual(message['snapshot']['date_received'], message['date'])
        second_state, second_box = self.start(1)
        second = self.page(second_state, second_box, [dict(record,dateSent='2026-10-09T01:00:00Z')])['message_ids'][0]
        self.a.mail_index.finish(second_state['scan_id'], second_state['epoch'])
        third_state, third_box = self.start(1)
        third = self.page(third_state, third_box, [dict(record,dateSent='2026-10-09T01:00:00Z',dateReceived='2026-10-09T03:30:00Z')])['message_ids'][0]
        self.assertNotEqual(first, second); self.assertNotEqual(second, third)
        self.assertEqual(self.a.message(second)['source_status'], 'missing_or_changed')
        self.assertEqual(self.a.message(third)['date'], '2026-10-09T01:00:00+00:00')

    def test_current_header_uses_latest_native_version_but_old_confirmed_case_stays_fail_closed(self):
        state, box = self.start(1)
        old = self.page(state, box, [self.record(body='Old captured body.')])['message_ids'][0]
        self.a.mail_index.finish(state['scan_id'], state['epoch'])
        case_id = self.a.case_create('Old fictional confirmed version'); self.a.membership(case_id, old, True)
        second_state, second_box = self.start(1)
        latest = self.page(second_state, second_box, [self.record(body='Updated captured body.')])['message_ids'][0]
        self.a.mail_index.finish(second_state['scan_id'], second_state['epoch'])
        current = {'id':'selected', 'messageID':'0@history.invalid', 'subject':'AWS billing overview',
                   'sender':'service@provider.invalid', 'body':'Freshly selected current text.'}
        context = build_context(self.a, current)
        self.assertEqual([e['message_id'] for e in context['thread_evidence'][1:]], [latest])
        self.assertNotIn(old, context['candidate_ids'])
        with self.assertRaisesRegex(ArchiveError, 'EVIDENCE_SOURCE_MISSING_OR_CHANGED'):
            build_context(self.a, current, case_id=case_id)
        plan = ' '.join(str(r[3]) for r in self.a.db.execute('EXPLAIN QUERY PLAN SELECT m.id FROM messages m LEFT JOIN mail_index_versions v ON v.message_id=m.id LEFT JOIN mail_index_catalog c ON c.locator_id=v.locator_id WHERE m.message_id=? AND (v.message_id IS NULL OR (c.current_message=v.message_id AND c.metadata_hash=v.metadata_hash AND c.last_seen_epoch>=?)) LIMIT ?', ('0@history.invalid',1,101)))
        self.assertIn('by_message_id', plan); self.assertNotIn('SCAN messages', plan)
        self.assertNotIn('TEMP B-TREE', plan)


if __name__ == '__main__': unittest.main()
