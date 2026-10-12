"""Explicit local style extraction over indexed, confirmed authored Sent mail.

This never calls a model or reads Apple Mail. Complete authored samples are
charged by UTF-8 bytes, a conservative byte-token upper bound rather than a
model-specific tokenizer measurement. The archive, candidate window, sample
count and optional provider excerpts have independent bounds.
"""
import email.utils
import json
import re

from archive import ArchiveError, SEARCH_MAX_SECONDS, SEARCH_MAX_VM_STEPS, authored_text, digest, now, packed

DEFAULT_TOKEN_BUDGET = 32_768
MAX_TOKEN_BUDGET = 131_072
MAX_SAMPLES = 512
MAX_CANDIDATES = 4096
PAGE_SIZE = 64
MAX_ADDRESSES = 32
SAMPLE_FRAMING_UNITS = 32
PROVIDER_EXAMPLE_LIMIT = 3
PROVIDER_EXAMPLE_BYTES = 2048
PROVIDER_TOTAL_BYTES = 4096
PROFILE_VERSION = 'local-style-corpus-1'
STYLE_CORPUS_SCHEMA = '''
CREATE TABLE IF NOT EXISTS style_corpus_profile(
 id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT,manifest TEXT,
 provider_manifest TEXT,author TEXT);
'''

# Each alias has its own ordered index stream. A global ORDER BY after IN can
# sort every Sent message; merging <=64 buffered rows per alias avoids that.
CANDIDATE_SQL = '''SELECT locator_id,current_message,date,metadata_hash
 FROM mail_index_catalog INDEXED BY mail_index_style
 WHERE account_id=? AND direction='sent' AND normalized_from=?
 AND body_status='captured' AND last_seen_epoch>=?
 {cursor_clause}
 ORDER BY date DESC,locator_id LIMIT ?'''
MANIFEST_SQL = '''SELECT c.account_id,c.direction,c.normalized_from,c.current_message,
 c.metadata_hash,c.body_status,c.last_seen_epoch,m.body_hash
 FROM mail_index_catalog c LEFT JOIN messages m ON m.id=c.current_message
 WHERE c.locator_id=?'''


def ensure_schema(archive):
    archive.db.execute(STYLE_CORPUS_SCHEMA)
    import style_capture
    style_capture.ensure_schema(archive)


def has_profile(archive):
    ensure_schema(archive)
    return archive.db.execute('SELECT 1 FROM style_corpus_profile WHERE id=1').fetchone() is not None


def clear(archive):
    ensure_schema(archive)
    archive.db.execute('DELETE FROM style_corpus_profile WHERE id=1')


def address(value):
    """Accept exactly one mailbox, never a multiple-address or injected header."""
    if not isinstance(value, str) or len(value) > 1024 or '\r' in value or '\n' in value:
        return ''
    pairs = email.utils.getaddresses([value])
    if len(pairs) != 1:
        return ''
    result = pairs[0][1].strip().casefold()
    if result.count('@') != 1 or re.search(r'[\s<>,;:\[\]]', result):
        return ''
    local, domain = result.split('@')
    return result if local and domain else ''


def _addresses(values):
    if not isinstance(values, (list, tuple)) or len(values) > MAX_ADDRESSES:
        raise ArchiveError('STYLE_ADDRESS_LIMIT')
    normalized = [address(value) for value in values]
    if any(not value for value in normalized):
        raise ArchiveError('STYLE_ADDRESS_INVALID')
    return tuple(dict.fromkeys(normalized))


def conservative_units(text):
    return len(text.encode('utf-8')) + SAMPLE_FRAMING_UNITS


def _epoch(archive, account_id):
    # The archive supplies an O(1) completed-scan watermark. Never derive this
    # using max/count over every catalog row in a reply or extraction path.
    return archive.mail_index_completed_epoch(account_id)


def _query_page(archive, sql, arguments):
    try:
        with archive.bounded_query(max_steps=SEARCH_MAX_VM_STEPS, seconds=SEARCH_MAX_SECONDS):
            return archive.db.execute(sql, arguments).fetchall()
    except ArchiveError as exc:
        if str(exc).startswith('SEARCH_BUDGET_EXCEEDED'):
            raise ArchiveError('STYLE_CANDIDATE_QUERY_BUDGET_NARROW_REQUIRED') from None
        raise


class _Candidates:
    def __init__(self, archive, account_id, own, epoch):
        self.archive = archive
        self.account_id = account_id
        self.own = own
        self.epoch = epoch
        self.fetched = 0
        self.queries = 0
        self.streams = {value: {'rows': [], 'position': 0, 'cursor': None, 'done': False} for value in own}

    def _head(self, alias):
        stream = self.streams[alias]
        if stream['position'] < len(stream['rows']):
            return stream['rows'][stream['position']]
        if stream['done'] or self.fetched >= MAX_CANDIDATES:
            return None
        cursor = stream['cursor']
        size = min(PAGE_SIZE, MAX_CANDIDATES-self.fetched)
        base = [self.account_id, alias, self.epoch]
        if cursor is None:
            rows = _query_page(self.archive, CANDIDATE_SQL.format(cursor_clause=''), base+[size])
            self.queries += 1
        else:
            # A mixed-direction (date DESC, ID ASC) OR predicate can reread all
            # preceding equal-date rows. Two actual index range seeks avoid the
            # resulting quadratic work in a large same-date Sent mailbox.
            rows = _query_page(self.archive, CANDIDATE_SQL.format(cursor_clause='AND date=? AND locator_id>?'),
                               base+[cursor[0], cursor[1], size])
            self.queries += 1
            if len(rows) < size:
                rows += _query_page(self.archive, CANDIDATE_SQL.format(cursor_clause='AND date<?'),
                                    base+[cursor[0], size-len(rows)])
                self.queries += 1
        self.fetched += len(rows)
        stream.update(rows=rows, position=0, done=len(rows) < size)
        if not rows:
            return None
        stream['cursor'] = (rows[-1]['date'], rows[-1]['locator_id'])
        return rows[0]

    def __iter__(self):
        # ISO dates are normalized non-null strings; descending lexicographic
        # order is UTC chronological order. Locator ID breaks same-date ties.
        heads = {alias: self._head(alias) for alias in self.own}
        while any(row is not None for row in heads.values()):
            newest = max(row['date'] for row in heads.values() if row is not None)
            alias = min((alias for alias, row in heads.items() if row is not None and row['date'] == newest),
                        key=lambda alias: heads[alias]['locator_id'])
            row = heads[alias]
            self.streams[alias]['position'] += 1
            yield row
            heads[alias] = self._head(alias)

    def exhausted(self):
        return all(stream['done'] and stream['position'] >= len(stream['rows']) for stream in self.streams.values())


def _author_matches(message, author):
    return (message.get('direction') == 'sent'
            and message.get('account_id') == author['account_id']
            and address(message.get('from', '')) in author['own_addresses'])


def _source_hash_verified(message):
    # Imported source ranges and derived native text snapshots have different
    # evidence. A verified private snapshot never claims live Mail/MIME access.
    return (message.get('range_verified') is True or
            (message.get('origin') in ('apple_mail_index_snapshot', 'apple_mail_sent_style_snapshot')
             and message.get('snapshot_hash_verified') is True
             and message.get('live_verified') is False))


def _manifest_valid(archive, manifest, author):
    if not isinstance(manifest, list) or not 1 <= len(manifest) <= MAX_SAMPLES:
        return False
    if all(entry.get('origin') == 'style_capture' for entry in manifest):
        import style_capture
        return style_capture.manifest_valid(archive, manifest, author)
    if any(entry.get('origin') == 'style_capture' for entry in manifest):
        return False
    epoch = _epoch(archive, author['account_id'])
    for item in manifest:
        row = archive.db.execute(MANIFEST_SQL, (item['locator_id'],)).fetchone()
        if (row is None or row['account_id'] != author['account_id'] or row['direction'] != 'sent'
                or row['normalized_from'] not in author['own_addresses'] or row['body_status'] != 'captured'
                or row['last_seen_epoch'] < epoch or row['current_message'] != item['message_id']
                or row['body_hash'] != item['body_hash'] or row['metadata_hash'] != item['metadata_hash']):
            return False
    return True


def extract(archive, account_id, own_addresses, shared_addresses=(), author_confirmed=False,
            token_budget=DEFAULT_TOKEN_BUDGET):
    if author_confirmed is not True:
        raise ArchiveError('STYLE_SENT_AUTHOR_REQUIRED')
    if not isinstance(account_id, str) or not account_id or len(account_id) > 1024:
        raise ArchiveError('STYLE_ACCOUNT_REQUIRED')
    if type(token_budget) is not int or not 64 <= token_budget <= MAX_TOKEN_BUDGET:
        raise ArchiveError('STYLE_TOKEN_BUDGET_INVALID')
    shared = set(_addresses(shared_addresses))
    own = tuple(value for value in _addresses(own_addresses) if value not in shared)
    if not own:
        raise ArchiveError('STYLE_PERSONAL_ADDRESS_REQUIRED')
    ensure_schema(archive)
    revision = archive.revision()
    author = {'account_id': account_id, 'own_addresses': list(own), 'author_confirmed': True}
    candidates = _Candidates(archive, account_id, own, _epoch(archive, account_id))
    texts = []
    manifest = []
    provider_manifest = []
    seen = set()
    seen_messages = set()
    checked = 0
    used = 0
    provider_bytes = 0
    skipped = dict.fromkeys(('duplicate', 'empty', 'over_budget', 'source_unavailable', 'unconfirmed_author'), 0)
    source_verifications = 0
    for candidate in candidates:
        checked += 1
        if candidate['current_message'] in seen_messages:
            skipped['duplicate'] += 1
            continue
        seen_messages.add(candidate['current_message'])
        try:
            message = archive.message(candidate['current_message'], verify=False)
        except ArchiveError:
            skipped['source_unavailable'] += 1
            continue
        if message.get('source_status') != 'available':
            skipped['source_unavailable'] += 1
            continue
        if not _author_matches(message, author):
            skipped['unconfirmed_author'] += 1
            continue
        text = authored_text(message['body_text'])
        if not text:
            skipped['empty'] += 1
            continue
        text_hash = digest(text.encode('utf-8'))
        if text_hash in seen:
            skipped['duplicate'] += 1
            continue
        charge = conservative_units(text)
        if used + charge > token_budget:
            skipped['over_budget'] += 1
            continue  # A long mail never hides a later, shorter eligible sample.
        try:
            verified = archive.message(message['id'], verify=True)
        except ArchiveError:
            skipped['source_unavailable'] += 1
            continue
        source_verifications += 1
        if (verified.get('source_status') != 'available' or not _source_hash_verified(verified)
                or not _author_matches(verified, author) or verified['body_hash'] != message['body_hash']):
            skipped['source_unavailable'] += 1
            continue
        entry = {'message_id': message['id'], 'body_hash': message['body_hash'],
                 'authored_hash': text_hash, 'locator_id': candidate['locator_id'],
                 'metadata_hash': candidate['metadata_hash']}
        manifest.append(entry)
        texts.append(text)
        seen.add(text_hash)
        used += charge
        encoded_size = len(text.encode('utf-8'))
        if (len(provider_manifest) < PROVIDER_EXAMPLE_LIMIT and encoded_size <= PROVIDER_EXAMPLE_BYTES
                and provider_bytes + encoded_size <= PROVIDER_TOTAL_BYTES):
            provider_manifest.append(entry)
            provider_bytes += encoded_size
        if len(texts) >= MAX_SAMPLES or used + SAMPLE_FRAMING_UNITS + 1 > token_budget:
            break
    if not texts:
        raise ArchiveError('STYLE_INDEXED_SENT_EXAMPLES_REQUIRED')
    summary_value = archive.style_traits(texts)
    description = archive.describe_style(summary_value)
    phrases = archive.neutral_source_phrases(texts)
    description = archive.style_source_description(description, phrases)
    summary_value.update(extraction_status='ready', description=description,
                         source_phrases=phrases, description_origin='observed_format_traits',
                         extracted_at=now(), corpus_version=PROFILE_VERSION,
                         sample_info={'selected_messages': len(texts), 'token_estimate': used,
                                      'token_budget': token_budget, 'token_unit': 'utf8_bytes_upper_bound',
                                      'token_estimate_is_exact': False, 'sample_framing_units': SAMPLE_FRAMING_UNITS,
                                      'candidates_checked': checked, 'candidates_fetched': candidates.fetched,
                                      'candidate_queries': candidates.queries, 'candidate_limit': MAX_CANDIDATES,
                                      'sample_limit': MAX_SAMPLES, 'skipped': skipped,
                                      'source_verifications': source_verifications,
                                      'provider_example_count': len(provider_manifest),
                                      'provider_example_bytes': provider_bytes,
                                      'coverage': {'scope': 'indexed_confirmed_own_sent',
                                                   'strategy': 'most_recent_indexed',
                                                   'candidate_window_exhausted': candidates.exhausted(),
                                                   'selection_capped': not candidates.exhausted(),
                                                   'snapshot_only': True,
                                                   'generation_source_verification': 'bounded_provider_examples_only'}})
    with archive.db:
        archive.db.execute('BEGIN IMMEDIATE')
        if archive.revision() != revision:
            raise ArchiveError('STYLE_CHANGED_DURING_EXTRACTION')
        if not _manifest_valid(archive, manifest, author):
            raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
        for entry in manifest:
            message = archive.message(entry['message_id'], verify=False)
            if message.get('source_status') != 'available' or not _author_matches(message, author):
                raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
        archive.db.execute('INSERT OR REPLACE INTO style_corpus_profile VALUES(1,?,?,?,?)',
                           (packed(summary_value), packed(manifest), packed(provider_manifest), packed(author)))
        archive.bump()
    return summary_value


def _stored(archive):
    ensure_schema(archive)
    row = archive.db.execute('SELECT * FROM style_corpus_profile WHERE id=1').fetchone()
    if row is None:
        return None
    profile = {key: json.loads(row[key]) for key in ('payload', 'manifest', 'provider_manifest', 'author')}
    profile['payload'] = archive.normalize_style_extraction(profile['payload'])
    return profile


def selected_messages(archive):
    profile = _stored(archive)
    if profile is None or profile['payload'].get('extraction_status') != 'ready':
        return []
    if not _manifest_valid(archive, profile['manifest'], profile['author']):
        raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
    examples = profile['provider_manifest']
    if len(examples) > PROVIDER_EXAMPLE_LIMIT:
        raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
    messages = []
    total = 0
    for entry in examples:
        if entry.get('origin') == 'style_capture':
            import style_capture
            message = style_capture.message(archive, entry['message_id'], verify=True)
        else:
            message = archive.message(entry['message_id'], verify=True)
        text = authored_text(message['body_text'])
        total += len(text.encode('utf-8'))
        if (message.get('source_status') != 'available' or not _source_hash_verified(message)
                or not _author_matches(message, profile['author']) or message['body_hash'] != entry['body_hash']
                or digest(text.encode('utf-8')) != entry['authored_hash']
                or len(text.encode('utf-8')) > PROVIDER_EXAMPLE_BYTES or total > PROVIDER_TOTAL_BYTES):
            raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
        messages.append(message)
    return messages


def summary(archive, verify=False, verified_messages=None):
    profile = _stored(archive)
    if profile is None:
        return None
    value = profile['payload']
    if value.get('extraction_status') == 'ready' and (verify or verified_messages is not None):
        try:
            if not _manifest_valid(archive, profile['manifest'], profile['author']):
                raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
            messages = selected_messages(archive) if verified_messages is None else verified_messages
            actual = [(m['id'], m['body_hash'], digest(authored_text(m['body_text']).encode('utf-8'))) for m in messages]
            expected = [(entry['message_id'], entry['body_hash'], entry['authored_hash']) for entry in profile['provider_manifest']]
            if actual != expected or any(not _author_matches(m, profile['author']) or m.get('source_status') != 'available'
                                         or not _source_hash_verified(m) for m in messages):
                raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
        except (ArchiveError, OSError):
            value.update(archive.empty_style_extraction('stale'))
            with archive.db:
                archive.db.execute('UPDATE style_corpus_profile SET payload=? WHERE id=1', (packed(value),))
                archive.bump()
    return value
