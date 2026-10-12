"""Bounded private cache of prior native-Mail body snapshots.

The caller must validate the requested locator against Mail before reuse. Hashes
verify local snapshot integrity only: a hit is never proof of a fresh Mail body.
No source/index/style revision, FTS row, filesystem mail or network is touched.
"""
import datetime as dt
import json
import math
import re
import time

from archive import ArchiveError, digest, packed
from mail_index import canonical_json, direction_for, path_parts, utc_date

MAX_BATCH = 20
MAX_REQUEST_BYTES = 1_500_000
MAX_RECORD_BYTES = 1_500_000
MAX_ENTRIES = 512
MAX_BYTES = 64 * 1024 * 1024
TTL_SECONDS = 24 * 60 * 60
ORIGIN = 'apple_mail_body_cache_snapshot'
LOCATOR_FIELDS = frozenset(('accountID', 'mailboxPath', 'nativeID', 'messageID',
                            'subject', 'sender', 'dateSent', 'dateReceived',
                            'messageSize', 'role', 'isLocal', 'scanID'))
RECORD_FIELDS = LOCATOR_FIELDS | frozenset(('body', 'headers', 'attachmentCount',
                                          'bodyStatus', 'failure'))
FINGERPRINT_FIELDS = tuple(sorted(LOCATOR_FIELDS - {'scanID'}))
SCHEMA = (
    '''CREATE TABLE IF NOT EXISTS mail_body_cache(
      account_id TEXT NOT NULL,mailbox_path TEXT NOT NULL,native_id TEXT NOT NULL,
      fingerprint TEXT NOT NULL,payload TEXT NOT NULL,payload_hash TEXT NOT NULL,
      body_hash TEXT NOT NULL,headers_hash TEXT NOT NULL,payload_bytes INTEGER NOT NULL,
      captured_at REAL NOT NULL,expires_at REAL NOT NULL,last_accessed REAL NOT NULL,
      PRIMARY KEY(account_id,mailbox_path,native_id),
      CHECK(payload_bytes>=0 AND payload_bytes<=1500000))''',
    '''CREATE INDEX IF NOT EXISTS mail_body_cache_eviction
       ON mail_body_cache(last_accessed,account_id,mailbox_path,native_id)''',
    '''CREATE INDEX IF NOT EXISTS mail_body_cache_expiry ON mail_body_cache(expires_at)''',
    '''CREATE TABLE IF NOT EXISTS mail_body_cache_totals(
      id INTEGER PRIMARY KEY CHECK(id=1),entries INTEGER NOT NULL CHECK(entries>=0),
      payload_bytes INTEGER NOT NULL CHECK(payload_bytes>=0))''',
)


def _batch(records):
    if type(records) is not list or len(records) > MAX_BATCH:
        raise ArchiveError('MAIL_BODY_CACHE_BATCH_LIMIT')
    encoded = canonical_json(records).encode('utf-8')
    if len(encoded) > MAX_REQUEST_BYTES:
        raise ArchiveError('MAIL_BODY_CACHE_INPUT_LIMIT')
    return records


def _locator(record):
    if type(record) is not dict:
        raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
    required = LOCATOR_FIELDS - {'dateSent', 'dateReceived'}
    if not required <= record.keys():
        raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
    text_fields = ('accountID', 'nativeID', 'messageID', 'subject', 'sender', 'scanID')
    if any(type(record[key]) is not str or '\0' in record[key]
           or len(record[key].encode('utf-8')) > 16_384 for key in text_fields):
        raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
    account, native, scan = (record[key] for key in ('accountID', 'nativeID', 'scanID'))
    if (not account or not re.fullmatch(r'[0-9]+', native) or len(native) > 19
            or not 0 < int(native) <= 2**63-1 or not scan or len(scan.encode('utf-8')) > 128):
        raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
    path = path_parts(record['mailboxPath'])
    if any(not part or '\0' in part for part in path):
        raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
    if (type(record['isLocal']) is not bool
            or (account == '__harborreply_local__') != record['isLocal']
            or type(record['messageSize']) is not int or not 0 <= record['messageSize'] <= 2**63-1):
        raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
    role = record['role']
    if role not in ('sent', 'received', 'draft', 'unknown') or direction_for(record) != role:
        raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
    value = {key: record.get(key) for key in FINGERPRINT_FIELDS}
    for key in ('dateSent', 'dateReceived'):
        date = record.get(key)
        if date is not None:
            if type(date) is not str or not utc_date(date):
                raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
            value[key] = utc_date(date)
    return (account, packed(path), native), digest(canonical_json(value).encode('utf-8'))


class MailBodyCache:
    """Owns only SQLite effects on the private Archive connection."""
    def __init__(self, archive):
        self.archive, self.db = archive, archive.db
        with self.db:
            for statement in SCHEMA:
                self.db.execute(statement)
            if self.db.execute('SELECT 1 FROM mail_body_cache_totals WHERE id=1').fetchone() is None:
                self.db.execute('''INSERT INTO mail_body_cache_totals
                  SELECT 1,count(*),coalesce(sum(payload_bytes),0) FROM mail_body_cache''')

    def _totals(self):
        row = self.db.execute('SELECT entries,payload_bytes FROM mail_body_cache_totals WHERE id=1').fetchone()
        if (row is None or type(row['entries']) is not int or type(row['payload_bytes']) is not int
                or not 0 <= row['entries'] <= MAX_ENTRIES + MAX_BATCH
                or not 0 <= row['payload_bytes'] <= MAX_BYTES + MAX_REQUEST_BYTES):
            raise ArchiveError('MAIL_BODY_CACHE_STATE_INVALID')
        return row['entries'], row['payload_bytes']

    def _delete(self, key, size):
        changed = self.db.execute('DELETE FROM mail_body_cache WHERE account_id=? AND mailbox_path=? AND native_id=?', key).rowcount
        if changed:
            self.db.execute('UPDATE mail_body_cache_totals SET entries=entries-1,payload_bytes=payload_bytes-? WHERE id=1', (size,))
        return changed

    def _evict(self, stamp):
        removed = 0
        # Expiry and recency use indices and a constant 512 + 20 row cap.
        expired = self.db.execute('''SELECT account_id,mailbox_path,native_id,payload_bytes
          FROM mail_body_cache WHERE expires_at<=? ORDER BY expires_at LIMIT ?''',
                                  (stamp, MAX_ENTRIES + MAX_BATCH)).fetchall()
        for row in expired:
            removed += self._delete(tuple(row[key] for key in ('account_id', 'mailbox_path', 'native_id')), row['payload_bytes'])
        entries, size = self._totals()
        while entries > MAX_ENTRIES or size > MAX_BYTES:
            row = self.db.execute('''SELECT account_id,mailbox_path,native_id,payload_bytes
              FROM mail_body_cache ORDER BY last_accessed,account_id,mailbox_path,native_id LIMIT 1''').fetchone()
            if row is None:
                raise ArchiveError('MAIL_BODY_CACHE_STATE_INVALID')
            removed += self._delete(tuple(row[key] for key in ('account_id', 'mailbox_path', 'native_id')), row['payload_bytes'])
            entries, size = self._totals()
        return removed

    def _prepare(self, record):
        key, fingerprint = _locator(record)
        if set(record) - RECORD_FIELDS:
            raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
        mailbox = {'account_id': key[0], 'mailbox_path': key[1],
                   'is_local': int(record['isLocal']), 'role': record['role']}
        parsed = self.archive.mail_index._prepare_record(record, mailbox, 0)
        if parsed['body_status'] != 'captured':
            return None
        if (type(record.get('body')) is not str or type(record.get('headers')) is not str
                or type(record.get('attachmentCount')) is not int
                or not 0 <= record['attachmentCount'] <= 10000):
            raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
        payload = canonical_json(record)
        size = len(payload.encode('utf-8'))
        if size > MAX_RECORD_BYTES:
            raise ArchiveError('MAIL_BODY_CACHE_INPUT_LIMIT')
        return (key, fingerprint, payload, digest(payload.encode('utf-8')),
                parsed['body_hash'], digest(record['headers'].encode('utf-8')), size)

    def store(self, records):
        prepared = [self._prepare(record) for record in _batch(records)]
        usable = [record for record in prepared if record is not None]
        keys = [record[0] for record in usable]
        if len(keys) != len(set(keys)):
            raise ArchiveError('MAIL_BODY_CACHE_DUPLICATE_RECORD')
        stamp = time.time()
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            evicted = self._evict(stamp)
            for key, fingerprint, payload, payload_hash, body_hash, headers_hash, size in usable:
                old = self.db.execute('SELECT payload_bytes FROM mail_body_cache WHERE account_id=? AND mailbox_path=? AND native_id=?', key).fetchone()
                if old is not None:
                    self._delete(key, old['payload_bytes'])
                self.db.execute('''INSERT INTO mail_body_cache VALUES(?,?,?,?,?,?,?,?,?,?,?,?)''',
                                (*key, fingerprint, payload, payload_hash, body_hash, headers_hash,
                                 size, stamp, stamp + TTL_SECONDS, stamp))
                self.db.execute('UPDATE mail_body_cache_totals SET entries=entries+1,payload_bytes=payload_bytes+? WHERE id=1', (size,))
            evicted += self._evict(stamp)
            entries, size = self._totals()
        return {'stored': len(usable), 'skipped': len(prepared)-len(usable),
                'evicted': evicted, 'entries': entries, 'payloadBytes': size}

    def lookup(self, locators):
        requested = [(record, *_locator(record)) for record in _batch(locators)]
        if any(set(record) - LOCATOR_FIELDS for record, _, _ in requested):
            raise ArchiveError('MAIL_BODY_CACHE_RECORD_INVALID')
        keys = [key for _, key, _ in requested]
        if len(keys) != len(set(keys)):
            raise ArchiveError('MAIL_BODY_CACHE_DUPLICATE_RECORD')
        stamp, slots, output_bytes = time.time(), [], 256 + 5 * len(requested)
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            for locator, key, fingerprint in requested:
                # A corrupt oversized value never crosses into Python memory.
                row = self.db.execute('''SELECT fingerprint,payload_hash,body_hash,headers_hash,payload_bytes,
                  captured_at,expires_at,CASE WHEN typeof(payload)='text' AND length(CAST(payload AS BLOB))<=?
                  THEN payload ELSE NULL END AS payload FROM mail_body_cache
                  WHERE account_id=? AND mailbox_path=? AND native_id=?''', (MAX_RECORD_BYTES, *key)).fetchone()
                value = None
                if row is not None:
                    try:
                        valid = (row['fingerprint'] == fingerprint and row['payload'] is not None
                                 and type(row['captured_at']) in (int, float)
                                 and type(row['expires_at']) in (int, float)
                                 and math.isfinite(row['captured_at']) and math.isfinite(row['expires_at'])
                                 and row['captured_at'] <= stamp < row['expires_at']
                                 and row['expires_at'] == row['captured_at'] + TTL_SECONDS
                                 and len(row['payload'].encode('utf-8')) == row['payload_bytes']
                                 and digest(row['payload'].encode('utf-8')) == row['payload_hash'])
                        if valid:
                            decoded = json.loads(row['payload'])
                            prepared = self._prepare(decoded)
                            valid = (prepared is not None and prepared[0] == key
                                     and prepared[1] == fingerprint and prepared[3] == row['payload_hash']
                                     and prepared[4] == row['body_hash'] and prepared[5] == row['headers_hash'])
                            if valid:
                                value = dict(decoded, scanID=locator['scanID'], snapshotOrigin=ORIGIN,
                                             snapshotHashVerified=True, liveVerified=False,
                                             cachedAt=dt.datetime.fromtimestamp(row['captured_at'], dt.timezone.utc).isoformat())
                    except (ArchiveError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
                        value = None
                    if value is None:
                        self._delete(key, row['payload_bytes'])
                    else:
                        # Match main.py's spaced JSON encoding, including the
                        # marker fields, rather than underestimate IPC bytes.
                        size = len(json.dumps(value, ensure_ascii=False).encode('utf-8')) + 2
                        if output_bytes + size > MAX_REQUEST_BYTES:
                            # Keep the valid prior snapshot, but do not exceed
                            # the IPC response cap for a mixed-size request.
                            value = None
                        else:
                            output_bytes += size
                            self.db.execute('UPDATE mail_body_cache SET last_accessed=? WHERE account_id=? AND mailbox_path=? AND native_id=?', (stamp, *key))
                slots.append(value)
        hits = sum(value is not None for value in slots)
        return {'slots': slots, 'hits': hits, 'misses': len(slots)-hits}
