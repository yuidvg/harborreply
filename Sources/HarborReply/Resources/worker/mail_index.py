"""Resumable public-Mail catalog. No Mail calls, raw MIME copies or network."""
import datetime as dt
import email.policy
import email.utils
from email.parser import Parser
import json
import re
import sqlite3
import uuid

from archive import ArchiveError, MAX_BODY, MAX_CASE_MESSAGES, digest, now, packed, tokens

MAX_PAGE = 128
MAX_DISCOVERY = 32
MAX_IPC_BYTES = 2 * 1024 * 1024
MAX_METADATA_BYTES = 16_384
NATIVE_PREFIX = 'native:'
BODY_STATES = ('metadata_only', 'captured', 'unreadable', 'too_large')

SCHEMA = '''
CREATE TABLE IF NOT EXISTS mail_index_state(
 id INTEGER PRIMARY KEY CHECK(id=1),scan_id TEXT NOT NULL DEFAULT '',epoch INTEGER NOT NULL DEFAULT 0,
 completed_epoch INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL DEFAULT 'idle',
 discovery_checkpoint TEXT NOT NULL DEFAULT 'null',discovery_done INTEGER NOT NULL DEFAULT 0,
 mailbox_count INTEGER NOT NULL DEFAULT 0,mailboxes_done INTEGER NOT NULL DEFAULT 0,
 metadata_count INTEGER NOT NULL DEFAULT 0,captured_count INTEGER NOT NULL DEFAULT 0,
 unreadable_count INTEGER NOT NULL DEFAULT 0,too_large_count INTEGER NOT NULL DEFAULT 0,
 metadata_only_count INTEGER NOT NULL DEFAULT 0,body_bytes INTEGER NOT NULL DEFAULT 0,
 pages INTEGER NOT NULL DEFAULT 0,warning TEXT NOT NULL DEFAULT '',updated_at TEXT NOT NULL DEFAULT '');
INSERT OR IGNORE INTO mail_index_state(id) VALUES(1);
CREATE TABLE IF NOT EXISTS mail_index_accounts(account_id TEXT PRIMARY KEY,payload TEXT NOT NULL,last_seen_epoch INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS mail_index_mailboxes(
 mailbox_id TEXT PRIMARY KEY,account_id TEXT NOT NULL,mailbox_path TEXT NOT NULL,name TEXT NOT NULL,
 message_count INTEGER NOT NULL,role TEXT NOT NULL,is_local INTEGER NOT NULL,
 epoch INTEGER NOT NULL,status TEXT NOT NULL DEFAULT 'pending',cursor TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS mail_index_queue ON mail_index_mailboxes(epoch,status,mailbox_id);
CREATE TABLE IF NOT EXISTS mail_index_catalog(
 locator_id TEXT PRIMARY KEY,account_id TEXT NOT NULL,mailbox_path TEXT NOT NULL,native_id TEXT NOT NULL,
 message_id TEXT NOT NULL,subject TEXT NOT NULL,sender TEXT NOT NULL,normalized_from TEXT NOT NULL,
 date TEXT NOT NULL DEFAULT '',direction TEXT NOT NULL,message_size INTEGER NOT NULL,is_local INTEGER NOT NULL,
 attachment_count INTEGER,metadata_hash TEXT NOT NULL,last_seen_epoch INTEGER NOT NULL,
 current_message TEXT REFERENCES messages(id),body_status TEXT NOT NULL,failure TEXT NOT NULL,
 body_bytes INTEGER NOT NULL DEFAULT 0,search_rowid INTEGER);
CREATE INDEX IF NOT EXISTS mail_index_mailbox ON mail_index_catalog(account_id,mailbox_path,is_local,last_seen_epoch);
CREATE INDEX IF NOT EXISTS mail_index_header ON mail_index_catalog(message_id);
CREATE INDEX IF NOT EXISTS mail_index_current ON mail_index_catalog(current_message);
CREATE INDEX IF NOT EXISTS mail_index_style ON mail_index_catalog(account_id,direction,normalized_from,body_status,date DESC,locator_id ASC);
CREATE TABLE IF NOT EXISTS mail_index_versions(
 message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,locator_id TEXT NOT NULL,
 metadata_hash TEXT NOT NULL,body_hash TEXT NOT NULL,captured_at TEXT NOT NULL,scan_epoch INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS mail_index_versions_locator ON mail_index_versions(locator_id);
CREATE TABLE IF NOT EXISTS mail_index_pages(
 scan_id TEXT NOT NULL,kind TEXT NOT NULL,mailbox_id TEXT NOT NULL,checkpoint_hash TEXT NOT NULL,
 request_hash TEXT NOT NULL,PRIMARY KEY(scan_id,kind,mailbox_id,checkpoint_hash));
'''


def text(value, limit, error='INDEX_RECORD_INVALID'):
    if not isinstance(value, str) or len(value) > limit: raise ArchiveError(error)
    return value


def path_parts(value):
    if not isinstance(value, list) or not 1 <= len(value) <= 32: raise ArchiveError('INDEX_MAILBOX_PATH')
    return [metadata_text(part, 'INDEX_MAILBOX_PATH') for part in value]


def metadata_text(value, error='INDEX_RECORD_INVALID'):
    value = text(value, MAX_METADATA_BYTES, error)
    if len(value.encode()) > MAX_METADATA_BYTES: raise ArchiveError(error)
    return value


def canonical_json(value):
    # JSON object order changes across Foundation/Python IPC round trips.
    # Preserve arrays and value types while comparing object content recursively.
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=True)


def cursor_json(value):
    result = canonical_json(value)
    if len(result.encode()) > MAX_IPC_BYTES: raise ArchiveError('INDEX_CURSOR_LIMIT')
    return result


def utc_date(value):
    if not value: return ''
    if not isinstance(value, str) or len(value) > 128: raise ArchiveError('INDEX_DATE_INVALID')
    try:
        result = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if not result.tzinfo: return ''
        return result.astimezone(dt.timezone.utc).isoformat()
    except ValueError: return ''


def direction_for(record):
    role = record.get('direction', record.get('role', 'unknown'))
    role = {'inbox': 'received', 'drafts': 'draft'}.get(role, role)
    if role not in ('sent', 'received', 'draft', 'unknown'): raise ArchiveError('INDEX_DIRECTION_INVALID')
    return role


class MailIndex:
    def __init__(self, archive):
        self.archive = archive; self.db = archive.db
        self.db.executescript(SCHEMA)

    def completed_epoch(self):
        return self.db.execute('SELECT completed_epoch FROM mail_index_state WHERE id=1').fetchone()[0]

    def _state(self): return self.db.execute('SELECT * FROM mail_index_state WHERE id=1').fetchone()

    def _guard(self, scan_id, epoch):
        state = self._state()
        if state['scan_id'] != scan_id or type(epoch) is not int or state['epoch'] != epoch:
            raise ArchiveError('INDEX_SCAN_CHANGED')
        if state['status'] != 'running': raise ArchiveError('INDEX_NOT_RUNNING')
        return state

    def status(self):
        state = self._state()
        return {'scan_id': state['scan_id'], 'epoch': state['epoch'], 'completed_epoch': state['completed_epoch'],
                'status': state['status'], 'discovery_checkpoint': json.loads(state['discovery_checkpoint']),
                'discovery_done': bool(state['discovery_done']),
                'counts': {'mailboxes': state['mailbox_count'], 'mailboxes_done': state['mailboxes_done'],
                           'metadata': state['metadata_count'], 'captured': state['captured_count'],
                           'unreadable': state['unreadable_count'], 'too_large': state['too_large_count'],
                           'metadata_only': state['metadata_only_count'], 'body_bytes': state['body_bytes'], 'pages': state['pages']},
                'warning': state['warning'], 'updated_at': state['updated_at'],
                'origin': 'apple_mail_index_snapshot', 'live_verified': False, 'attachments_fetched': False}

    def start(self, restart=False):
        if type(restart) is not bool: raise ArchiveError('INDEX_RESTART_INVALID')
        with self.db:
            self.db.execute('BEGIN IMMEDIATE'); state = self._state()
            if not restart and state['status'] in ('running', 'paused'):
                self.db.execute("UPDATE mail_index_state SET status='running',updated_at=? WHERE id=1", (now(),))
            else:
                self.db.execute("UPDATE mail_index_state SET scan_id=?,epoch=epoch+1,status='running',discovery_checkpoint='null',discovery_done=0,mailbox_count=0,mailboxes_done=0,metadata_count=0,captured_count=0,unreadable_count=0,too_large_count=0,metadata_only_count=0,body_bytes=0,pages=0,warning='',updated_at=? WHERE id=1", (str(uuid.uuid4()), now()))
            self.archive.bump()
        return self.status()

    def _retry(self, scan_id, kind, mailbox_id, expected, request_hash):
        key = digest(expected.encode())
        prior = self.db.execute('SELECT request_hash FROM mail_index_pages WHERE scan_id=? AND kind=? AND mailbox_id=? AND checkpoint_hash=?', (scan_id, kind, mailbox_id, key)).fetchone()
        if prior:
            if prior[0] != request_hash: raise ArchiveError('INDEX_PAGE_RETRY_CHANGED')
            return True
        return False

    def _save_page(self, scan_id, kind, mailbox_id, expected, request_hash):
        self.db.execute('INSERT INTO mail_index_pages VALUES(?,?,?,?,?)', (scan_id, kind, mailbox_id, digest(expected.encode()), request_hash))

    def discovery(self, scan_id, epoch, expected_checkpoint, checkpoint, mailboxes, done, accounts=()):
        if not isinstance(mailboxes, list) or len(mailboxes) > MAX_DISCOVERY or not isinstance(accounts, (list, tuple)) or len(accounts) > MAX_DISCOVERY or type(done) is not bool:
            raise ArchiveError('INDEX_DISCOVERY_LIMIT')
        expected = cursor_json(expected_checkpoint); following = cursor_json(checkpoint)
        request = canonical_json([following, mailboxes, done, accounts]); request_hash = digest(request.encode())
        if len(request.encode()) > MAX_IPC_BYTES: raise ArchiveError('IPC_INPUT_LIMIT')
        prepared = []; seen = set()
        for box in mailboxes:
            if not isinstance(box, dict): raise ArchiveError('INDEX_MAILBOX_INVALID')
            account = metadata_text(box.get('accountID', ''))
            path = path_parts(box.get('mailboxPath', box.get('path')))
            count = box.get('messageCount', 0); local = box.get('isLocal', False)
            if type(count) is not int or count < 0 or type(local) is not bool: raise ArchiveError('INDEX_MAILBOX_INVALID')
            role = direction_for(box); mid = digest(packed([account, path, local]).encode())
            if mid in seen: raise ArchiveError('INDEX_DUPLICATE_MAILBOX')
            seen.add(mid)
            initial = {'scanID': scan_id, 'accountID': account, 'mailboxPath': path, 'offset': 0,
                       'expectedCount': count, 'isLocal': local, 'role': role}
            prepared.append((mid, account, packed(path), metadata_text(box.get('name', path[-1])), count, role, int(local), epoch, cursor_json(initial)))
        with self.db:
            self.db.execute('BEGIN IMMEDIATE'); state = self._guard(scan_id, epoch)
            if self._retry(scan_id, 'discovery', '', expected, request_hash): return self.status()
            if state['discovery_done'] or cursor_json(json.loads(state['discovery_checkpoint'])) != expected: raise ArchiveError('INDEX_CHECKPOINT_CHANGED')
            for account in accounts:
                if not isinstance(account, dict): raise ArchiveError('INDEX_ACCOUNT_INVALID')
                aid = metadata_text(account.get('id', account.get('accountID', '')))
                self.db.execute('INSERT INTO mail_index_accounts VALUES(?,?,?) ON CONFLICT(account_id) DO UPDATE SET payload=excluded.payload,last_seen_epoch=excluded.last_seen_epoch', (aid, packed(account), epoch))
            added = 0
            for row in prepared:
                existing = self.db.execute('SELECT epoch FROM mail_index_mailboxes WHERE mailbox_id=?', (row[0],)).fetchone()
                if not existing or existing[0] != epoch:
                    self.db.execute("INSERT INTO mail_index_mailboxes(mailbox_id,account_id,mailbox_path,name,message_count,role,is_local,epoch,cursor) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(mailbox_id) DO UPDATE SET account_id=excluded.account_id,mailbox_path=excluded.mailbox_path,name=excluded.name,message_count=excluded.message_count,role=excluded.role,is_local=excluded.is_local,epoch=excluded.epoch,status='pending',cursor=excluded.cursor", row)
                    added += 1
            self.db.execute('UPDATE mail_index_state SET discovery_checkpoint=?,discovery_done=?,mailbox_count=mailbox_count+?,updated_at=? WHERE id=1', (following, int(done), added, now()))
            self._save_page(scan_id, 'discovery', '', expected, request_hash); self.archive.bump()
        return self.status()

    def rewind_mailbox(self, scan_id, epoch, mailbox_id, expected_checkpoint):
        # The old snapshots remain readable until this scan completes. Only the
        # affected folder's progress and receipts are invalidated, atomically.
        with self.db:
            self.db.execute('BEGIN IMMEDIATE'); self._guard(scan_id, epoch)
            box = self.db.execute('SELECT * FROM mail_index_mailboxes WHERE mailbox_id=? AND epoch=?', (mailbox_id, epoch)).fetchone()
            if box is None: raise ArchiveError('INDEX_MAILBOX_NOT_FOUND')
            if box['status'] != 'pending' or cursor_json(json.loads(box['cursor'])) != cursor_json(expected_checkpoint):
                raise ArchiveError('INDEX_CHECKPOINT_CHANGED')
            cursor = dict(json.loads(box['cursor']), offset=0, expectedCount=None)
            scope = (box['account_id'], box['mailbox_path'], box['is_local'], epoch)
            counts = self.db.execute('SELECT body_status,count(*) AS n,coalesce(sum(body_bytes),0) AS bytes FROM mail_index_catalog WHERE account_id=? AND mailbox_path=? AND is_local=? AND last_seen_epoch=? GROUP BY body_status', scope).fetchall()
            totals = {row['body_status']: row['n'] for row in counts}
            self.db.execute('UPDATE mail_index_state SET metadata_count=metadata_count-?,captured_count=captured_count-?,metadata_only_count=metadata_only_count-?,unreadable_count=unreadable_count-?,too_large_count=too_large_count-?,body_bytes=body_bytes-?,updated_at=? WHERE id=1',
                            (sum(totals.values()), totals.get('captured',0), totals.get('metadata_only',0), totals.get('unreadable',0), totals.get('too_large',0), sum(row['bytes'] for row in counts), now()))
            self.db.execute('UPDATE mail_index_catalog SET last_seen_epoch=? WHERE account_id=? AND mailbox_path=? AND is_local=? AND last_seen_epoch=?', (epoch-1, *scope))
            self.db.execute('DELETE FROM mail_index_pages WHERE scan_id=? AND kind=? AND mailbox_id=?', (scan_id, 'mailbox', mailbox_id))
            self.db.execute('UPDATE mail_index_mailboxes SET cursor=? WHERE mailbox_id=?', (cursor_json(cursor), mailbox_id))
            self.archive.bump()
        return self.status()

    def next(self, scan_id, epoch):
        self._guard(scan_id, epoch)
        box = self.db.execute("SELECT * FROM mail_index_mailboxes WHERE epoch=? AND status='pending' ORDER BY mailbox_id LIMIT 1", (epoch,)).fetchone()
        if not box: return {'mailbox_id': None, 'mailbox': None, 'cursor': None}
        return {'mailbox_id': box['mailbox_id'], 'mailbox': {'accountID': box['account_id'], 'mailboxPath': json.loads(box['mailbox_path']),
                'name': box['name'], 'messageCount': box['message_count'], 'role': box['role'], 'isLocal': bool(box['is_local'])},
                'cursor': json.loads(box['cursor'])}

    def _prepare_record(self, record, mailbox, epoch):
        if not isinstance(record, dict): raise ArchiveError('INDEX_RECORD_INVALID')
        account = metadata_text(record.get('accountID', '')); path = path_parts(record.get('mailboxPath'))
        native_id = text(record.get('nativeID', record.get('id', '')), 512)
        local = record.get('isLocal', bool(mailbox['is_local']))
        if not native_id or type(local) is not bool or (account, packed(path), int(local)) != (mailbox['account_id'], mailbox['mailbox_path'], mailbox['is_local']):
            raise ArchiveError('INDEX_RECORD_WRONG_MAILBOX')
        direction = direction_for(record)
        if direction != mailbox['role']: raise ArchiveError('INDEX_ROLE_CHANGED')
        subject = metadata_text(record.get('subject', '')); sender = metadata_text(record.get('sender', ''))
        message_id = metadata_text(record.get('messageID', '')).strip('<>')
        size = record.get('messageSize', 0); count = record.get('attachmentCount')
        if type(size) is not int or size < 0 or count is not None and (type(count) is not int or not 0 <= count <= 10000): raise ArchiveError('INDEX_RECORD_INVALID')
        date_sent = utc_date(record.get('dateSent'))
        date_received = utc_date(record.get('dateReceived'))
        date = date_sent or utc_date(record.get('date')) or date_received
        address = next((address.casefold() for _, address in email.utils.getaddresses([sender]) if '@' in address), '')
        header_text = text(record.get('headers', ''), 32768)
        headers = Parser(policy=email.policy.default).parsestr(header_text, headersonly=True)
        references = re.findall(r'<([^<>\s]+)>', str(headers.get('References', '')) + ' ' + str(headers.get('In-Reply-To', '')))
        if len(references) > 60: raise ArchiveError('HEADER_REFERENCES_LIMIT')
        metadata = {'account_id': account, 'mailbox_path': path, 'native_id': native_id, 'message_id': message_id,
                    'subject': subject, 'from': sender, 'date': date, 'date_sent': date_sent, 'date_received': date_received,
                    'direction': direction, 'is_local': local,
                    'message_size': size, 'attachment_count': count, 'references': list(dict.fromkeys(references))}
        metadata_hash = digest(packed(metadata).encode()); locator = digest(packed([account, path, native_id, local]).encode())
        body_status = record.get('bodyStatus', 'captured' if 'body' in record else 'metadata_only')
        if body_status not in BODY_STATES: raise ArchiveError('INDEX_BODY_STATUS_INVALID')
        if body_status == 'captured' and 'body' not in record: raise ArchiveError('INDEX_CAPTURED_BODY_REQUIRED')
        failure = text(record.get('failure', ''), 512); body = record.get('body', '')
        if not isinstance(body, str): raise ArchiveError('INDEX_RECORD_INVALID')
        if len(body) > MAX_BODY: body_status = 'too_large'; failure = 'BODY_LIMIT'; body = ''
        if body_status != 'captured': body = ''
        body_hash = digest(body.encode()); version_id = digest(packed([locator, metadata_hash, body_hash]).encode()) if body_status == 'captured' else None
        return {'locator_id': locator, 'metadata': metadata, 'metadata_hash': metadata_hash, 'normalized_from': address,
                'body_status': body_status, 'failure': failure, 'body': body, 'body_hash': body_hash,
                'version_id': version_id, 'body_bytes': len(body.encode()), 'epoch': epoch}

    def page(self, scan_id, epoch, mailbox_id, expected_checkpoint, checkpoint, records, done):
        if not isinstance(records, list) or len(records) > MAX_PAGE or type(done) is not bool: raise ArchiveError('INDEX_PAGE_LIMIT')
        expected = cursor_json(expected_checkpoint); following = cursor_json(checkpoint)
        request = canonical_json([following, records, done]); encoded = request.encode()
        if len(encoded) > MAX_IPC_BYTES: raise ArchiveError('IPC_INPUT_LIMIT')
        request_hash = digest(encoded)
        mailbox = self.db.execute('SELECT * FROM mail_index_mailboxes WHERE mailbox_id=? AND epoch=?', (mailbox_id, epoch)).fetchone()
        if mailbox is None: raise ArchiveError('INDEX_MAILBOX_NOT_FOUND')
        prepared = [self._prepare_record(record, mailbox, epoch) for record in records]
        locators = [r['locator_id'] for r in prepared]
        if len(set(locators)) != len(locators): raise ArchiveError('INDEX_DUPLICATE_RECORD')
        mids = []
        with self.db:
            self.db.execute('BEGIN IMMEDIATE'); self._guard(scan_id, epoch)
            if self._retry(scan_id, 'mailbox', mailbox_id, expected, request_hash):
                return dict(self.status(), message_ids=[r['version_id'] for r in prepared if r['version_id']])
            current = self.db.execute('SELECT cursor,status FROM mail_index_mailboxes WHERE mailbox_id=?', (mailbox_id,)).fetchone()
            if current['status'] != 'pending' or cursor_json(json.loads(current['cursor'])) != expected: raise ArchiveError('INDEX_CHECKPOINT_CHANGED')
            changed_locators = []
            for record in prepared:
                old = self.db.execute('SELECT * FROM mail_index_catalog WHERE locator_id=?', (record['locator_id'],)).fetchone()
                if self._upsert(record, old): changed_locators.append(record['locator_id'])
                mids.extend([record['version_id']] if record['version_id'] else [])
            if changed_locators: self._invalidate_style(changed_locators)
            self.db.execute('UPDATE mail_index_mailboxes SET cursor=?,status=? WHERE mailbox_id=?', (following, 'done' if done else 'pending', mailbox_id))
            self.db.execute('UPDATE mail_index_state SET pages=pages+1,mailboxes_done=mailboxes_done+?,updated_at=? WHERE id=1', (int(done), now()))
            self._save_page(scan_id, 'mailbox', mailbox_id, expected, request_hash); self.archive.bump()
        return dict(self.status(), message_ids=mids)

    def _upsert(self, record, old):
        metadata = record['metadata']; locator = record['locator_id']; version = record['version_id']
        if version:
            payload = self._payload(record)
            inserted = self.db.execute('INSERT OR IGNORE INTO messages VALUES(?,?,?,?,?)', (version, metadata['message_id'], metadata['date'] or None, record['body_hash'], packed(payload)))
            if inserted.rowcount:
                self.db.execute("UPDATE meta SET value=value+1 WHERE key='message_count'")
                self.db.execute("UPDATE meta SET value=value+? WHERE key='body_bytes'", (record['body_bytes'],))
                self.db.execute('INSERT INTO mail_index_versions VALUES(?,?,?,?,?,?)', (version, locator, record['metadata_hash'], record['body_hash'], payload['ingestion_time'], record['epoch']))
                self.db.executemany('INSERT OR IGNORE INTO reply_edges VALUES(?,?)', ((version, parent) for parent in metadata['references']))
        # The saved FTS rowid gives indexed updates. WHERE id=? on an UNINDEXED
        # FTS column would walk all source rows on every incremental page.
        rowid = old['search_rowid'] if old else None
        changed = old is None or (old['metadata_hash'], old['current_message'], old['body_status'], old['failure']) != (record['metadata_hash'], version, record['body_status'], record['failure'])
        if changed or old['last_seen_epoch'] != record['epoch']:
            if rowid is not None: self.db.execute('DELETE FROM search WHERE rowid=?', (rowid,))
            self.db.execute('INSERT INTO search VALUES(?,?)', (NATIVE_PREFIX+locator, ' '.join(tokens(metadata['subject']+'\n'+metadata['from']+'\n'+record['body']))))
            rowid = self.db.execute('SELECT last_insert_rowid()').fetchone()[0]
        if changed:
            if old and old['current_message'] and self.db.execute('SELECT 1 FROM styles WHERE message_id=?', (old['current_message'],)).fetchone(): self.archive.invalidate_style_extraction()
        self.db.execute('INSERT INTO mail_index_catalog VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(locator_id) DO UPDATE SET account_id=excluded.account_id,mailbox_path=excluded.mailbox_path,native_id=excluded.native_id,message_id=excluded.message_id,subject=excluded.subject,sender=excluded.sender,normalized_from=excluded.normalized_from,date=excluded.date,direction=excluded.direction,message_size=excluded.message_size,is_local=excluded.is_local,attachment_count=excluded.attachment_count,metadata_hash=excluded.metadata_hash,last_seen_epoch=excluded.last_seen_epoch,current_message=excluded.current_message,body_status=excluded.body_status,failure=excluded.failure,body_bytes=excluded.body_bytes,search_rowid=excluded.search_rowid',
                        (locator, metadata['account_id'], packed(metadata['mailbox_path']), metadata['native_id'], metadata['message_id'], metadata['subject'], metadata['from'], record['normalized_from'], metadata['date'], metadata['direction'], metadata['message_size'], int(metadata['is_local']), metadata['attachment_count'], record['metadata_hash'], record['epoch'], version, record['body_status'], record['failure'], record['body_bytes'], rowid))
        old_counted = old is not None and old['last_seen_epoch'] == record['epoch']
        delta = {kind: int(record['body_status'] == kind) - int(old_counted and old['body_status'] == kind) for kind in BODY_STATES}
        self.db.execute('UPDATE mail_index_state SET metadata_count=metadata_count+?,captured_count=captured_count+?,metadata_only_count=metadata_only_count+?,unreadable_count=unreadable_count+?,too_large_count=too_large_count+?,body_bytes=body_bytes+? WHERE id=1',
                        (int(not old_counted), delta['captured'], delta['metadata_only'], delta['unreadable'], delta['too_large'], record['body_bytes']-(old['body_bytes'] if old_counted else 0)))
        return changed

    def _payload(self, record):
        metadata = record['metadata']; count = metadata['attachment_count']
        attachments = [] if count == 0 else [{'name': '(original attachments not fetched)', 'media_type': 'application/octet-stream', 'size': 0, 'parse_status': 'not_fetched', 'reported_count': count}]
        return {'id': record['version_id'], 'message_id': metadata['message_id'], 'in_reply_to': metadata['references'],
                'references': metadata['references'], 'from': metadata['from'], 'to': '', 'cc': '', 'reply_to': '',
                'date': metadata['date'] or None, 'date_sent': metadata['date_sent'] or None,
                'date_received': metadata['date_received'] or None, 'date_parse_status': 'parsed' if metadata['date'] else 'unknown',
                'subject': metadata['subject'], 'account_id': metadata['account_id'], 'direction': metadata['direction'],
                'body_text': record['body'], 'body_hash': record['body_hash'], 'parser_version': 'native-plaintext-1',
                'attachments': attachments, 'sections': [], 'internal': False, 'ingestion_time': now(),
                'body_bytes': record['body_bytes'], 'attachment_bytes': 0, 'origin': 'apple_mail_index_snapshot',
                'attachments_fetched': False, 'live_verified': False, 'locator_id': record['locator_id']}

    def _invalidate_style(self, changed_locators=None):
        stored = self.db.execute('SELECT payload,manifest FROM style_corpus_profile WHERE id=1').fetchone()
        if not stored: return
        manifest = json.loads(stored['manifest'])
        # An address-scoped Sent acquisition has its own immutable journal and
        # lifecycle. Global discovery/scan epochs cannot make it stale.
        if manifest and all(entry.get('origin') == 'style_capture' for entry in manifest): return
        if changed_locators is not None:
            affected = set(changed_locators)
            if not any(entry.get('locator_id') in affected for entry in manifest): return
        else:
            epoch = self.completed_epoch(); stale = False
            for entry in manifest:
                row = self.db.execute('SELECT c.current_message,c.metadata_hash,c.last_seen_epoch,m.body_hash FROM mail_index_catalog c LEFT JOIN messages m ON m.id=c.current_message WHERE c.locator_id=?', (entry['locator_id'],)).fetchone()
                if row is None or row['last_seen_epoch'] < epoch or any(row[key] != entry[saved] for key, saved in (('current_message', 'message_id'), ('metadata_hash', 'metadata_hash'), ('body_hash', 'body_hash'))):
                    stale = True; break
            if not stale: return
        # Invalidate aggregate/profile provenance with indexed point checks on
        # its <=512 selected manifest, rather than every catalog row.
        value = json.loads(stored['payload']); value.update(self.archive.empty_style_extraction('stale'))
        self.db.execute('UPDATE style_corpus_profile SET payload=? WHERE id=1', (packed(value),))

    def finish(self, scan_id, epoch, expected_checkpoint=None, status='complete', warning=''):
        if status not in ('complete', 'paused'): raise ArchiveError('INDEX_FINISH_STATUS')
        warning = text(warning, 1024, 'INDEX_WARNING_LIMIT')
        with self.db:
            self.db.execute('BEGIN IMMEDIATE'); state = self._guard(scan_id, epoch)
            if expected_checkpoint is not None and cursor_json(json.loads(state['discovery_checkpoint'])) != cursor_json(expected_checkpoint): raise ArchiveError('INDEX_CHECKPOINT_CHANGED')
            if status == 'complete':
                if not state['discovery_done'] or state['mailboxes_done'] != state['mailbox_count']: raise ArchiveError('INDEX_SCAN_INCOMPLETE')
                self.db.execute('UPDATE mail_index_state SET completed_epoch=? WHERE id=1', (epoch,))
                self._invalidate_style()
            self.db.execute('UPDATE mail_index_state SET status=?,warning=?,updated_at=? WHERE id=1', (status, warning, now())); self.archive.bump()
        return self.status()

    def _catalog(self, search_id):
        if search_id.startswith(NATIVE_PREFIX):
            return self.db.execute('SELECT * FROM mail_index_catalog WHERE locator_id=?', (search_id[len(NATIVE_PREFIX):],)).fetchone()
        return self.db.execute('SELECT c.* FROM mail_index_versions v JOIN mail_index_catalog c ON c.locator_id=v.locator_id WHERE v.message_id=?', (search_id,)).fetchone()

    def rank_metadata(self, search_id):
        if not search_id.startswith(NATIVE_PREFIX): return None
        row = self.db.execute('SELECT locator_id,current_message,message_id,subject,sender,last_seen_epoch FROM mail_index_catalog WHERE locator_id=?', (search_id[len(NATIVE_PREFIX):],)).fetchone()
        if row is None or row['last_seen_epoch'] < self.completed_epoch(): return {}
        return {'id': row['current_message'] or search_id, 'subject': row['subject'], 'sender': row['sender'], 'messageID': row['message_id']}

    def message(self, mid, verify=True):
        row = self._catalog(mid)
        if row is None: return None
        if mid.startswith(NATIVE_PREFIX):
            if row['current_message']: return self.message(row['current_message'], verify)
            return {'id': mid, 'subject': row['subject'], 'date': row['date'] or None, 'direction': row['direction'],
                    'source_status': row['body_status'], 'attachments': [], 'origin': 'apple_mail_index_snapshot',
                    'attachments_fetched': False, 'live_verified': False, 'body_text': '', 'from': row['sender'], 'body_hash': ''}
        version = self.db.execute('SELECT * FROM mail_index_versions WHERE message_id=?', (mid,)).fetchone()
        saved = self.db.execute('SELECT payload FROM messages WHERE id=?', (mid,)).fetchone()
        if version is None or saved is None: return None
        message = json.loads(saved[0])
        valid = row['current_message'] == mid and row['metadata_hash'] == version['metadata_hash'] and row['last_seen_epoch'] >= self.completed_epoch()
        if verify: valid = valid and digest(message['body_text'].encode()) == version['body_hash'] == message['body_hash']
        message.update(source_status='available' if valid else 'missing_or_changed', range_verified=False,
                       snapshot_hash_verified=bool(valid and verify),
                       snapshot={'origin': 'apple_mail_index_snapshot', 'native_id': row['native_id'], 'account_id': row['account_id'],
                                 'mailbox_path': json.loads(row['mailbox_path']), 'captured_at': version['captured_at'],
                                 'date_sent': message.get('date_sent'), 'date_received': message.get('date_received'),
                                 'scan_epoch': version['scan_epoch'], 'live_verified': False, 'attachments_fetched': False})
        return message

    def preview(self, mid):
        row = self._catalog(mid)
        if row is None: return None
        valid = row['current_message'] == mid and row['last_seen_epoch'] >= self.completed_epoch()
        count = row['attachment_count']
        return {'id': mid, 'subject': row['subject'], 'date': row['date'] or None, 'direction': row['direction'],
                'source_status': 'available' if valid else row['body_status'] if not row['current_message'] else 'missing_or_changed',
                'attachments': [] if count == 0 else [{'name': '(original attachments not fetched)', 'media_type': 'application/octet-stream', 'size': 0, 'parse_status': 'not_fetched', 'reported_count': count}],
                'origin': 'apple_mail_index_snapshot', 'attachments_fetched': False, 'live_verified': False}
