"""Durable, numeric-only native acquisition budget across resumptions.

Reserve the worst permitted bytes before native I/O. A failed or interrupted
request keeps that reservation until an exact validated acknowledgement is
committed; restarting a process does not forgive attempts or pending bytes.
"""
import json
import uuid

from archive import ArchiveError
from style_capture import ensure_schema

MAX_ATTEMPTS = 1024
MAX_BYTES = 64 * 1024 * 1024
MAX_READ_BYTES = 2 * 1024 * 1024 + 32_768 * 4
MAX_RESERVATION_READS = 40
SCHEMA = (
    '''CREATE TABLE IF NOT EXISTS style_capture_read_totals(
      capture_id TEXT PRIMARY KEY,reserved_attempts INTEGER NOT NULL DEFAULT 0,
      captured_bytes INTEGER NOT NULL DEFAULT 0,unresolved_bytes INTEGER NOT NULL DEFAULT 0,
      CHECK(reserved_attempts>=0 AND reserved_attempts<=1024),
      CHECK(captured_bytes>=0 AND unresolved_bytes>=0 AND captured_bytes+unresolved_bytes<=67108864))''',
    '''CREATE TABLE IF NOT EXISTS style_capture_read_requests(
      capture_id TEXT NOT NULL REFERENCES style_capture_read_totals(capture_id) ON DELETE CASCADE,
      attempt_id TEXT NOT NULL,reads INTEGER NOT NULL,reserved_bytes INTEGER NOT NULL,
      charged_bytes INTEGER,PRIMARY KEY(capture_id,attempt_id),
      CHECK(reads>=1 AND reads<=40),CHECK(reserved_bytes=reads*2228224),
      CHECK(charged_bytes IS NULL OR (charged_bytes>=0 AND charged_bytes<=reserved_bytes)))''',
)


def _uuid(value):
    if type(value) is not str or len(value) != 36:
        raise ArchiveError('STYLE_READ_BUDGET_INPUT_INVALID')
    try:
        parsed = str(uuid.UUID(value))
    except (ValueError, AttributeError):
        raise ArchiveError('STYLE_READ_BUDGET_INPUT_INVALID') from None
    if parsed != value.lower():
        raise ArchiveError('STYLE_READ_BUDGET_INPUT_INVALID')
    return parsed


class StyleCaptureReadBudget:
    """Only counters are written; no Mail data or archive revision is changed."""
    def __init__(self, archive):
        self.archive, self.db = archive, archive.db
        ensure_schema(archive)
        with self.db:
            for statement in SCHEMA:
                self.db.execute(statement)
            self._gc()

    def _gc(self):
        active = self.db.execute('SELECT capture_id FROM style_capture_state WHERE id=1').fetchone()
        retained = {active['capture_id']} if active else set()
        profile = self.db.execute('SELECT manifest FROM style_corpus_profile WHERE id=1').fetchone()
        if profile:
            try:
                entries = json.loads(profile['manifest'])
                if type(entries) is not list or len(entries) > 512:
                    raise ArchiveError('STYLE_READ_BUDGET_STATE_INVALID')
                retained.update(entry['capture_id'] for entry in entries
                                if type(entry) is dict and entry.get('origin') == 'style_capture')
            except (ValueError, TypeError, KeyError):
                raise ArchiveError('STYLE_READ_BUDGET_STATE_INVALID') from None
        if len(retained) > 2:
            raise ArchiveError('STYLE_READ_BUDGET_STATE_INVALID')
        if retained:
            parameters = tuple(sorted(retained))
            slots = ','.join('?' for _ in parameters)
            self.db.execute('DELETE FROM style_capture_read_totals WHERE capture_id NOT IN ('+slots+')', parameters)
        else:
            self.db.execute('DELETE FROM style_capture_read_totals')

    def _capture(self, capture_id, running=False):
        capture_id = _uuid(capture_id)
        state = self.db.execute('SELECT capture_id,status FROM style_capture_state WHERE id=1').fetchone()
        if state is None or state['capture_id'] != capture_id:
            raise ArchiveError('STYLE_READ_BUDGET_CAPTURE_CHANGED')
        if running and state['status'] != 'running':
            raise ArchiveError('STYLE_READ_BUDGET_NOT_RUNNING')
        self.db.execute('INSERT OR IGNORE INTO style_capture_read_totals(capture_id) VALUES(?)', (capture_id,))
        return capture_id

    def _totals(self, capture_id):
        row = self.db.execute('SELECT reserved_attempts,captured_bytes,unresolved_bytes '
                              'FROM style_capture_read_totals WHERE capture_id=?', (capture_id,)).fetchone()
        requests = self.db.execute('''SELECT count(*) AS count,sum(reads) AS attempts,
          sum(coalesce(charged_bytes,0)) AS captured,
          sum(CASE WHEN charged_bytes IS NULL THEN reserved_bytes ELSE 0 END) AS unresolved
          FROM style_capture_read_requests WHERE capture_id=?''', (capture_id,)).fetchone()
        if (row is None or requests['count'] > MAX_ATTEMPTS
                or any(type(row[key]) is not int or row[key] < 0 for key in row.keys())
                or row['reserved_attempts'] > MAX_ATTEMPTS
                or row['captured_bytes'] + row['unresolved_bytes'] > MAX_BYTES
                or row['reserved_attempts'] != (requests['attempts'] or 0)
                or row['captured_bytes'] != (requests['captured'] or 0)
                or row['unresolved_bytes'] != (requests['unresolved'] or 0)):
            raise ArchiveError('STYLE_READ_BUDGET_STATE_INVALID')
        return dict(row)

    def status(self, capture_id):
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            current = self._capture(capture_id)
            return self._totals(current)

    def reserve(self, capture_id, attempt_id, reads):
        token = _uuid(attempt_id)
        if type(reads) is not int or not 1 <= reads <= MAX_RESERVATION_READS:
            raise ArchiveError('STYLE_READ_BUDGET_INPUT_INVALID')
        worst = reads * MAX_READ_BYTES
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            current = self._capture(capture_id, running=True)
            totals = self._totals(current)
            prior = self.db.execute('SELECT reads FROM style_capture_read_requests '
                                    'WHERE capture_id=? AND attempt_id=?', (current, token)).fetchone()
            if prior:
                if prior['reads'] != reads:
                    raise ArchiveError('STYLE_READ_BUDGET_RETRY_CHANGED')
                return totals
            if (totals['reserved_attempts'] + reads > MAX_ATTEMPTS
                    or totals['captured_bytes'] + totals['unresolved_bytes'] + worst > MAX_BYTES):
                raise ArchiveError('STYLE_READ_BUDGET_LIMIT')
            self.db.execute('INSERT INTO style_capture_read_requests VALUES(?,?,?,?,NULL)',
                            (current, token, reads, worst))
            self.db.execute('''UPDATE style_capture_read_totals SET
              reserved_attempts=reserved_attempts+?,unresolved_bytes=unresolved_bytes+?
              WHERE capture_id=?''', (reads, worst, current))
            return self._totals(current)

    def charge(self, capture_id, attempt_id, captured_bytes):
        token = _uuid(attempt_id)
        if type(captured_bytes) is not int or not 0 <= captured_bytes <= MAX_BYTES:
            raise ArchiveError('STYLE_READ_BUDGET_INPUT_INVALID')
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            current = self._capture(capture_id)
            totals = self._totals(current)
            prior = self.db.execute('SELECT reserved_bytes,charged_bytes FROM style_capture_read_requests '
                                    'WHERE capture_id=? AND attempt_id=?', (current, token)).fetchone()
            if prior is None:
                raise ArchiveError('STYLE_READ_BUDGET_REQUEST_UNKNOWN')
            if prior['charged_bytes'] is not None:
                if prior['charged_bytes'] != captured_bytes:
                    raise ArchiveError('STYLE_READ_BUDGET_RETRY_CHANGED')
                return totals
            self._capture(current, running=True)
            if captured_bytes > prior['reserved_bytes']:
                raise ArchiveError('STYLE_READ_BUDGET_CHARGE_INVALID')
            self.db.execute('UPDATE style_capture_read_requests SET charged_bytes=? '
                            'WHERE capture_id=? AND attempt_id=?', (captured_bytes, current, token))
            self.db.execute('''UPDATE style_capture_read_totals SET
              captured_bytes=captured_bytes+?,unresolved_bytes=unresolved_bytes-?
              WHERE capture_id=?''', (captured_bytes, prior['reserved_bytes'], current))
            return self._totals(current)
