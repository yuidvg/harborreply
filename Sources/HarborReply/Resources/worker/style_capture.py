"""Private, bounded Sent acquisition journal, independent of the global index.

Native records arrive through the read-only Swift Mail bridge. Only complete
authored text within the budget is retained; quoted source text is discarded
after its hash is recorded. A partial or cancelled journal cannot publish a
profile. No Apple Mail, file source, network, or global-index operation occurs.
"""
import json
import uuid

from archive import ArchiveError, MAX_BODY, authored_text, digest, now, packed
from mail_index import canonical_json
import style_corpus as styles

MAX_PAGE_RECORDS = 20
MAX_PAGE_HEADERS = 128
MAX_CHECKPOINT_BYTES = 64 * 1024
MAX_REQUEST_BYTES = 1_500_000
ORIGIN = 'apple_mail_sent_style_snapshot'
CONTENT_MODE = 'sent_contents'
SCHEMA = (
    '''CREATE TABLE IF NOT EXISTS style_capture_state(
      id INTEGER PRIMARY KEY CHECK(id=1),capture_id TEXT NOT NULL,
      account_id TEXT NOT NULL,address TEXT NOT NULL,author TEXT NOT NULL,
      token_budget INTEGER NOT NULL,status TEXT NOT NULL,checkpoint TEXT NOT NULL,
      candidates_checked INTEGER NOT NULL DEFAULT 0,records_received INTEGER NOT NULL DEFAULT 0,
      captured INTEGER NOT NULL DEFAULT 0,token_estimate INTEGER NOT NULL DEFAULT 0,
      skipped TEXT NOT NULL,pages INTEGER NOT NULL DEFAULT 0,acquisition_done INTEGER NOT NULL DEFAULT 0,
      source_exhausted INTEGER NOT NULL DEFAULT 0,updated_at TEXT NOT NULL)''',
    '''CREATE TABLE IF NOT EXISTS style_capture_samples(
      capture_id TEXT NOT NULL,locator_id TEXT NOT NULL,message_id TEXT NOT NULL UNIQUE,
      sequence INTEGER NOT NULL,metadata_hash TEXT NOT NULL,body_hash TEXT NOT NULL,
      source_body_hash TEXT NOT NULL,payload TEXT NOT NULL,
      PRIMARY KEY(capture_id,locator_id))''',
    '''CREATE INDEX IF NOT EXISTS style_capture_order ON style_capture_samples(capture_id,sequence)''',
    '''CREATE INDEX IF NOT EXISTS style_capture_dedup ON style_capture_samples(capture_id,body_hash)''',
    '''CREATE TABLE IF NOT EXISTS style_capture_pages(
      capture_id TEXT NOT NULL,checkpoint_hash TEXT NOT NULL,request_hash TEXT NOT NULL,
      PRIMARY KEY(capture_id,checkpoint_hash))''',
)


def ensure_schema(archive):
    for statement in SCHEMA:
        archive.db.execute(statement)


def checkpoint_json(value):
    value = canonical_json(value)
    if len(value.encode('utf-8')) > MAX_CHECKPOINT_BYTES:
        raise ArchiveError('STYLE_CAPTURE_CHECKPOINT_LIMIT')
    return value


def message(archive, message_id, verify=True):
    row = archive.db.execute('SELECT * FROM style_capture_samples WHERE message_id=?', (message_id,)).fetchone()
    if row is None:
        raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
    value = json.loads(row['payload'])
    valid = (value.get('id') == row['message_id'] and value.get('body_hash') == row['body_hash']
             and value.get('origin') == ORIGIN and value.get('source_body_hash') == row['source_body_hash'])
    if value.get('collection_mode') == CONTENT_MODE:
        # These are only checksums over this private snapshot. They never
        # identify or reread a Mail message, and cannot prove live identity.
        scope = {key: value.get(key) for key in ('account_id', 'mailbox_path', 'position', 'from', 'direction',
                                                'collection_mode', 'identity_verification')}
        snapshot = value.get('snapshot', {})
        valid = (valid and digest(packed(scope).encode('utf-8')) == row['metadata_hash']
                 and digest(packed([row['capture_id'], value.get('mailbox_path'), value.get('position')]).encode('utf-8')) == row['locator_id']
                 and value.get('identity_verification') == 'not_performed'
                 and snapshot.get('collection_mode') == CONTENT_MODE
                 and snapshot.get('identity_verification') == 'not_performed'
                 and snapshot.get('position_is_native_identity') is False
                 and snapshot.get('headers_fetched') is False)
    if verify:
        valid = valid and digest(value.get('body_text', '').encode('utf-8')) == row['body_hash']
    value.update(source_status='available' if valid else 'missing_or_changed',
                 range_verified=False, snapshot_hash_verified=bool(valid and verify),
                 live_verified=False, attachments_fetched=False)
    return value


def manifest_valid(archive, entries, author):
    for entry in entries:
        row = archive.db.execute('SELECT * FROM style_capture_samples WHERE capture_id=? AND locator_id=?',
                                 (entry.get('capture_id'), entry['locator_id'])).fetchone()
        if (row is None or row['message_id'] != entry['message_id'] or row['body_hash'] != entry['body_hash']
                or row['metadata_hash'] != entry['metadata_hash']):
            return False
        value = message(archive, row['message_id'], verify=False)
        if (value.get('id') != row['message_id'] or value.get('body_hash') != row['body_hash']
                or value.get('origin') != ORIGIN or value.get('source_body_hash') != row['source_body_hash']
                or value.get('source_status') != 'available'
                or not styles._author_matches(value, author)):
            return False
    return True


class StyleCapture:
    def __init__(self, archive):
        self.archive = archive
        self.db = archive.db
        ensure_schema(archive)

    def _state(self, capture_id=None):
        row = self.db.execute('SELECT * FROM style_capture_state WHERE id=1').fetchone()
        if row is None or capture_id is not None and row['capture_id'] != capture_id:
            raise ArchiveError('STYLE_CAPTURE_CHANGED')
        return row

    def status(self, capture_id=None):
        row = self._state(capture_id)
        # A complete nonempty sample needs at least one UTF-8 byte plus its
        # framing charge. Stop when that minimum cannot fit, even if a small
        # remainder is left; the native caller must not keep acquiring bodies
        # that can no longer contribute to the profile.
        budget_reached = row['token_estimate'] + styles.SAMPLE_FRAMING_UNITS + 1 > row['token_budget']
        reason = ('sample_limit' if row['captured'] >= styles.MAX_SAMPLES else
                  'candidate_limit' if row['candidates_checked'] >= styles.MAX_CANDIDATES else
                  'token_budget' if budget_reached else '')
        return {'capture_id': row['capture_id'], 'account_id': row['account_id'], 'address': row['address'],
                'status': row['status'], 'checkpoint': json.loads(row['checkpoint']), 'pages': row['pages'],
                'acquisition_done': bool(row['acquisition_done']),
                'resume_available': row['status'] in ('running', 'paused', 'cancelled', 'complete'),
                'counts': {key: row[key] for key in ('candidates_checked', 'records_received', 'captured', 'token_estimate')},
                'token_budget': row['token_budget'], 'candidate_limit': styles.MAX_CANDIDATES,
                'sample_limit': styles.MAX_SAMPLES, 'budget_reached': budget_reached,
                'should_stop': bool(reason), 'stop_reason': reason, 'skipped': json.loads(row['skipped']),
                'coverage': {'snapshot_only': True,
                             'strategy': 'bounded_sent_contents' if self._content_checkpoint(row['checkpoint']) else 'bounded_mail_order',
                             'source_exhausted': bool(row['source_exhausted'])}}

    @staticmethod
    def _content_checkpoint(checkpoint):
        value = json.loads(checkpoint) if isinstance(checkpoint, str) else checkpoint
        return isinstance(value, dict) and value.get('collection_mode') == CONTENT_MODE

    def _validate_journal(self, state, author):
        """Check bounded retained state before reusing a partially acquired corpus.

        This verifies private snapshots, not current Mail content. The native
        caller must separately compare its saved page witness with Mail before
        advancing a resumed checkpoint.
        """
        rows = self.db.execute('SELECT * FROM style_capture_samples WHERE capture_id=? ORDER BY sequence LIMIT ?',
                               (state['capture_id'], styles.MAX_SAMPLES+1)).fetchall()
        if (len(rows) != state['captured'] or len(rows) > styles.MAX_SAMPLES
                or not 0 <= state['records_received'] <= state['candidates_checked'] <= styles.MAX_CANDIDATES
                or state['records_received'] < state['captured']
                or self.db.execute('SELECT count(*) FROM style_capture_pages WHERE capture_id=?',
                                   (state['capture_id'],)).fetchone()[0] != state['pages']):
            raise ArchiveError('STYLE_CAPTURE_JOURNAL_CHANGED')
        used = 0
        for sequence, row in enumerate(rows, 1):
            value = message(self.archive, row['message_id'], verify=True)
            expected_id = 'style:'+digest(packed([state['capture_id'], row['locator_id'],
                                                 row['metadata_hash'], row['body_hash']]).encode('utf-8'))
            if (row['sequence'] != sequence or value['source_status'] != 'available'
                    or row['message_id'] != expected_id or value.get('locator_id') != row['locator_id']
                    or not styles._author_matches(value, author)):
                raise ArchiveError('STYLE_CAPTURE_JOURNAL_CHANGED')
            used += styles.conservative_units(value['body_text'])
        if used != state['token_estimate'] or used > state['token_budget']:
            raise ArchiveError('STYLE_CAPTURE_JOURNAL_CHANGED')
        skipped = json.loads(state['skipped'])
        if (not isinstance(skipped, dict)
                or set(skipped) != {'duplicate', 'empty', 'over_budget', 'source_unavailable', 'sample_limit'}
                or any(type(count) is not int or count < 0 for count in skipped.values())
                or sum(skipped.values()) + state['captured'] != state['records_received']):
            raise ArchiveError('STYLE_CAPTURE_JOURNAL_CHANGED')

    def _retain(self, active_capture_id):
        retained = {active_capture_id}
        profile = self.db.execute('SELECT manifest FROM style_corpus_profile WHERE id=1').fetchone()
        if profile:
            retained.update(entry.get('capture_id') for entry in json.loads(profile[0]) if entry.get('origin') == 'style_capture')
        values = sorted(value for value in retained if value)
        placeholders = ','.join('?' for _ in values)
        self.db.execute('DELETE FROM style_capture_samples WHERE capture_id NOT IN ('+placeholders+')', values)
        self.db.execute('DELETE FROM style_capture_pages WHERE capture_id!=?', (active_capture_id,))

    def start(self, account_id, selected_address, own_addresses, shared_addresses=(),
              author_confirmed=False, token_budget=styles.DEFAULT_TOKEN_BUDGET, restart=True):
        if author_confirmed is not True:
            raise ArchiveError('STYLE_SENT_AUTHOR_REQUIRED')
        if not isinstance(account_id, str) or not account_id or len(account_id) > 1024:
            raise ArchiveError('STYLE_ACCOUNT_REQUIRED')
        if type(token_budget) is not int or not 64 <= token_budget <= styles.MAX_TOKEN_BUDGET:
            raise ArchiveError('STYLE_TOKEN_BUDGET_INVALID')
        if type(restart) is not bool:
            raise ArchiveError('STYLE_CAPTURE_RESTART_INVALID')
        own = styles._addresses(own_addresses)
        shared = styles._addresses(shared_addresses)
        selected = styles.address(selected_address)
        if not selected or selected not in own or selected in shared:
            raise ArchiveError('STYLE_PERSONAL_ADDRESS_REQUIRED')
        author = {'account_id': account_id, 'own_addresses': [selected], 'author_confirmed': True,
                  'selected_address': selected}
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            old = self.db.execute('SELECT * FROM style_capture_state WHERE id=1').fetchone()
            same_config = old and (old['account_id'], old['address'], old['token_budget'], old['author']) == (
                account_id, selected, token_budget, packed(author))
            if not restart and same_config and old['status'] in ('running', 'paused', 'cancelled', 'complete'):
                self._validate_journal(old, author)
                # Completion and publication are separate transactions. If a
                # response was lost (or cancellation intervened), retry only
                # the local analysis rather than acquiring the same Mail again.
                status = 'complete' if old['acquisition_done'] or old['status'] == 'complete' else 'running'
                self.db.execute('UPDATE style_capture_state SET status=?,updated_at=? WHERE id=1', (status, now()))
                return self.status(old['capture_id'])
            capture_id = str(uuid.uuid4())
            skipped = {key: 0 for key in ('duplicate', 'empty', 'over_budget', 'source_unavailable', 'sample_limit')}
            self.db.execute('''INSERT OR REPLACE INTO style_capture_state(
                id,capture_id,account_id,address,author,token_budget,status,checkpoint,skipped,updated_at)
                VALUES(1,?,?,?,?,?,'running','null',?,?)''',
                            (capture_id, account_id, selected, packed(author), token_budget, packed(skipped), now()))
            self._retain(capture_id)
        return self.status(capture_id)

    def page(self, capture_id, expected_checkpoint, checkpoint, records, candidates_checked, done=False):
        expected, following, request_hash = self._page_request(expected_checkpoint, checkpoint, records,
                                                              candidates_checked, done)
        state = self._state(capture_id)
        if state['status'] != 'running':
            raise ArchiveError('STYLE_CAPTURE_NOT_RUNNING')
        if self._content_checkpoint(state['checkpoint']) or self._content_checkpoint(checkpoint):
            raise ArchiveError('STYLE_CAPTURE_SOURCE_CHANGED')
        prepared = []
        for record in records:
            if not isinstance(record, dict):
                raise ArchiveError('STYLE_CAPTURE_RECORD_INVALID')
            if 'cacheSnapshot' in record and type(record['cacheSnapshot']) is not bool:
                raise ArchiveError('STYLE_CAPTURE_RECORD_INVALID')
            if record.get('accountID') != state['account_id']:
                raise ArchiveError('STYLE_CAPTURE_WRONG_ACCOUNT')
            if record.get('direction', record.get('role')) != 'sent' or record.get('isLocal', False) is not False:
                raise ArchiveError('STYLE_CAPTURE_SENT_REQUIRED')
            if styles.address(record.get('sender', '')) != state['address']:
                raise ArchiveError('STYLE_CAPTURE_WRONG_ADDRESS')
            # Reuse only the pure native-record parser. No global scan, catalog,
            # counters, version table, source or FTS entry is touched.
            path = record.get('mailboxPath')
            mailbox = {'account_id': state['account_id'], 'mailbox_path': packed(path), 'is_local': 0, 'role': 'sent'}
            value = self.archive.mail_index._prepare_record(record, mailbox, 0)
            value['cache_snapshot'] = record.get('cacheSnapshot') is True
            prepared.append(value)
        return self._commit_page(capture_id, expected, following, request_hash, prepared,
                                 candidates_checked, done)

    @staticmethod
    def _page_request(expected_checkpoint, checkpoint, records, candidates_checked, done, content_only=False):
        if (not isinstance(records, list) or len(records) > MAX_PAGE_RECORDS or type(candidates_checked) is not int
                or not 0 <= candidates_checked <= MAX_PAGE_HEADERS or type(done) is not bool):
            raise ArchiveError('STYLE_CAPTURE_PAGE_LIMIT')
        expected = checkpoint_json(expected_checkpoint)
        following = checkpoint_json(checkpoint)
        fields = [following, records, candidates_checked, done]
        # Native page retries retain their existing hash. The new command has
        # a separate request domain; neither path can replay the other's data.
        request = canonical_json([CONTENT_MODE]+fields if content_only else fields)
        if len(request.encode('utf-8')) > MAX_REQUEST_BYTES:
            raise ArchiveError('STYLE_CAPTURE_INPUT_LIMIT')
        return expected, following, digest(request.encode('utf-8'))

    def content_page(self, capture_id, expected_checkpoint, checkpoint, records, candidates_checked, done=False):
        """Retain bounded text from a selected author's genuine Sent scope.

        Position is only a capture-local collection slot. It is deliberately
        neither a native Mail identifier nor evidence of stable/live identity.
        This path does not call the native-record parser, Mail, or the index.
        """
        expected, following, request_hash = self._page_request(expected_checkpoint, checkpoint, records,
                                                              candidates_checked, done, content_only=True)
        state = self._state(capture_id)
        if state['status'] != 'running':
            raise ArchiveError('STYLE_CAPTURE_NOT_RUNNING')
        if (not self._content_checkpoint(checkpoint)
                or state['checkpoint'] != 'null' and not self._content_checkpoint(state['checkpoint'])):
            raise ArchiveError('STYLE_CAPTURE_SOURCE_CHANGED')
        prepared = [self._prepare_content(state, record) for record in records]
        return self._commit_page(capture_id, expected, following, request_hash, prepared,
                                 candidates_checked, done)

    @staticmethod
    def _prepare_content(state, record):
        if (not isinstance(record, dict)
                or set(record)-{'position', 'mailbox_path', 'sender', 'body', 'nativeCode'}):
            raise ArchiveError('STYLE_CAPTURE_RECORD_INVALID')
        position = record.get('position')
        path = record.get('mailbox_path')
        sender = record.get('sender')
        body = record.get('body')
        native_code = record.get('nativeCode')
        if (type(position) is not int or not 1 <= position <= 2**31-1
                or not isinstance(path, list) or not 1 <= len(path) <= 32
                or any(not isinstance(part, str) or not part or len(part.encode('utf-8')) > 16_384 for part in path)
                or not isinstance(sender, str) or len(sender.encode('utf-8')) > 16_384
                or body is not None and not isinstance(body, str)
                or native_code is not None and (type(native_code) is not int or native_code not in (-1712, -1708))
                or body is not None and native_code is not None):
            raise ArchiveError('STYLE_CAPTURE_RECORD_INVALID')
        if styles.address(sender) != state['address']:
            raise ArchiveError('STYLE_CAPTURE_WRONG_ADDRESS')
        if body is not None and len(body) > MAX_BODY:
            raise ArchiveError('STYLE_CAPTURE_INPUT_LIMIT')
        scope = {'account_id': state['account_id'], 'mailbox_path': path, 'position': position,
                 'from': sender, 'direction': 'sent', 'collection_mode': CONTENT_MODE,
                 'identity_verification': 'not_performed'}
        slot = digest(packed([state['capture_id'], path, position]).encode('utf-8'))
        text = body if body is not None else ''
        return {'locator_id': slot, 'metadata_hash': digest(packed(scope).encode('utf-8')),
                'body_status': 'captured' if body is not None else 'unreadable',
                'body': text, 'body_hash': digest(text.encode('utf-8')), 'cache_snapshot': False,
                'content_payload': dict(scope, locator_id=slot)}

    def _commit_page(self, capture_id, expected, following, request_hash, prepared, candidates_checked, done):
        locators = [value['locator_id'] for value in prepared]
        if len(locators) != len(set(locators)):
            raise ArchiveError('STYLE_CAPTURE_DUPLICATE_RECORD')
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            state = self._state(capture_id)
            if state['status'] != 'running':
                raise ArchiveError('STYLE_CAPTURE_NOT_RUNNING')
            expected_hash = digest(expected.encode('utf-8'))
            retry = self.db.execute('SELECT request_hash FROM style_capture_pages WHERE capture_id=? AND checkpoint_hash=?',
                                    (capture_id, expected_hash)).fetchone()
            if retry:
                if retry[0] != request_hash:
                    raise ArchiveError('STYLE_CAPTURE_RETRY_CHANGED')
                return self.status(capture_id)
            if state['checkpoint'] != expected:
                raise ArchiveError('STYLE_CAPTURE_CHECKPOINT_CHANGED')
            checked = state['candidates_checked'] + candidates_checked
            received = state['records_received'] + len(prepared)
            if checked > styles.MAX_CANDIDATES or received > checked:
                raise ArchiveError('STYLE_CAPTURE_CANDIDATE_LIMIT')
            if following == expected and not done:
                raise ArchiveError('STYLE_CAPTURE_NO_PROGRESS')
            captured = state['captured']
            used = state['token_estimate']
            skipped = json.loads(state['skipped'])
            for value in prepared:
                old = self.db.execute('SELECT source_body_hash,metadata_hash FROM style_capture_samples WHERE capture_id=? AND locator_id=?',
                                      (capture_id, value['locator_id'])).fetchone()
                if old:
                    if old['source_body_hash'] != value['body_hash'] or old['metadata_hash'] != value['metadata_hash']:
                        raise ArchiveError('STYLE_CAPTURE_SOURCE_CHANGED')
                    skipped['duplicate'] += 1
                    continue
                if value['body_status'] != 'captured':
                    skipped['source_unavailable'] += 1
                    continue
                text = authored_text(value['body'])
                if not text:
                    skipped['empty'] += 1
                    continue
                authored_hash = digest(text.encode('utf-8'))
                if self.db.execute('SELECT 1 FROM style_capture_samples WHERE capture_id=? AND body_hash=? LIMIT 1',
                                   (capture_id, authored_hash)).fetchone():
                    skipped['duplicate'] += 1
                    continue
                if captured >= styles.MAX_SAMPLES:
                    skipped['sample_limit'] += 1
                    continue
                charge = styles.conservative_units(text)
                if used + charge > state['token_budget']:
                    skipped['over_budget'] += 1
                    continue
                content_only = 'content_payload' in value
                payload = dict(value['content_payload']) if content_only else self.archive.mail_index._payload(value)
                mid = 'style:'+digest(packed([capture_id, value['locator_id'], value['metadata_hash'], authored_hash]).encode('utf-8'))
                payload.update(id=mid, body_text=text, body_hash=authored_hash, body_bytes=len(text.encode('utf-8')),
                               origin=ORIGIN, source_body_hash=value['body_hash'],
                               parser_version='sent-content-authored-style-1' if content_only else 'native-authored-style-1',
                               snapshot={'origin': ORIGIN, 'capture_id': capture_id, 'captured_at': now(),
                                         'live_verified': False, 'original_mime_fetched': False,
                                         'quoted_text_excluded': True, 'attachments_fetched': False})
                payload['snapshot']['reused_cached_body'] = value['cache_snapshot']
                if content_only:
                    payload['snapshot'].update(collection_mode=CONTENT_MODE, identity_verification='not_performed',
                                               position_is_native_identity=False, headers_fetched=False)
                captured += 1
                used += charge
                self.db.execute('INSERT INTO style_capture_samples VALUES(?,?,?,?,?,?,?,?)',
                                (capture_id, value['locator_id'], mid, captured, value['metadata_hash'], authored_hash,
                                 value['body_hash'], packed(payload)))
            self.db.execute('''UPDATE style_capture_state SET checkpoint=?,candidates_checked=?,records_received=?,
                captured=?,token_estimate=?,skipped=?,pages=pages+1,acquisition_done=?,updated_at=? WHERE id=1''',
                            (following, checked, received, captured, used, packed(skipped), int(done), now()))
            self.db.execute('INSERT INTO style_capture_pages VALUES(?,?,?)', (capture_id, expected_hash, request_hash))
        return self.status(capture_id)

    def finish(self, capture_id, status='complete', source_exhausted=False):
        if status not in ('complete', 'paused', 'cancelled') or type(source_exhausted) is not bool:
            raise ArchiveError('STYLE_CAPTURE_FINISH_INVALID')
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            state = self._state(capture_id)
            if state['status'] == 'published' and status != 'cancelled':
                return self.status(capture_id)
            if state['status'] == status == 'complete':
                if bool(state['source_exhausted']) != source_exhausted:
                    raise ArchiveError('STYLE_CAPTURE_FINISH_CHANGED')
                return self.status(capture_id)
            allowed = ('running', 'paused', 'complete', 'published', 'cancelled') if status == 'cancelled' else ('running', status)
            if state['status'] not in allowed:
                raise ArchiveError('STYLE_CAPTURE_NOT_RUNNING')
            if status == 'cancelled':
                profile = self.db.execute('SELECT payload,manifest FROM style_corpus_profile WHERE id=1').fetchone()
                if (profile and json.loads(profile['payload']).get('extraction_status') == 'ready'
                        and any(entry.get('origin') == 'style_capture' and entry.get('capture_id') == capture_id
                                for entry in json.loads(profile['manifest']))):
                    value = json.loads(profile['payload'])
                    value.update(self.archive.empty_style_extraction('stale'))
                    self.db.execute('UPDATE style_corpus_profile SET payload=? WHERE id=1', (packed(value),))
                    self.archive.bump()
            self.db.execute('''UPDATE style_capture_state SET status=?,
                acquisition_done=CASE WHEN ?='complete' THEN 1 ELSE acquisition_done END,
                source_exhausted=CASE WHEN ?='complete' THEN ? ELSE source_exhausted END,
                updated_at=? WHERE id=1''',
                            (status, status, status, int(source_exhausted), now()))
        return self.status(capture_id)

    def extract(self, capture_id):
        state = self._state(capture_id)
        if state['status'] == 'published':
            # An exact retry after a lost publication response is read-only.
            # Do not bump the archive revision or create a second publication.
            profile = self.db.execute('SELECT payload,manifest,author FROM style_corpus_profile WHERE id=1').fetchone()
            author = json.loads(state['author'])
            self._validate_journal(state, author)
            manifest = json.loads(profile['manifest']) if profile else []
            if (not profile or profile['author'] != state['author']
                    or len(manifest) != state['captured']
                    or len({entry.get('locator_id') for entry in manifest}) != len(manifest)
                    or not all(entry.get('capture_id') == capture_id and entry.get('origin') == 'style_capture'
                               for entry in manifest)
                    or not manifest_valid(self.archive, manifest, author)):
                raise ArchiveError('STYLE_CAPTURE_JOURNAL_CHANGED')
            summary = json.loads(profile['payload'])
            if summary.get('extraction_status') != 'ready':
                raise ArchiveError('STYLE_CAPTURE_INCOMPLETE')
            return summary
        if state['status'] != 'complete':
            raise ArchiveError('STYLE_CAPTURE_INCOMPLETE')
        rows = self.db.execute('SELECT * FROM style_capture_samples WHERE capture_id=? ORDER BY sequence LIMIT ?',
                               (capture_id, styles.MAX_SAMPLES+1)).fetchall()
        if not 1 <= len(rows) <= styles.MAX_SAMPLES:
            raise ArchiveError('STYLE_INDEXED_SENT_EXAMPLES_REQUIRED')
        revision = self.archive.revision()
        author = json.loads(state['author'])
        texts = []
        manifest = []
        provider = []
        provider_bytes = 0
        content_only = self._content_checkpoint(state['checkpoint'])
        for row in rows:
            value = message(self.archive, row['message_id'], verify=True)
            if value['source_status'] != 'available' or not styles._author_matches(value, author):
                raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
            text = value['body_text']
            texts.append(text)
            entry = {'origin': 'style_capture', 'capture_id': capture_id, 'locator_id': row['locator_id'],
                     'message_id': row['message_id'], 'body_hash': row['body_hash'],
                     'authored_hash': row['body_hash'], 'metadata_hash': row['metadata_hash']}
            manifest.append(entry)
            size = len(text.encode('utf-8'))
            if (len(provider) < styles.PROVIDER_EXAMPLE_LIMIT and size <= styles.PROVIDER_EXAMPLE_BYTES
                    and provider_bytes + size <= styles.PROVIDER_TOTAL_BYTES):
                provider.append(entry)
                provider_bytes += size
        summary = self.archive.style_traits(texts)
        description = self.archive.describe_style(summary)
        phrases = self.archive.neutral_source_phrases(texts)
        description = self.archive.style_source_description(description, phrases)
        summary.update(extraction_status='ready', description=description, source_phrases=phrases,
                       description_origin='observed_format_traits', extracted_at=now(),
                       source_address=state['address'], source_account_id=state['account_id'],
                       corpus_version=styles.PROFILE_VERSION,
                       sample_info={'selected_messages': len(rows), 'token_estimate': state['token_estimate'],
                                    'token_budget': state['token_budget'], 'token_unit': 'utf8_bytes_upper_bound',
                                    'token_estimate_is_exact': False, 'sample_framing_units': styles.SAMPLE_FRAMING_UNITS,
                                    'candidates_checked': state['candidates_checked'], 'candidates_fetched': state['candidates_checked'],
                                    'candidate_queries': state['pages'], 'candidate_limit': styles.MAX_CANDIDATES,
                                    'sample_limit': styles.MAX_SAMPLES, 'skipped': json.loads(state['skipped']),
                                    'source_verifications': 0 if content_only else len(rows),
                                    'snapshot_hash_verifications': len(rows), 'provider_example_count': len(provider),
                                    'provider_example_bytes': provider_bytes,
                                    'coverage': {'scope': 'selected_address_sent_contents' if content_only else 'selected_address_native_sent',
                                                 'strategy': 'bounded_sent_contents' if content_only else 'bounded_mail_order',
                                                 'candidate_window_exhausted': bool(state['source_exhausted']),
                                                 'selection_capped': not bool(state['source_exhausted']), 'snapshot_only': True,
                                                 'identity_verification': 'not_performed' if content_only else 'native_metadata_snapshot',
                                                 'native_identity_verified': False if content_only else True,
                                                 'generation_source_verification': 'private_snapshot_only' if content_only else 'bounded_provider_examples_only'}})
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            checked = self._state(capture_id)
            if checked['status'] != 'complete' or self.archive.revision() != revision:
                raise ArchiveError('STYLE_CHANGED_DURING_EXTRACTION')
            if not manifest_valid(self.archive, manifest, author):
                raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
            self.db.execute('INSERT OR REPLACE INTO style_corpus_profile VALUES(1,?,?,?,?)',
                            (packed(summary), packed(manifest), packed(provider), packed(author)))
            self.db.execute("UPDATE style_capture_state SET status='published',updated_at=? WHERE id=1", (now(),))
            self._retain(capture_id)
            self.archive.bump()
        return summary
