"""Private derived Mail snapshots from fictional records; no Apple events."""
import json
import os
from pathlib import Path
import stat
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive, ArchiveError
from context import build_context
from main import dispatch
import test_archive as fixtures


class MailSnapshotTests(unittest.TestCase):
    setUp = fixtures.ArchiveTests.setUp
    tearDown = fixtures.ArchiveTests.tearDown

    def record(self, **changes):
        return dict({'id': 'native-fixture', 'accountID': 'fixture-account.invalid', 'mailbox': 'Sent fixture',
                     'messageID': 'fixture@history.invalid', 'subject': 'AWS billing overview',
                     'sender': 'person@owner.invalid', 'body': 'Thank you for your message.\n\nPlease send the details.',
                     'headers': 'Message-ID: <original@history.invalid>\r\nReferences: <parent@history.invalid>\r\nIn-Reply-To: <parent@history.invalid>\r\nDate: Thu, 08 Oct 2026 09:00:00 +0900\r\nContent-Type: multipart/mixed; boundary=unfetched\r\nBcc: hidden@fixture.invalid\r\n',
                     'direction': 'sent', 'attachmentCount': 0}, **changes)

    def test_plaintext_snapshot_has_private_stable_identity_and_whitelisted_headers(self):
        record = self.record()
        response = dispatch({'db': str(self.root/'state/db.sqlite'), 'command': 'mail_snapshot', 'records': [record]})
        mid = response['message_ids'][0]
        self.assertEqual(response['origin'], 'apple_mail_readonly_snapshot')
        self.assertFalse(response['attachments_fetched'])
        message = self.a.message(mid)
        self.assertEqual(message['origin'], response['origin'])
        self.assertEqual(message['message_id'], record['messageID'])
        self.assertEqual(message['references'], ['parent@history.invalid'])
        self.assertEqual(message['in_reply_to'], ['parent@history.invalid'])
        self.assertEqual(message['bcc'] if 'bcc' in message else '', '')
        self.assertEqual(message['body_text'].replace('\r\n', '\n').strip(), record['body'])
        self.assertFalse(message['attachments'])
        self.assertEqual(message['direction'], 'sent')
        paths = list(self.a.snapshot_directory.glob('*.eml'))
        self.assertEqual(len(paths), 1)
        self.assertEqual(stat.S_IMODE(self.a.snapshot_directory.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(paths[0].stat().st_mode), 0o600)
        raw = paths[0].read_text()
        self.assertIn('Content-Type: text/plain;', raw)
        self.assertNotIn('multipart/mixed', raw); self.assertNotIn('Bcc:', raw)
        revision = self.a.revision()
        self.assertEqual(self.a.ingest_mail_snapshot([record])['message_ids'], [mid])
        self.assertEqual(self.a.coverage()['count'], 1)
        self.assertEqual(self.a.revision(), revision)
        self.a.db.close(); self.a = Archive(self.root/'state/db.sqlite')
        self.assertEqual(self.a.message(mid)['snapshot']['native_id'], record['id'])
        self.assertEqual(self.a.ingest_mail_snapshot([record])['message_ids'], [mid])

    def test_direction_and_authorship_are_separate_and_captures_cannot_silently_merge(self):
        sent = self.a.ingest_mail_snapshot([self.record()])['message_ids'][0]
        received = self.a.ingest_mail_snapshot([self.record(direction='received', mailbox='Inbox fixture')])['message_ids'][0]
        unknown = self.a.ingest_mail_snapshot([self.record(direction='unknown')])['message_ids'][0]
        other_account = self.a.ingest_mail_snapshot([self.record(accountID='second-account.invalid')])['message_ids'][0]
        self.assertEqual(len({sent, received, unknown, other_account}), 4)
        self.assertEqual(self.a.style_summary()['example_count'], 0)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_SENT_AUTHOR_REQUIRED'):
            self.a.style_replace([sent], 'true')
        for mid in (received, unknown):
            with self.assertRaisesRegex(ArchiveError, 'STYLE_SENT_AUTHOR_REQUIRED'):
                self.a.style_replace([mid], True)
        self.a.style_replace([sent], True)
        self.assertEqual(self.a.style_extract()['example_count'], 1)
        self.assertEqual(self.a.message(received)['direction'], 'received')

    def test_missing_or_present_attachments_remain_unknown_and_snapshot_is_not_live_original(self):
        for index, count in enumerate((None, 2, 0)):
            mid = self.a.ingest_mail_snapshot([self.record(id='native-'+str(index), messageID=str(index)+'@history.invalid', attachmentCount=count)])['message_ids'][0]
            message = self.a.message(mid)
            if count is None or count > 0:
                self.assertEqual(message['attachments'][0]['parse_status'], 'not_fetched')
                self.assertEqual(message['attachments'][0]['reported_count'], count)
            else: self.assertEqual(message['attachments'], [])
            preview = self.a.candidate_previews([mid])[0]
            self.assertEqual(preview['origin'], 'apple_mail_readonly_snapshot')
            self.assertFalse(preview['attachments_fetched'])
            self.assertNotIn('body_text', preview); self.assertNotIn('snapshot', preview)
            case_id = self.a.case_create('Fictional snapshot case '+str(index)); self.a.membership(case_id, mid, True)
            context = build_context(self.a, {'id': 'new', 'body': 'Different fictional current text.'}, case_id=case_id)
            self.assertIn('現在のMail原本は照合していません', ' '.join(context['local_warnings']))
            if count is None or count > 0: self.assertIn('未解析添付', ' '.join(context['local_warnings']))

    def test_all_records_are_validated_before_bounded_private_writes(self):
        invalid_inputs = [[], [self.record(id=str(i)) for i in range(21)],
                          [self.record(), self.record(id='other', body='x'*12001)],
                          [self.record(direction='draft')], [self.record(attachmentCount=True)],
                          [self.record(subject='safe\r\nBcc: attacker@fixture.invalid')],
                          [self.record(), self.record()]]
        for records in invalid_inputs:
            with self.subTest(records=len(records)):
                with self.assertRaises(ArchiveError): self.a.ingest_mail_snapshot(records)
                self.assertFalse(self.a.snapshot_directory.exists())
                self.assertEqual(self.a.coverage()['count'], 0)
        records = [self.record(id=str(i), messageID=str(i)+'@history.invalid', body='x'*12000) for i in range(20)]
        self.assertEqual(len(self.a.ingest_mail_snapshot(records)['message_ids']), 20)
        self.assertEqual(self.a.coverage()['count'], 20)

    def test_changed_snapshot_or_symlink_fails_closed(self):
        record = self.record(); mid = self.a.ingest_mail_snapshot([record])['message_ids'][0]
        path = next(self.a.snapshot_directory.glob('*.eml'))
        raw = path.read_bytes(); path.write_bytes(raw.replace(b'Thank you', b'Thunk you'))
        self.assertEqual(self.a.message(mid)['source_status'], 'missing_or_changed')
        with self.assertRaisesRegex(ArchiveError, 'MAIL_SNAPSHOT_FILE_CHANGED'):
            self.a.ingest_mail_snapshot([record])
        # A fresh private subdirectory cannot be redirected to another location.
        second = Archive(self.root/'second/db.sqlite')
        try:
            target = self.root/'redirect'; target.mkdir()
            second.snapshot_directory.symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(ArchiveError, 'SYMLINK_NOT_ALLOWED'):
                second.ingest_mail_snapshot([record])
            self.assertEqual(list(target.iterdir()), [])
        finally: second.db.close()

    def test_app_owned_database_alias_is_canonicalized_but_imported_aliases_stay_denied(self):
        actual = self.root/'canonical-app-state'; actual.mkdir()
        alias = self.root/'app-state-alias'; alias.symlink_to(actual, target_is_directory=True)
        second = Archive(alias/'db.sqlite')
        try:
            response = second.ingest_mail_snapshot([self.record()])
            self.assertEqual(second.snapshot_directory, actual/'mail-snapshots')
            mid = response['message_ids'][0]
            self.assertEqual(second.message(mid)['source_status'], 'available')
            self.assertEqual(second.ingest_mail_snapshot([self.record()])['message_ids'], [mid])
            stored = second.db.execute('SELECT path FROM sources').fetchone()[0]
            self.assertTrue(stored.startswith(str(actual/'mail-snapshots')))
            # Canonicalizing generated storage does not weaken source safety.
            selected = actual/'selected.eml'; selected.write_bytes(fixtures.mail().as_bytes())
            with self.assertRaisesRegex(ArchiveError, 'SYMLINK_NOT_ALLOWED'):
                second.add_source(alias/'selected.eml', 'received', '', False)
        finally: second.db.close()


if __name__ == '__main__': unittest.main()
