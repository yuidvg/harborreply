"""Fictional indexed-Sent style sampling and bounded-work regressions."""
import json
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive, ArchiveError, authored_text, digest, packed
import style_corpus
import test_archive as fixtures

CATALOG_FIXTURE_SCHEMA = '''CREATE TABLE IF NOT EXISTS mail_index_catalog(
 locator_id TEXT PRIMARY KEY,account_id TEXT,mailbox_path TEXT,native_id TEXT,
 message_id TEXT,subject TEXT,sender TEXT,normalized_from TEXT,date TEXT NOT NULL,
 direction TEXT,message_size INTEGER,is_local INTEGER,attachment_count INTEGER,
 metadata_hash TEXT,last_seen_epoch INTEGER,current_message TEXT,body_status TEXT,failure TEXT);
 CREATE INDEX IF NOT EXISTS mail_index_style ON mail_index_catalog(
 account_id,direction,normalized_from,body_status,date DESC,locator_id);'''


class StyleCorpusTests(unittest.TestCase):
    setUp = fixtures.ArchiveTests.setUp
    tearDown = fixtures.ArchiveTests.tearDown

    def prepare(self):
        self.a.db.executescript(CATALOG_FIXTURE_SCHEMA)
        self.a.mail_index_completed_epoch = lambda account_id=None: getattr(self, 'epoch', 1)

    def add(self, body, number=0, direction='sent', account='fixture',
            sender='Operator <operator@fixture.invalid>', date=None, status='captured'):
        self.prepare()
        message = fixtures.mail(body, mid=f'style{number}@fixture.invalid', subject='Fictional style fixture')
        message.replace_header('From', sender)
        if date is not None:
            message.replace_header('Date', date)
        path = self.root / f'style-{number}.eml'
        path.write_bytes(message.as_bytes())
        source = self.a.add_source(str(path), direction, account, False)
        self.a.ingest_batch(source)
        mid = self.a.db.execute('SELECT message_id FROM locations WHERE source_id=?', (source,)).fetchone()[0]
        parsed = self.a.message(mid)
        locator = digest(f'{account}:{number}'.encode())
        row = {'locator_id': locator, 'account_id': account, 'mailbox_path': '["Sent"]',
               'native_id': str(number), 'message_id': parsed['message_id'],
               'subject': parsed['subject'], 'sender': sender,
               'normalized_from': style_corpus.address(sender), 'date': parsed['date'] or '',
               'direction': direction, 'message_size': path.stat().st_size, 'is_local': 1,
               'attachment_count': 0, 'metadata_hash': digest(f'header:{account}:{number}'.encode()),
               'last_seen_epoch': 1, 'current_message': mid, 'body_status': status, 'failure': ''}
        columns = [r[1] for r in self.a.db.execute('PRAGMA table_info(mail_index_catalog)')]
        row = {k: v for k, v in row.items() if k in columns}
        with self.a.db:
            self.a.db.execute('INSERT OR REPLACE INTO mail_index_catalog('+','.join(row)+') VALUES('+','.join('?' for _ in row)+')', tuple(row.values()))
        return mid, path, locator

    def extract(self, **options):
        self.prepare()
        arguments = {'account_id': 'fixture', 'own_addresses': ['operator@fixture.invalid'],
                     'author_confirmed': True}
        arguments.update(options)
        return style_corpus.extract(self.a, **arguments)

    def add_native_indexed_sent(self, count):
        index = self.a.mail_index
        started = index.start()
        scan, epoch = started['scan_id'], started['epoch']
        index.discovery(scan, epoch, None, {'finished': True},
                        [{'accountID': 'fixture', 'mailboxPath': ['Sent'], 'messageCount': count,
                          'role': 'sent', 'isLocal': False}], True,
                        [{'id': 'fixture', 'name': 'Fictional personal account',
                          'addresses': ['operator@fixture.invalid']}])
        for start in range(0, count, 128):
            queued = index.next(scan, epoch)
            records = [{'accountID': 'fixture', 'mailboxPath': ['Sent'], 'nativeID': str(i),
                        'messageID': f'corpus{i}@fixture.invalid', 'subject': 'Fictional indexed Sent',
                        'sender': 'operator@fixture.invalid', 'dateSent': '2026-10-10T00:00:00+00:00',
                        'direction': 'sent', 'messageSize': 128, 'attachmentCount': 0,
                        'body': f'Please check fictional item {i}.', 'bodyStatus': 'captured'}
                       for i in range(start, min(start+128, count))]
            index.page(scan, epoch, queued['mailbox_id'], queued['cursor'], {'offset': start+len(records)},
                       records, start+len(records) == count)
        index.finish(scan, epoch)

    def test_many_complete_japanese_and_english_mails_drive_aggregate_over_three(self):
        for i in range(12):
            body = ('お世話になっております。\n\n架空の項目'+str(i)+'のご確認をお願いいたします。\n\nよろしくお願いいたします。'
                    if i % 2 else 'Thank you for your message.\n\nPlease send fictional item '+str(i)+'.\n\nKind regards,')
            self.add(body+'\n\nOn 8 Oct 2026, quoted@fixture.invalid wrote:\nSECRET-SHIP 999 approved.', i)
        result = self.extract()
        self.assertEqual(result['example_count'], 12)
        self.assertEqual(result['language'], 'Mixed')
        self.assertEqual(result['sample_info']['selected_messages'], 12)
        self.assertFalse(result['sample_info']['token_estimate_is_exact'])
        self.assertTrue(result['sample_info']['coverage']['snapshot_only'])
        self.assertNotIn('SECRET-SHIP', packed(result))
        self.assertNotIn('999', result['description'])
        provider = style_corpus.selected_messages(self.a)
        self.assertLessEqual(len(provider), 3)
        self.assertLessEqual(sum(len(authored_text(m['body_text']).encode()) for m in provider), 4096)
        self.assertEqual(style_corpus.summary(self.a, verify=True), result)

    def test_actual_sent_account_and_single_author_are_required(self):
        self.add('Please send the actual fictional report.', 1)
        for i, direction in enumerate(('received', 'draft', 'unknown'), 2):
            self.add('Please send wrong-role item '+str(i)+'.', i, direction=direction)
        self.add('Please send other-account item.', 5, account='other')
        self.add('Please send shared item.', 6, sender='Shared <shared@fixture.invalid>')
        self.add('Please send ambiguous item.', 7, sender='operator@fixture.invalid, other@fixture.invalid')
        # A malicious/ambiguous normalized catalog address is not proof of authorship.
        with self.a.db:
            self.a.db.execute("UPDATE mail_index_catalog SET normalized_from='operator@fixture.invalid' WHERE native_id='7'")
        result = self.extract(own_addresses=['operator@fixture.invalid', 'shared@fixture.invalid'],
                              shared_addresses=['shared@fixture.invalid'])
        self.assertEqual(result['example_count'], 1)
        self.assertEqual(result['sample_info']['skipped']['unconfirmed_author'], 1)
        self.assertEqual(result['sample_info']['candidates_checked'], 2)

    def test_author_confirmation_is_a_boolean_not_a_truthy_value(self):
        self.add('Please send the fictional report.')
        for value in (False, 'true', 1, None):
            with self.subTest(value=value), self.assertRaisesRegex(ArchiveError, 'STYLE_SENT_AUTHOR_REQUIRED'):
                self.extract(author_confirmed=value)
        self.assertFalse(style_corpus.has_profile(self.a))

    def test_budget_charges_complete_utf8_samples_and_continues_after_large_mail(self):
        small = 'ご確認をお願いいたします。'
        expected = style_corpus.conservative_units(small)
        self.add('長い架空の文章です。'*100, 1, date='Sat, 10 Oct 2026 09:00:00 +0900')
        self.add(small, 2, date='Fri, 09 Oct 2026 09:00:00 +0900')
        result = self.extract(token_budget=expected)
        self.assertEqual(result['example_count'], 1)
        self.assertEqual(result['sample_info']['token_estimate'], expected)
        self.assertEqual(result['sample_info']['skipped']['over_budget'], 1)
        self.assertEqual(result['sample_info']['source_verifications'], 1)
        selected = style_corpus.selected_messages(self.a)
        self.assertEqual(authored_text(selected[0]['body_text']), small)
        self.assertGreater(expected, len(small))  # Japanese characters are not counted as one byte/token.

    def test_one_sample_over_budget_is_not_truncated_or_reported_as_success(self):
        self.add('X'*200)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_INDEXED_SENT_EXAMPLES_REQUIRED'):
            self.extract(token_budget=64)
        self.assertFalse(style_corpus.has_profile(self.a))

    def test_duplicate_authored_text_and_quote_only_messages_do_not_bias_statistics(self):
        self.add('Thank you for your message.\n\nPlease check fictional item.', 1)
        self.add('Thank you for your message.\n\nPlease check fictional item.\n\n> Different quoted old mail.', 2)
        self.add('> Received text only.\n-- \nSignature only.', 3)
        result = self.extract()
        self.assertEqual(result['example_count'], 1)
        self.assertEqual(result['sample_info']['skipped']['duplicate'], 1)
        self.assertEqual(result['sample_info']['skipped']['empty'], 1)
        self.assertEqual(result['sample_info']['source_verifications'], 1)

    def test_source_change_before_extraction_is_skipped_without_success(self):
        _, path, _ = self.add('Please send unchanged fictional report.')
        path.write_bytes(b'Changed fictional bytes')
        with self.assertRaisesRegex(ArchiveError, 'STYLE_INDEXED_SENT_EXAMPLES_REQUIRED'):
            self.extract()

    def test_provider_source_change_invalidates_profile_and_blocks_use(self):
        _, path, _ = self.add('Please send unchanged fictional report.')
        self.extract()
        path.write_bytes(b'Changed fictional bytes')
        with self.assertRaisesRegex(ArchiveError, 'STYLE_SOURCE_UNAVAILABLE'):
            style_corpus.selected_messages(self.a)
        stale = style_corpus.summary(self.a, verify=True)
        self.assertEqual(stale['extraction_status'], 'stale')
        self.assertEqual(stale['description'], '')
        self.assertEqual(stale['source_phrases'], [])
        self.assertEqual(style_corpus.selected_messages(self.a), [])

    def test_changed_catalog_metadata_or_missing_sample_invalidates_aggregate(self):
        for change in ('metadata', 'deleted', 'direction', 'scan'):
            with self.subTest(change=change):
                _, _, locator = self.add('Please check fictional '+change+'.', 100+len(change))
                self.extract()
                with self.a.db:
                    if change == 'metadata':
                        self.a.db.execute('UPDATE mail_index_catalog SET metadata_hash=? WHERE locator_id=?', ('changed', locator))
                    elif change == 'deleted':
                        self.a.db.execute('DELETE FROM mail_index_catalog WHERE locator_id=?', (locator,))
                    elif change == 'direction':
                        self.a.db.execute("UPDATE mail_index_catalog SET direction='unknown' WHERE locator_id=?", (locator,))
                    else:
                        self.epoch = 2
                self.assertEqual(style_corpus.summary(self.a, verify=True)['extraction_status'], 'stale')
                self.epoch = 1

    def test_changed_revision_during_cpu_extraction_does_not_commit_profile(self):
        self.add('Please send a fictional report.')
        describe = self.a.describe_style
        def concurrent(summary):
            self.a.case_create('Fictional concurrent change')
            return describe(summary)
        with patch.object(self.a, 'describe_style', side_effect=concurrent):
            with self.assertRaisesRegex(ArchiveError, 'STYLE_CHANGED_DURING_EXTRACTION'):
                self.extract()
        self.assertFalse(style_corpus.has_profile(self.a))

    def test_multiple_aliases_are_merged_recent_first_without_global_sort(self):
        older, _, _ = self.add('Please check older fictional mail.', 1,
                               date='Thu, 08 Oct 2026 09:00:00 +0900')
        newer, _, _ = self.add('Please check newer fictional mail.', 2,
                               sender='Alias <alias@fixture.invalid>', date='Sat, 10 Oct 2026 09:00:00 +0900')
        self.extract(own_addresses=['operator@fixture.invalid', 'alias@fixture.invalid'])
        profile = json.loads(self.a.db.execute('SELECT manifest FROM style_corpus_profile').fetchone()[0])
        self.assertEqual([m['message_id'] for m in profile], [newer, older])
        plan = list(self.a.db.execute('EXPLAIN QUERY PLAN '+style_corpus.CANDIDATE_SQL.format(cursor_clause=''),
                                      ('fixture', 'operator@fixture.invalid', 1, 64)))
        self.assertTrue(any('mail_index_style' in r[3] for r in plan), plan)
        self.assertFalse(any('TEMP B-TREE' in r[3] for r in plan), plan)

    def test_metadata_only_or_old_scan_rows_are_not_claimed_as_processed_bodies(self):
        self.add('Please check available fictional mail.', 1)
        self.add('Please check metadata-only fictional mail.', 2, status='metadata_only')
        self.add('Please check stale fictional mail.', 3)
        with self.a.db:
            self.a.db.execute('UPDATE mail_index_catalog SET last_seen_epoch=0 WHERE native_id=\'3\'')
        result = self.extract()
        self.assertEqual(result['example_count'], 1)
        self.assertEqual(result['sample_info']['candidates_checked'], 1)
        self.assertEqual(result['sample_info']['coverage']['scope'], 'indexed_confirmed_own_sent')

    def test_provider_examples_can_be_empty_for_complete_long_samples(self):
        self.add('A complete fictional paragraph. '*90)
        result = self.extract()
        self.assertEqual(result['example_count'], 1)
        self.assertEqual(result['sample_info']['provider_example_count'], 0)
        self.assertEqual(style_corpus.selected_messages(self.a), [])
        self.assertEqual(style_corpus.summary(self.a, verified_messages=[])['extraction_status'], 'ready')

    def test_legacy_corpus_display_templates_are_removed_but_provider_sources_are_preserved(self):
        self.add('Thank you for your message.\n\nPlease check a fictional item.')
        original = self.extract()
        provider = self.a.selected_style_messages()
        old = dict(original, description='Old fabricated [recipient] template.',
                   examples=['Please [requested action].'], example_origin='synthetic_template_not_source_quote')
        old.pop('description_origin')
        with self.a.db:
            self.a.db.execute('UPDATE style_corpus_profile SET payload=? WHERE id=1', (packed(old),))
        self.assertEqual(style_corpus.summary(self.a, verify=True), original)
        self.a.db.close(); self.a = Archive(self.root / 'state' / 'db.sqlite')
        self.assertEqual(style_corpus.summary(self.a, verify=True), original)
        self.assertEqual(self.a.selected_style_messages(), provider)
        persisted = json.loads(self.a.db.execute('SELECT payload FROM style_corpus_profile').fetchone()[0])
        self.assertEqual(persisted, original)

    def test_invalid_budgets_addresses_and_shared_only_account_fail_closed(self):
        self.add('Please check a fictional item.')
        for value in (63, 131073, True, 1.5, '32768'):
            with self.subTest(value=value), self.assertRaisesRegex(ArchiveError, 'STYLE_TOKEN_BUDGET_INVALID'):
                self.extract(token_budget=value)
        for value in ('a@fixture.invalid\nInjected: yes', 'a@fixture.invalid, b@fixture.invalid', 'bad'):
            self.assertEqual(style_corpus.address(value), '')
        with self.assertRaisesRegex(ArchiveError, 'STYLE_PERSONAL_ADDRESS_REQUIRED'):
            self.extract(shared_addresses=['operator@fixture.invalid'])

    def test_generation_verifies_only_bounded_examples_not_all_aggregate_samples(self):
        for i in range(20):
            self.add('Please check fictional sample '+str(i)+'.', i)
        self.extract()
        reads = []
        message = self.a.message
        def observed(mid, verify=True):
            if verify:
                reads.append(mid)
            return message(mid, verify)
        with patch.object(self.a, 'message', side_effect=observed):
            result = style_corpus.summary(self.a, verify=True)
        self.assertEqual(result['example_count'], 20)
        self.assertEqual(len(reads), 3)
        self.assertEqual(result['sample_info']['coverage']['generation_source_verification'], 'bounded_provider_examples_only')

    def test_partial_provider_sample_list_never_validates_the_profile(self):
        for i in range(5):
            self.add('Please check fictional sample '+str(i)+'.', i)
        self.extract()
        examples = style_corpus.selected_messages(self.a)
        self.assertEqual(style_corpus.summary(self.a, verified_messages=examples[:1])['extraction_status'], 'stale')

    def test_unverified_provider_examples_never_validate_a_ready_profile(self):
        self.add_native_indexed_sent(6)
        style_corpus.extract(self.a, 'fixture', ['operator@fixture.invalid'], author_confirmed=True)
        examples = self.a.selected_style_messages()
        examples[0]['snapshot_hash_verified'] = False
        self.assertEqual(self.a.style_summary(verified_messages=examples)['extraction_status'], 'stale')

    def test_native_index_snapshot_hashes_support_many_samples_without_claiming_live_mail(self):
        self.add_native_indexed_sent(12)
        result = style_corpus.extract(self.a, 'fixture', ['operator@fixture.invalid'], author_confirmed=True)
        self.assertEqual(result['example_count'], 12)
        provider = style_corpus.selected_messages(self.a)
        self.assertEqual(len(provider), 3)
        for message in provider:
            self.assertEqual(message['origin'], 'apple_mail_index_snapshot')
            self.assertTrue(message['snapshot_hash_verified'])
            self.assertFalse(message['range_verified'])
            self.assertFalse(message['live_verified'])
        self.assertEqual(self.a.style_summary(verify=True), result)
        self.assertEqual(len(self.a.selected_style_messages()), 3)
        mid = provider[0]['id']
        payload = self.a.db.execute('SELECT payload FROM messages WHERE id=?', (mid,)).fetchone()[0]
        changed = json.loads(payload)
        changed['body_text'] = 'Changed fictional captured snapshot.'
        with self.a.db:
            self.a.db.execute('UPDATE messages SET payload=? WHERE id=?', (packed(changed), mid))
        with self.assertRaisesRegex(ArchiveError, 'STYLE_SOURCE_UNAVAILABLE'):
            style_corpus.selected_messages(self.a)
        self.assertEqual(self.a.style_summary(verify=True)['extraction_status'], 'stale')

    def test_more_than_512_indexed_samples_stop_at_the_sample_cap_without_corpus_scan(self):
        self.add_native_indexed_sent(600)
        result = style_corpus.extract(self.a, 'fixture', ['operator@fixture.invalid'],
                                      author_confirmed=True, token_budget=131072)
        info = result['sample_info']
        self.assertEqual(result['example_count'], 512)
        self.assertEqual(info['selected_messages'], 512)
        self.assertEqual(info['candidates_checked'], 512)
        self.assertEqual(info['source_verifications'], 512)
        self.assertTrue(info['coverage']['selection_capped'])
        self.assertFalse(info['coverage']['candidate_window_exhausted'])
        self.assertLess(info['candidates_fetched'], 600)
        self.assertLessEqual(info['token_estimate'], info['token_budget'])
        self.assertEqual(len(style_corpus.selected_messages(self.a)), 3)

    def test_pathological_stale_catalog_rows_fail_with_a_query_budget(self):
        self.add_native_indexed_sent(128)
        with self.a.db:
            self.a.db.execute('UPDATE mail_index_catalog SET last_seen_epoch=0')
        with patch.object(style_corpus, 'SEARCH_MAX_VM_STEPS', 1):
            with self.assertRaisesRegex(ArchiveError, 'STYLE_CANDIDATE_QUERY_BUDGET_NARROW_REQUIRED'):
                self.extract()
        self.assertFalse(style_corpus.has_profile(self.a))

    def test_candidate_window_and_selection_have_constant_caps_and_indexed_work(self):
        # The actual small source is reused only for bounded body verification.
        # Additional fictional catalog rows measure SQL work at increasing N.
        base, _, _ = self.add('Please check a fictional bounded sample.')
        metadata_hash = digest(b'fictional scaling metadata')
        measurements = []
        for count in (128, 1024, 4096, 8192):
            with self.a.db:
                self.a.db.execute('DELETE FROM mail_index_catalog')
                self.a.db.executemany('INSERT INTO mail_index_catalog(locator_id,account_id,mailbox_path,native_id,message_id,subject,sender,normalized_from,date,direction,message_size,is_local,metadata_hash,last_seen_epoch,current_message,body_status,failure) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                                      [(f'{i:08d}', 'fixture', '["Sent"]', str(i), 'fixture@fixture.invalid',
                                        'Fictional fixture', 'operator@fixture.invalid', 'operator@fixture.invalid',
                                        '2026-10-08T00:00:00+00:00', 'sent', 128, 1, metadata_hash, 1, base, 'captured', '')
                                       for i in range(count)])
            steps = [0]
            self.a._sql_step_observer = lambda amount: steps.__setitem__(0, steps[0]+amount)
            start = time.perf_counter()
            result = self.extract()
            elapsed = time.perf_counter()-start
            self.a._sql_step_observer = None
            info = result['sample_info']
            measurements.append({'catalog_rows': count, 'candidates_checked': info['candidates_checked'],
                                 'sqlite_vm_steps': steps[0], 'wall_seconds': elapsed})
            self.assertLessEqual(info['candidates_fetched'], 4096)
            self.assertLessEqual(info['candidate_queries'], 65)
            self.assertLessEqual(info['selected_messages'], 512)
            self.assertEqual(info['selected_messages'], 1)
        # Duplicate mail bodies still require at most the explicit candidate
        # window, so this negative case documents that work rather than hiding it.
        self.assertEqual([r['candidates_checked'] for r in measurements], [128, 1024, 4096, 4096])
        self.assertLessEqual(measurements[-1]['sqlite_vm_steps'], measurements[-2]['sqlite_vm_steps']*1.1+100)
        self.assertTrue(all(r['wall_seconds'] > 0 for r in measurements))
        print('FICTIONAL_STYLE_CANDIDATE_CAPS '+json.dumps(measurements, separators=(',', ':')))


if __name__ == '__main__':
    unittest.main()
