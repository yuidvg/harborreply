"""Local-only archive; no network, execution, Mail access or raw-content logging."""
import contextlib
import datetime as dt
import email.policy
import email.utils
from email.parser import BytesParser
from email.parser import Parser
from email.message import EmailMessage
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import statistics
import time
import unicodedata

PARSER_VERSION = 'harbor-mime-1'
MAX_MESSAGE = 16 * 1024 * 1024
MAX_LINE = 1024 * 1024
MAX_BODY = 250_000
MAX_DEPTH = 16
MAX_PARTS = 256
MAX_SOURCE_RANGE = MAX_MESSAGE + MAX_LINE
MAX_LOCATIONS = 200
MAX_CASE_MESSAGES = 100
MAX_CASE_EVENTS = 100
MAX_STYLE_EXAMPLES = 3
MAX_CANDIDATE_PREVIEWS = 20
MAX_RELATED_POOL = 180
MAX_MAIL_HEADERS = 768
MAX_MAIL_SNAPSHOTS = 20
# Only complete, neutral lines may be quoted as source examples. This is not a
# pattern that accepts arbitrary text after a greeting or closing.
NEUTRAL_STYLE_PHRASES = frozenset((
    'Thank you for your message.', 'Kind regards,', 'Best regards,', 'Dear Sir/Madam,',
    'お世話になっております。', 'よろしくお願いいたします。', 'ご確認をお願いいたします。',
))
SEARCH_MAX_VM_STEPS = 200_000
SEARCH_MAX_SECONDS = 0.75
SEARCH_SQL = 'SELECT id FROM search WHERE search MATCH ? ORDER BY rowid DESC LIMIT ?'
CASE_MESSAGES_SQL = 'SELECT message_id FROM memberships WHERE case_id=? AND confirmed=1 ORDER BY message_date DESC,message_id LIMIT ?'
CASE_EVENTS_SQL = 'SELECT * FROM events WHERE case_id=? ORDER BY event_time DESC,id LIMIT ?'
ENVELOPE = re.compile(rb'^From \S+ (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +\d{1,2} \d{2}:\d{2}(?::\d{2})?(?: [^\r\n]+)? \d{4}\r?\n$')

class ArchiveError(Exception):
    pass

def digest(data):
    return hashlib.sha256(data).hexdigest()

def packed(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def stat_fingerprint(s):
    return packed([s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns])

def fingerprint(path):
    p = Path(path)
    # Reject symlinks in every component, not only the leaf.
    if any(x.is_symlink() for x in [p] + list(p.parents)):
        raise ArchiveError('SYMLINK_NOT_ALLOWED')
    s = p.stat()
    if not stat.S_ISREG(s.st_mode):
        raise ArchiveError('NOT_REGULAR_FILE')
    return stat_fingerprint(s)

def read_source_range(path, start, end, expected_fingerprint):
    """Verify just one imported message range, never hash the whole archive.

    Path and open-descriptor checks before and after prevent accepting replaced
    or concurrently modified sources. ctime is included; preserving mtime alone
    cannot make changed bytes trusted. The per-message range hash remains required.
    """
    if start < 0 or end <= start or end - start > MAX_SOURCE_RANGE:
        raise ArchiveError('SOURCE_RANGE_LIMIT')
    if fingerprint(path) != expected_fingerprint: raise ArchiveError('SOURCE_CHANGED')
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'rb') as f:
        if stat_fingerprint(os.fstat(f.fileno())) != expected_fingerprint: raise ArchiveError('SOURCE_CHANGED')
        f.seek(start); raw = f.read(end - start)
        if len(raw) != end - start or stat_fingerprint(os.fstat(f.fileno())) != expected_fingerprint:
            raise ArchiveError('SOURCE_CHANGED')
    if fingerprint(path) != expected_fingerprint: raise ArchiveError('SOURCE_CHANGED')
    return raw

def source_files(root):
    root = Path(root).absolute()
    if any(x.is_symlink() for x in [root] + list(root.parents)):
        raise ArchiveError('SYMLINK_NOT_ALLOWED')
    if root.is_file():
        if root.suffix.lower() not in ('.eml', '.mbox') and root.name != 'mbox':
            raise ArchiveError('UNSUPPORTED_SOURCE')
        return [str(root)]
    result = []
    visited = 0
    for folder, dirs, files in os.walk(root, followlinks=False):
        visited += 1
        if visited > 10000 or len(result) > 10000:
            raise ArchiveError('SOURCE_ENUMERATION_LIMIT')
        dirs[:] = sorted(d for d in dirs if not Path(folder, d).is_symlink())
        for name in sorted(files):
            p = Path(folder, name)
            if not p.is_symlink() and (p.suffix.lower() in ('.eml', '.mbox') or name == 'mbox'):
                result.append(str(p))
    if not result:
        raise ArchiveError('NO_SUPPORTED_SOURCE')
    return result

class PlainHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden = 0
        self.output = []
    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'head'): self.hidden += 1
        if tag in ('br', 'p', 'div', 'li', 'tr'): self.output.append('\n')
    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'head'): self.hidden = max(0, self.hidden - 1)
    def handle_data(self, data):
        if not self.hidden: self.output.append(data)


def parse_message(raw, direction='received', account='', internal=False):
    if len(raw) > MAX_MESSAGE: raise ArchiveError('MESSAGE_TOO_LARGE')
    if any(len(line) > MAX_LINE for line in raw.splitlines()): raise ArchiveError('LINE_TOO_LONG')
    msg = BytesParser(policy=email.policy.default).parsebytes(raw)
    if msg.defects: raise ArchiveError('MALFORMED_MIME')
    if not any(msg.get(x) for x in ('From', 'Subject', 'Message-ID')):
        raise ArchiveError('MISSING_MAIL_HEADERS')
    if msg.get('Content-Length'): raise ArchiveError('MBOXCL_UNSUPPORTED')
    parts = []; attachments = []; count = [0]
    def visit(part, depth=0):
        count[0] += 1
        if depth > MAX_DEPTH or count[0] > MAX_PARTS: raise ArchiveError('MIME_COMPLEXITY_LIMIT')
        if part.defects: raise ArchiveError('MALFORMED_MIME')
        ctype = part.get_content_type()
        if ctype in ('multipart/encrypted', 'application/pkcs7-mime', 'application/x-pkcs7-mime'):
            raise ArchiveError('UNREADABLE_ENCRYPTED')
        if part.get_content_disposition() == 'attachment' or part.get_filename() or ctype == 'message/rfc822':
            data = part.get_payload(decode=True)
            attachments.append({'name': str(part.get_filename() or '(unnamed)'), 'media_type': ctype,
                                'size': len(data) if data is not None else len(part.as_bytes()),
                                'parse_status': 'unparsed', 'part': count[0]})
            return
        if part.is_multipart():
            if part.get_content_subtype() == 'alternative':
                variants = []
                for child in part.iter_parts():
                    start = len(parts); visit(child, depth + 1)
                    variants.append(parts[start:]); del parts[start:]
                chosen = next((v for v in variants if any(kind == 'text/plain' for kind, _ in v)), variants[-1] if variants else [])
                parts.extend(chosen)
            else:
                for child in part.iter_parts(): visit(child, depth + 1)
            return
        data = part.get_payload(decode=True) or b''
        if part.defects: raise ArchiveError('MALFORMED_TRANSFER_ENCODING')
        if ctype not in ('text/plain', 'text/html'):
            attachments.append({'name': '(inline)', 'media_type': ctype, 'size': len(data), 'parse_status': 'unparsed', 'part': count[0]})
            return
        try: text = data.decode(part.get_content_charset() or 'ascii', errors='strict')
        except (UnicodeError, LookupError): raise ArchiveError('UNREADABLE_CHARSET')
        if ctype == 'text/html':
            html = PlainHTML(); html.feed(text); text = ''.join(html.output)
        parts.append((ctype, text))
    visit(msg)
    # Prefer plain alternatives, retain inline answers and quotes verbatim.
    body = '\n'.join(text for _, text in parts)
    if len(body) > MAX_BODY: raise ArchiveError('BODY_LIMIT')
    date = None
    try:
        parsed = email.utils.parsedate_to_datetime(str(msg.get('Date', '')))
        if parsed.tzinfo: date = parsed.astimezone(dt.timezone.utc).isoformat()
    except (ValueError, TypeError, OverflowError): pass
    refs = lambda v: re.findall(r'<([^<>\s]+)>', str(v or ''))
    message_id = refs(msg.get('Message-ID'))
    sections = [{'kind': 'quoted' if line.lstrip().startswith('>') else 'signature' if line == '-- ' else 'text', 'text': line}
                for line in body.splitlines()]
    return {'id': digest(raw), 'message_id': message_id[0] if message_id else '',
            'in_reply_to': refs(msg.get('In-Reply-To')), 'references': refs(msg.get('References')),
            'from': str(msg.get('From', '')), 'to': str(msg.get('To', '')), 'cc': str(msg.get('Cc', '')),
            'reply_to': str(msg.get('Reply-To', '')), 'date': date, 'date_parse_status': 'parsed' if date else 'unknown',
            'subject': str(msg.get('Subject', '')), 'account_id': account, 'direction': direction,
            'body_text': body, 'body_hash': digest(body.encode()), 'parser_version': PARSER_VERSION,
            'attachments': attachments, 'sections': sections, 'internal': internal, 'ingestion_time': now(),
            'body_bytes': len(body.encode()), 'attachment_bytes': sum(a['size'] for a in attachments)}


def records(path, checkpoint=0):
    """Bounded streaming mboxo/mboxrd; source offsets always refer to original bytes."""
    with open(path, 'rb') as f:
        if Path(path).suffix.lower() == '.eml':
            if checkpoint: return
            raw = f.read(MAX_MESSAGE + 1)
            size = os.fstat(f.fileno()).st_size
            yield 0, size, raw if len(raw) <= MAX_MESSAGE else None, 'MESSAGE_TOO_LARGE' if len(raw) > MAX_MESSAGE else None
            return
        f.seek(checkpoint)
        start = checkpoint; chunks = []; total = 0; failure = None; have_envelope = False
        while True:
            offset = f.tell()
            line = f.readline(MAX_LINE + 1)
            if not line: break
            if ENVELOPE.match(line):
                if have_envelope:
                    yield start, offset, b''.join(chunks) if not failure else None, failure
                elif offset != checkpoint:
                    raise ArchiveError('INVALID_MBOX_PREAMBLE')
                start = offset; chunks = []; total = 0; failure = None; have_envelope = True
                continue
            if not have_envelope: raise ArchiveError('INVALID_MBOX_ENVELOPE')
            total += len(line)
            if len(line) > MAX_LINE: failure = 'LINE_TOO_LONG'
            if total > MAX_MESSAGE: failure = 'MESSAGE_TOO_LARGE'
            if not failure:
                # Remove exactly one mboxrd escape; never split the corpus into strings.
                chunks.append(line[1:] if re.match(rb'^>+From ', line) else line)
        if have_envelope: yield start, f.tell(), b''.join(chunks) if not failure else None, failure


def normalized(text):
    return unicodedata.normalize('NFKC', text).casefold()

def tokens(text):
    text = normalized(text)
    words = re.findall(r'[a-z0-9]+(?:-[a-z0-9]+)*', text)
    cjk = re.findall(r'[\u3040-\u30ff\u3400-\u9fff]+', text)
    grams = [g for s in cjk for n in (1, 2) for i in range(len(s)-n+1) for g in [s[i:i+n]]]
    return words + ['j' + x.encode().hex() for x in grams]

def query_tokens(text):
    words = re.findall(r'[a-z0-9]+(?:-[a-z0-9]+)*', normalized(text))
    for s in re.findall(r'[\u3040-\u30ff\u3400-\u9fff]+', normalized(text)):
        n = min(2, len(s)); words.extend('j' + s[i:i+n].encode().hex() for i in range(len(s)-n+1))
    return list(dict.fromkeys(words))[:64]

# Common notification words do not establish a relationship by themselves.
RELATED_STOP_WORDS = frozenset('a an the of and or to from for with in on is are was your you this that new re fw fwd alert alerts notification notifications message email update updates important please dear regards best noreply no reply'.split())

def related_features(subject='', sender=''):
    text = normalized(re.sub(r'^(?:(?:re|fw|fwd):\s*)+', '', subject, flags=re.I))
    words = set(query_tokens(text))
    address = next((address.casefold() for _, address in email.utils.getaddresses([sender]) if '@' in address), '')
    meaningful = [x for x in query_tokens(text) if x not in RELATED_STOP_WORDS][:12]
    return {'words': words, 'meaningful': meaningful, 'address': address}


def related_header_refs(current):
    headers = current.get('headers', '')
    if not isinstance(headers, str) or len(headers) > 32768: raise ArchiveError('RELATED_HEADERS_LIMIT')
    parsed = Parser(policy=email.policy.default).parsestr(headers, headersonly=True)
    refs = re.findall(r'<([^<>\s]+)>', str(parsed.get('References', '')) + ' ' + str(parsed.get('In-Reply-To', '')))
    if len(refs) > 60: raise ArchiveError('HEADER_REFERENCES_LIMIT')
    return set(refs)

def rank_related_rows(current, rows, limit=20):
    """One shared metadata-only scorer for local and native Mail candidates.

    It never turns lexical similarity into a case membership or historical fact.
    Only the bounded candidate pool is sorted; no body or all-mail ranking.
    """
    if not isinstance(current, dict): raise ArchiveError('RELATED_INPUT_LIMIT')
    if not isinstance(rows, list) or len(rows) > MAX_MAIL_HEADERS: raise ArchiveError('RELATED_RECORD_LIMIT')
    subject = current.get('subject', ''); sender = current.get('sender', '')
    if not isinstance(subject, str) or len(subject.encode()) > 16384 or not isinstance(sender, str) or len(sender.encode()) > 16384:
        raise ArchiveError('RELATED_INPUT_LIMIT')
    selected = related_features(subject, sender); refs = related_header_refs(current)
    own_header = str(current.get('messageID', '')).strip('<>'); own_id = current.get('id', '')
    scored = []; seen = set(); started = time.monotonic()
    for index, row in enumerate(rows):
        if time.monotonic() - started > SEARCH_MAX_SECONDS: raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY')
        if not isinstance(row, dict): raise ArchiveError('RELATED_RECORD_INVALID')
        mid = row.get('id'); title = row.get('subject', ''); author = row.get('sender', row.get('from', ''))
        if not isinstance(mid, str) or not mid or len(mid) > 512 or not isinstance(title, str) or len(title.encode()) > 16384 or not isinstance(author, str) or len(author.encode()) > 16384:
            raise ArchiveError('RELATED_RECORD_INVALID')
        if mid in seen: raise ArchiveError('RELATED_DUPLICATE_ID')
        seen.add(mid)
        header = str(row.get('messageID', row.get('message_id', ''))).strip('<>')
        if mid == own_id or own_header and header == own_header: continue
        candidate = related_features(title, author)
        shared = set(selected['meaningful']) & candidate['words']
        same_sender = bool(selected['address'] and selected['address'] == candidate['address'])
        if header and header in refs: score, reason = 10000, 'reply_header'
        elif shared:
            score = 100 * len(shared) + (10 if same_sender else 0)
            reason = 'sender_terms' if same_sender else 'subject_terms'
        else: continue
        scored.append({'id': mid, 'score': score, 'reason': reason, '_order': index})
    scored.sort(key=lambda row: (-row['score'], row['_order']))
    if time.monotonic() - started > SEARCH_MAX_SECONDS: raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY')
    return [{k: row[k] for k in ('id', 'score', 'reason')} for row in scored[:min(max(limit, 1), 60)]]

def authored_text(body):
    """Conservative reply-author portion for style only, never mail evidence."""
    lines = body.splitlines(); result = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        combined = ' '.join(x.strip() for x in lines[index:index+3])
        if stripped in ('--',) or re.match(r'(?i)^[-_\s]*(?:original message|forwarded message|転送メッセージ|元のメッセージ)[-_\s]*:?$', stripped) or re.match(r'(?i)^begin forwarded message:', stripped): break
        if re.match(r'(?i)^on\b.{0,600}\bwrote:\s*$', stripped) or (stripped.casefold().startswith('on ') and re.match(r'(?i)^on\b.{0,600}\bwrote:', combined)): break
        if re.search(r'(?:書きました|のメッセージ):?\s*$', stripped) and (re.search(r'\d', stripped) or '@' in stripped): break
        if re.match(r'(?i)^(?:from|差出人|送信者):', stripped) and any(re.match(r'(?i)^(?:sent|date|to|subject|送信日時|宛先|件名):', x.strip()) for x in lines[index+1:index+7]): break
        if stripped.startswith('>'): continue
        result.append(line)
    return '\n'.join(result).strip()

SCHEMA = '''
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value INTEGER);
INSERT OR IGNORE INTO meta VALUES('revision',0);
CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,path TEXT UNIQUE,fingerprint TEXT,checkpoint INTEGER DEFAULT 0,done INTEGER DEFAULT 0,parser TEXT,direction TEXT,account TEXT,internal INTEGER,updated TEXT,bytes INTEGER,imported INTEGER DEFAULT 0,duplicates INTEGER DEFAULT 0,failures INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY,message_id TEXT,date TEXT,body_hash TEXT,payload TEXT);
CREATE INDEX IF NOT EXISTS by_message_id ON messages(message_id);
CREATE INDEX IF NOT EXISTS by_date ON messages(date DESC);
CREATE TABLE IF NOT EXISTS locations(message_id TEXT REFERENCES messages(id) ON DELETE CASCADE,source_id TEXT REFERENCES sources(id) ON DELETE CASCADE,start INTEGER,end INTEGER,raw_hash TEXT,PRIMARY KEY(source_id,start));
CREATE TABLE IF NOT EXISTS mail_snapshots(message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,payload TEXT);
CREATE INDEX IF NOT EXISTS locations_message ON locations(message_id);
CREATE TABLE IF NOT EXISTS reply_edges(child TEXT REFERENCES messages(id) ON DELETE CASCADE,parent_header TEXT,PRIMARY KEY(child,parent_header));
CREATE INDEX IF NOT EXISTS parent_edges ON reply_edges(parent_header);
CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED,terms);
CREATE TABLE IF NOT EXISTS failures(source_id TEXT REFERENCES sources(id) ON DELETE CASCADE,start INTEGER,reason TEXT,PRIMARY KEY(source_id,start));
CREATE TABLE IF NOT EXISTS cases(id TEXT PRIMARY KEY,label TEXT,vessel TEXT,voyage TEXT,cargo TEXT);
CREATE TABLE IF NOT EXISTS memberships(case_id TEXT REFERENCES cases(id) ON DELETE CASCADE,message_id TEXT REFERENCES messages(id) ON DELETE CASCADE,reason TEXT,confirmed INTEGER,message_date TEXT,PRIMARY KEY(case_id,message_id));
CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,case_id TEXT REFERENCES cases(id) ON DELETE CASCADE,message_id TEXT REFERENCES messages(id) ON DELETE CASCADE,kind TEXT,subject TEXT,action TEXT,value TEXT,quote TEXT,body_hash TEXT,reported_by TEXT,event_time TEXT,supersedes TEXT,confirmed INTEGER);
CREATE TABLE IF NOT EXISTS policies(id TEXT PRIMARY KEY,payload TEXT);
CREATE TABLE IF NOT EXISTS styles(message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,author_confirmed INTEGER);
CREATE TABLE IF NOT EXISTS style_profiles(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT,manifest TEXT);
'''

class Archive:
    def __init__(self, db):
        os.umask(0o077)
        p = Path(db)
        p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(p.parent, 0o700)
        # Foundation may spell its own /private/var temporary directory as
        # /var. Resolve only our generated storage parent, keeping the snapshot
        # leaf unresolved so a redirected mail-snapshots folder is still denied.
        # User-selected source paths continue to reject every symlink component.
        self.snapshot_directory = p.parent.resolve() / 'mail-snapshots'
        self.db = sqlite3.connect(str(p), timeout=10)
        os.chmod(p, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA secure_delete=ON')
        self.db.executescript(SCHEMA)
        self.db.execute("CREATE TABLE IF NOT EXISTS style_text_profile(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL)")
        from mail_index import MailIndex
        self.mail_index = MailIndex(self)
        from direct_store import schema
        schema(self.db)
        import style_corpus
        style_corpus.ensure_schema(self)
        with self.db:
            # One-time migration is separate from the bounded normal reply path.
            if 'message_date' not in {r[1] for r in self.db.execute('PRAGMA table_info(memberships)')}:
                self.db.execute('ALTER TABLE memberships ADD COLUMN message_date TEXT')
                self.db.execute('UPDATE memberships SET message_date=(SELECT date FROM messages WHERE id=memberships.message_id)')
            self.db.execute('CREATE INDEX IF NOT EXISTS memberships_recent ON memberships(case_id,confirmed,message_date DESC,message_id)')
            self.db.execute('CREATE INDEX IF NOT EXISTS events_recent ON events(case_id,event_time DESC,id)')
            if self.db.execute("SELECT 1 FROM meta WHERE key='body_bytes'").fetchone() is None:
                self.update_size_totals()
            if self.db.execute("SELECT 1 FROM meta WHERE key='message_count'").fetchone() is None:
                self.db.execute("INSERT INTO meta VALUES('message_count',(SELECT count(*) FROM messages))")
            profile = self.db.execute('SELECT payload FROM style_profiles WHERE id=1').fetchone()
            if profile is None:
                self.rebuild_style_profile()
            elif json.loads(profile[0]).get('version') != 'local-style-2-authored':
                # Recompute only the <=3 selected numeric traits. Old extracted
                # prose is stale, never automatically extracted again.
                self.rebuild_style_profile()
            elif 'extraction_status' not in json.loads(profile[0]):
                # Numeric v1 profiles are retained, but never promoted to a text
                # extraction that the user did not explicitly start.
                migrated = dict(json.loads(profile[0]), **self.empty_style_extraction('not_extracted'))
                self.db.execute('UPDATE style_profiles SET payload=? WHERE id=1', (packed(migrated),))
            elif 'source_phrases' not in json.loads(profile[0]):
                previous = json.loads(profile[0])
                status = 'stale' if previous.get('extraction_status') in ('ready', 'stale') else 'not_extracted'
                previous.update(self.empty_style_extraction(status))
                self.db.execute('UPDATE style_profiles SET payload=? WHERE id=1', (packed(previous),))
            # Only the two bounded cached profile rows are migrated. Do not
            # read source messages or re-extract a user's style at startup.
            for table in ('style_profiles', 'style_corpus_profile'):
                row = self.db.execute('SELECT payload FROM '+table+' WHERE id=1').fetchone()
                if row:
                    previous = json.loads(row[0])
                    normalized = self.normalize_style_extraction(previous)
                    if normalized != previous:
                        self.db.execute('UPDATE '+table+' SET payload=? WHERE id=1', (packed(normalized),))
                        self.bump()
        self._sql_step_observer = None
        self._query_budget = None
        self.db.set_progress_handler(self._sql_progress, 100)
    def _sql_progress(self):
        if self._sql_step_observer is not None: self._sql_step_observer(100)
        if self._query_budget is not None:
            self._query_budget['steps'] += 100
            if self._query_budget['steps'] > self._query_budget.get('max_steps', SEARCH_MAX_VM_STEPS) or time.monotonic() > self._query_budget['deadline']:
                return 1
        return 0
    @contextlib.contextmanager
    def bounded_query(self, max_steps=SEARCH_MAX_VM_STEPS, seconds=SEARCH_MAX_SECONDS):
        previous = self._query_budget
        # The installed VM observer has 100-step resolution. A smaller budget
        # cannot be measured reliably, so reject it before executing a query.
        if max_steps < 100 or seconds <= 0: raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY')
        if previous is None: self._query_budget = {'steps': 0, 'deadline': time.monotonic() + seconds, 'max_steps': max_steps}
        try:
            yield
            if time.monotonic() > self._query_budget['deadline']: raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY')
        except sqlite3.OperationalError as exc:
            if 'interrupt' in str(exc).lower(): raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY') from None
            raise
        finally: self._query_budget = previous
    def mail_index_completed_epoch(self, account_id=None): return self.mail_index.completed_epoch()
    def header_message_ids(self, header, limit=60, children=False):
        # Retained native body versions are historical captures. Current/header
        # discovery selects only the catalog's current version; explicit old
        # case links still go through message() and fail closed as stale.
        if children:
            sql = 'SELECT r.child FROM reply_edges r LEFT JOIN mail_index_versions v ON v.message_id=r.child LEFT JOIN mail_index_catalog c ON c.locator_id=v.locator_id WHERE r.parent_header=?'
        else:
            sql = 'SELECT m.id FROM messages m LEFT JOIN mail_index_versions v ON v.message_id=m.id LEFT JOIN mail_index_catalog c ON c.locator_id=v.locator_id WHERE m.message_id=?'
        sql += ' AND (v.message_id IS NULL OR (c.current_message=v.message_id AND c.metadata_hash=v.metadata_hash AND c.last_seen_epoch>=?)) LIMIT ?'
        with self.bounded_query():
            return [row[0] for row in self.db.execute(sql, (header, self.mail_index.completed_epoch(), limit))]
    def update_size_totals(self):
        for key in ('body_bytes', 'attachment_bytes'):
            value = self.db.execute("SELECT coalesce(sum(json_extract(payload,?)),0) FROM messages", ('$.' + key,)).fetchone()[0]
            self.db.execute('INSERT OR REPLACE INTO meta VALUES(?,?)', (key, value))
    def revision(self): return self.db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0]
    def bump(self): self.db.execute("UPDATE meta SET value=value+1 WHERE key='revision'")
    def add_source(self, path, direction, account, internal):
        if direction not in ('received', 'sent', 'draft', 'unknown'): raise ArchiveError('INVALID_DIRECTION')
        fp = fingerprint(path); sid = digest(str(Path(path).absolute()).encode())
        with self.db:
            old = self.db.execute('SELECT * FROM sources WHERE id=?', (sid,)).fetchone()
            if old and (old['fingerprint'] != fp or old['parser'] != PARSER_VERSION): raise ArchiveError('SOURCE_CHANGED_REIMPORT_REQUIRED')
            if old and (old['direction'], old['account'], old['internal']) != (direction, account, int(internal)):
                raise ArchiveError('SOURCE_METADATA_CHANGED_REIMPORT_REQUIRED')
            self.db.execute('INSERT OR IGNORE INTO sources(id,path,fingerprint,parser,direction,account,internal,updated,bytes) VALUES(?,?,?,?,?,?,?,?,?)',
                            (sid, str(Path(path).absolute()), fp, PARSER_VERSION, direction, account, int(internal), now(), Path(path).stat().st_size))
        return sid
    def add_style_source(self, path, author_confirmed):
        """A deliberate single-.eml choice preserves existing sent metadata."""
        if author_confirmed is not True: raise ArchiveError('STYLE_SENT_AUTHOR_REQUIRED')
        if Path(path).suffix.lower() != '.eml': raise ArchiveError('STYLE_EML_FILE_REQUIRED')
        existing = self.db.execute('SELECT direction,account,internal FROM sources WHERE path=?', (str(Path(path).absolute()),)).fetchone()
        if existing:
            if existing['direction'] != 'sent': raise ArchiveError('STYLE_EXISTING_SOURCE_NOT_SENT')
            return self.add_source(path, 'sent', existing['account'], bool(existing['internal']))
        return self.add_source(path, 'sent', '', False)
    def ingest_batch(self, sid, limit=100):
        src = self.db.execute('SELECT * FROM sources WHERE id=?', (sid,)).fetchone()
        if not src: raise ArchiveError('SOURCE_NOT_FOUND')
        if fingerprint(src['path']) != src['fingerprint']: raise ArchiveError('SOURCE_CHANGED')
        started = time.monotonic(); processed = 0; complete = False
        with self.db:
            for start, end, raw, failure in records(src['path'], src['checkpoint']):
                if processed >= min(max(limit, 1), 200): break
                processed += 1
                message = None
                if not failure:
                    try: message = parse_message(raw, src['direction'], src['account'], bool(src['internal']))
                    except (ArchiveError, RecursionError) as exc: failure = str(exc) if isinstance(exc, ArchiveError) else 'MIME_COMPLEXITY_LIMIT'
                if message:
                    mid = message['id']
                    existed = self.db.execute('SELECT 1 FROM messages WHERE id=?', (mid,)).fetchone()
                    self.db.execute('INSERT OR IGNORE INTO messages VALUES(?,?,?,?,?)', (mid, message['message_id'], message['date'], message['body_hash'], packed(message)))
                    if not existed:
                        self.db.execute("UPDATE meta SET value=value+1 WHERE key='message_count'")
                        for key in ('body_bytes', 'attachment_bytes'):
                            self.db.execute('UPDATE meta SET value=value+? WHERE key=?', (message[key], key))
                        self.db.execute('INSERT INTO search VALUES(?,?)', (mid, ' '.join(tokens(message['subject'] + '\n' + message['body_text'] + '\n' + message['from']))))
                        for parent in set(message['in_reply_to'] + message['references']):
                            self.db.execute('INSERT OR IGNORE INTO reply_edges VALUES(?,?)', (mid, parent))
                    # Hash original range, including envelope/escaping, for later provenance checks.
                    raw_hash = digest(read_source_range(src['path'], start, end, src['fingerprint']))
                    self.db.execute('INSERT OR IGNORE INTO locations VALUES(?,?,?,?,?)', (mid, sid, start, end, raw_hash))
                    if self.db.execute('SELECT 1 FROM styles WHERE message_id=?', (mid,)).fetchone():
                        self.invalidate_style_extraction()
                    column = 'duplicates' if existed else 'imported'
                    self.db.execute('UPDATE sources SET ' + column + '=' + column + '+1 WHERE id=?', (sid,))
                else:
                    self.db.execute('INSERT OR REPLACE INTO failures VALUES(?,?,?)', (sid, start, failure))
                    self.db.execute('UPDATE sources SET failures=failures+1 WHERE id=?', (sid,))
                self.db.execute('UPDATE sources SET checkpoint=?,updated=? WHERE id=?', (end, now(), sid))
            else: complete = True
            if fingerprint(src['path']) != src['fingerprint']: raise ArchiveError('SOURCE_CHANGED_DURING_IMPORT')
            if complete: self.db.execute('UPDATE sources SET done=1 WHERE id=?', (sid,))
            if processed: self.bump()
        row = dict(self.db.execute('SELECT * FROM sources WHERE id=?', (sid,)).fetchone())
        row.pop('path'); row.pop('fingerprint')
        row.update(processed=processed, elapsed=time.monotonic()-started)
        return row
    def message(self, mid, verify=True):
        from direct_store import message as direct_message
        direct = direct_message(self, mid)
        if direct is not None: return direct
        indexed = self.mail_index.message(mid, verify)
        if indexed is not None: return indexed
        row = self.db.execute('SELECT payload FROM messages WHERE id=?', (mid,)).fetchone()
        if not row: raise ArchiveError('MESSAGE_NOT_FOUND')
        message = json.loads(row[0]); message['source_status'] = 'unverified'
        locations = self.db.execute('SELECT l.*,s.path,s.fingerprint,s.direction,s.account,s.internal FROM locations l JOIN sources s ON s.id=l.source_id WHERE l.message_id=? LIMIT ?', (mid, MAX_LOCATIONS + 1)).fetchall()
        if len(locations) > MAX_LOCATIONS: raise ArchiveError('SOURCE_LOCATION_LIMIT')
        valid = []
        for loc in locations:
            try:
                if fingerprint(loc['path']) != loc['fingerprint']: continue
                if verify:
                    original = read_source_range(loc['path'], loc['start'], loc['end'], loc['fingerprint'])
                    if digest(original) != loc['raw_hash']: continue
                valid.append(loc)
            except (OSError, ArchiveError): continue
        message['source_status'] = 'available' if valid else 'missing_or_changed'
        message['range_verified'] = bool(valid and verify)
        # A copy in Drafts must never promote identical bytes to a sent fact.
        directions = {loc['direction'] for loc in valid}
        message['direction'] = directions.pop() if len(directions) == 1 else 'unknown'
        message['internal'] = any(loc['internal'] for loc in locations)
        message['source_locators'] = [{'source_id': loc['source_id'], 'start': loc['start'], 'end': loc['end']} for loc in valid]
        snapshot = self.db.execute('SELECT payload FROM mail_snapshots WHERE message_id=?', (mid,)).fetchone()
        if snapshot:
            metadata = json.loads(snapshot[0]); message['origin'] = metadata['origin']; message['snapshot'] = metadata
            message['attachments_fetched'] = False
            count = metadata['attachment_count']
            if count is None or count > 0:
                message['attachments'] = [{'name': '(original attachments not fetched)', 'media_type': 'application/octet-stream',
                                           'size': 0, 'parse_status': 'not_fetched', 'reported_count': count}]
        return message
    def ingest_mail_snapshot(self, records_input):
        """Bounded public-Mail captures, stored as derived immutable plaintext.

        This does not call Mail, infer sent status from From, or confirm authorship.
        Attachment content and original MIME were not fetched. Native identifiers
        stay in private storage; the IPC result has only local content IDs.
        """
        if not isinstance(records_input, list) or not 1 <= len(records_input) <= MAX_MAIL_SNAPSHOTS:
            raise ArchiveError('MAIL_SNAPSHOT_LIMIT')
        prepared = []; identities = set()
        for record in records_input:
            if not isinstance(record, dict): raise ArchiveError('MAIL_SNAPSHOT_RECORD_INVALID')
            def field(key, maximum, default=''):
                value = record.get(key, default)
                if not isinstance(value, str) or len(value) > maximum: raise ArchiveError('MAIL_SNAPSHOT_INPUT_LIMIT')
                return value
            native_id = field('id', 512); account = field('accountID', 1024); mailbox = field('mailbox', 1024)
            if not native_id or (account, native_id) in identities: raise ArchiveError('MAIL_SNAPSHOT_DUPLICATE_OR_MISSING_ID')
            identities.add((account, native_id))
            direction = record.get('direction', 'unknown')
            if direction not in ('sent', 'received', 'unknown'): raise ArchiveError('MAIL_SNAPSHOT_DIRECTION')
            body = field('body', 12000); raw_headers = field('headers', 32768)
            subject = field('subject', 4096); sender = field('sender', 1024); header_id = field('messageID', 512).strip('<>')
            count = record.get('attachmentCount')
            if count is not None and (type(count) is not int or not 0 <= count <= 10000): raise ArchiveError('MAIL_SNAPSHOT_ATTACHMENT_COUNT')
            metadata = {'origin': 'apple_mail_readonly_snapshot', 'native_id': native_id, 'account_id': account,
                        'mailbox': mailbox, 'direction': direction, 'attachment_count': count,
                        'attachments_fetched': False, 'original_mime_fetched': False}
            original = Parser(policy=email.policy.default).parsestr(raw_headers, headersonly=True)
            message = EmailMessage(policy=email.policy.SMTP)
            def header(name, value):
                if not value: return
                value = str(value)
                if len(value) > 8192 or re.search(r'[\x00-\x1f\x7f]', value): raise ArchiveError('MAIL_SNAPSHOT_HEADER_INVALID')
                try: message[name] = value
                except (ValueError, TypeError): raise ArchiveError('MAIL_SNAPSHOT_HEADER_INVALID') from None
            header('Message-ID', '<' + header_id + '>' if header_id else original.get('Message-ID', ''))
            header('Subject', subject or original.get('Subject', ''))
            header('From', sender or original.get('From', ''))
            for name in ('References', 'In-Reply-To', 'Date'): header(name, original.get(name, ''))
            # Stable metadata participates in identity, preventing captures from
            # different accounts/mailboxes/directions from silently merging.
            header('X-HarborReply-Snapshot', packed(metadata))
            message.set_content(body, charset='utf-8')
            raw = message.as_bytes(); parse_message(raw, direction, account, False)
            prepared.append((raw, metadata))
        folder = self.snapshot_directory
        if any(p.is_symlink() for p in [folder] + list(folder.parents)): raise ArchiveError('SYMLINK_NOT_ALLOWED')
        folder.mkdir(mode=0o700, exist_ok=True); os.chmod(folder, 0o700)
        mids = []
        for raw, metadata in prepared:
            path = folder / (digest(raw) + '.eml')
            try: descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, 'O_NOFOLLOW', 0), 0o600)
            except FileExistsError:
                fp = fingerprint(path)
                if path.stat().st_size != len(raw) or read_source_range(path, 0, len(raw), fp) != raw: raise ArchiveError('MAIL_SNAPSHOT_FILE_CHANGED')
            else:
                with os.fdopen(descriptor, 'wb') as output: output.write(raw)
            # chmod of an unchanged file still changes ctime on macOS. Do not
            # invalidate our own stored fingerprint when deduplicating a capture.
            if stat.S_IMODE(path.stat().st_mode) != 0o600: os.chmod(path, 0o600)
            sid = self.add_source(path, metadata['direction'], metadata['account_id'], False)
            imported = self.ingest_batch(sid, 1)
            if not imported['done'] or imported['failures']: raise ArchiveError('MAIL_SNAPSHOT_IMPORT_FAILED')
            ids = self.source_message_ids(sid)
            if len(ids) != 1: raise ArchiveError('MAIL_SNAPSHOT_IDENTITY_FAILED')
            with self.db:
                old = self.db.execute('SELECT payload FROM mail_snapshots WHERE message_id=?', (ids[0],)).fetchone()
                if old is None:
                    self.db.execute('INSERT INTO mail_snapshots VALUES(?,?)', (ids[0], packed(metadata))); self.bump()
                elif json.loads(old[0]) != metadata: raise ArchiveError('MAIL_SNAPSHOT_METADATA_CHANGED')
            mids.append(ids[0])
        return {'message_ids': mids, 'origin': 'apple_mail_readonly_snapshot', 'attachments_fetched': False}
    def source_message_ids(self, sid):
        """Resolve a user-selected source without searching unrelated mail.

        Two indexed location rows are enough to distinguish a single .eml from
        a multi-record source. No body or source path crosses the IPC boundary.
        """
        source = self.db.execute('SELECT path,fingerprint FROM sources WHERE id=?', (sid,)).fetchone()
        if not source: raise ArchiveError('SOURCE_NOT_FOUND')
        if fingerprint(source['path']) != source['fingerprint']: raise ArchiveError('SOURCE_CHANGED')
        return [r[0] for r in self.db.execute('SELECT message_id FROM locations WHERE source_id=? ORDER BY start LIMIT 2', (sid,))]
    def search(self, query, limit=40):
        return self._search(query, limit, hydrate=True)
    def search_ids(self, query, limit=40):
        return self._search(query, limit, hydrate=False)
    def related_candidates(self, current, limit=60):
        rank_related_rows(current, [])  # Validate bounded current metadata first.
        features = related_features(current.get('subject', ''), current.get('sender', ''))
        quote = lambda term: '"' + term.replace('"', '""') + '"'
        alternatives = lambda values: '(' + ' OR '.join(values) + ')'
        meaningful = [quote(word) for word in features['meaningful']]
        queries = []
        if meaningful:
            # Generic overlap tiers keep specific matches ahead of broad hits,
            # with three bounded index queries regardless of archive size.
            queries.append(' AND '.join(meaningful))
            if len(meaningful) > 1:
                queries.append(alternatives(['(' + a + ' AND ' + b + ')' for a, b in zip(meaningful, meaningful[1:])]))
            queries.append(alternatives(meaningful))
        if not queries: return []
        if SEARCH_MAX_VM_STEPS <= 0 or SEARCH_MAX_SECONDS <= 0: raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY')
        self._query_budget = {'steps': 0, 'deadline': time.monotonic() + SEARCH_MAX_SECONDS}
        try:
            mids = []
            for query in list(dict.fromkeys(queries))[:3]:
                for row in self.db.execute(SEARCH_SQL, (query, 60)):
                    if row[0] not in mids: mids.append(row[0])
            rows = []
            for mid in mids[:MAX_RELATED_POOL]:
                if mid.startswith('direct:') and not self.db.execute('SELECT 1 FROM direct_files WHERE message=? AND active=1 LIMIT 1', (mid,)).fetchone(): continue
                indexed = self.mail_index.rank_metadata(mid)
                if indexed is not None:
                    if indexed: rows.append(indexed)
                    continue
                # Project only metadata out of the indexed payload. A large
                # body is neither hydrated nor parsed into Python to rank it.
                row = self.db.execute("SELECT id,json_extract(payload,'$.subject') AS subject,json_extract(payload,'$.from') AS sender,message_id AS messageID FROM messages WHERE id=?", (mid,)).fetchone()
                if row: rows.append(dict(row))
            rows = list({row['id']: row for row in rows}.values())
            result = rank_related_rows(current, rows, limit)
            if time.monotonic() > self._query_budget['deadline']: raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY')
            return result
        except sqlite3.OperationalError as exc:
            if 'interrupt' in str(exc).lower(): raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY') from None
            raise
        finally: self._query_budget = None
    def _search(self, query, limit, hydrate):
        if len(query) > 4096: raise ArchiveError('SEARCH_QUERY_TOO_LONG')
        terms = query_tokens(query)
        if not terms: return []
        match = ' AND '.join('"' + t.replace('"', '""') + '"' for t in terms)
        # FTS5 can stop after the bounded reverse-docid postings. Global BM25
        # ordering evaluates every common-term hit, even when LIMIT is small.
        # Results are most recently indexed matches, not a date/relevance ranking.
        if SEARCH_MAX_VM_STEPS <= 0 or SEARCH_MAX_SECONDS <= 0:
            raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY')
        self._query_budget = {'steps': 0, 'deadline': time.monotonic() + SEARCH_MAX_SECONDS}
        try:
            result = [self.message(r[0], False) if hydrate else r[0] for r in self.db.execute(SEARCH_SQL, (match, min(max(limit, 1), 100)))]
            if time.monotonic() > self._query_budget['deadline']:
                raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY')
            return result
        except sqlite3.OperationalError as exc:
            if 'interrupt' in str(exc).lower(): raise ArchiveError('SEARCH_BUDGET_EXCEEDED_NARROW_QUERY') from None
            raise
        finally: self._query_budget = None
    def case_message_ids(self, cid):
        rows = self.db.execute(CASE_MESSAGES_SQL, (cid, MAX_CASE_MESSAGES + 1)).fetchall()
        if len(rows) > MAX_CASE_MESSAGES: raise ArchiveError('CASE_SCOPE_TOO_LARGE_NARROW_REQUIRED')
        return [r[0] for r in rows]
    def case_events(self, cid):
        rows = self.db.execute(CASE_EVENTS_SQL, (cid, MAX_CASE_EVENTS + 1)).fetchall()
        if len(rows) > MAX_CASE_EVENTS: raise ArchiveError('CASE_EVENTS_TOO_LARGE_NARROW_REQUIRED')
        return [dict(r) for r in rows if self.db.execute('SELECT 1 FROM memberships WHERE case_id=? AND message_id=? AND confirmed=1', (cid, r['message_id'])).fetchone()]
    def case_create(self, label, vessel='', voyage='', cargo=''):
        import uuid
        cid = str(uuid.uuid4())
        with self.db:
            self.db.execute('INSERT INTO cases VALUES(?,?,?,?,?)', (cid, label, vessel, voyage, cargo)); self.bump()
        return cid
    def membership(self, cid, mid, include):
        with self.db:
            if include:
                row = self.db.execute('SELECT date FROM messages WHERE id=?', (mid,)).fetchone()
                if not row: raise ArchiveError('MESSAGE_NOT_FOUND')
                self.db.execute('INSERT OR REPLACE INTO memberships VALUES(?,?,?,1,?)', (cid, mid, 'user_confirmed', row[0]))
            else: self.db.execute('DELETE FROM memberships WHERE case_id=? AND message_id=?', (cid, mid))
            self.bump()
    def event_add(self, event):
        import uuid
        m = self.message(event['message_id'])
        if m['source_status'] != 'available' or m['direction'] in ('draft', 'unknown'): raise ArchiveError('EVENT_SOURCE_UNCONFIRMED')
        if event['kind'] not in ('requested', 'reported', 'received', 'checked', 'approved', 'held', 'corrected', 'cancelled'): raise ArchiveError('EVENT_KIND')
        if not event['quote'] or event['quote'] not in m['body_text']: raise ArchiveError('EVENT_QUOTE_MISSING')
        if not self.db.execute('SELECT 1 FROM memberships WHERE case_id=? AND message_id=?', (event['case_id'], m['id'])).fetchone(): raise ArchiveError('EVENT_NOT_IN_CASE')
        previous = event.get('supersedes', '')
        if previous:
            prior = self.db.execute('SELECT * FROM events WHERE id=?', (previous,)).fetchone()
            if not prior or any(prior[k] != event[k] for k in ('case_id', 'subject', 'action')): raise ArchiveError('CORRECTION_SCOPE_MISMATCH')
            if event['kind'] not in ('corrected', 'cancelled'): raise ArchiveError('CORRECTION_KIND')
        eid = str(uuid.uuid4())
        with self.db:
            self.db.execute('INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)', (eid, event['case_id'], m['id'], event['kind'], event['subject'], event['action'], event.get('value', ''), event['quote'], m['body_hash'], m['from'], m['date'], previous, int(event.get('confirmed', False))))
            self.bump()
        return eid
    def policies(self): return [json.loads(r[0]) for r in self.db.execute('SELECT payload FROM policies')]
    def policy_add(self, p):
        required = ('title', 'version', 'section', 'effective', 'conditions', 'source', 'text')
        if not all(p.get(k, '').strip() for k in required) or not p.get('confirmed'): raise ArchiveError('POLICY_CONFIRM_REQUIRED')
        pid = digest(packed(p).encode())
        with self.db:
            self.db.execute('INSERT OR REPLACE INTO policies VALUES(?,?)', (pid, packed(dict(p, id=pid)))); self.bump()
        return pid
    def style_add(self, mid, author_confirmed):
        m = self.message(mid)
        if author_confirmed is not True or m['direction'] != 'sent' or m['source_status'] != 'available': raise ArchiveError('STYLE_SENT_AUTHOR_REQUIRED')
        with self.db:
            import style_corpus
            style_corpus.clear(self)
            if self.db.execute('SELECT 1 FROM styles WHERE message_id=?', (mid,)).fetchone() is None and self.db.execute('SELECT count(*) FROM styles').fetchone()[0] >= MAX_STYLE_EXAMPLES:
                raise ArchiveError('STYLE_LIMIT_3')
            self.db.execute('INSERT OR REPLACE INTO styles VALUES(?,1)', (mid,))
            self.rebuild_style_profile(); self.bump()
    def style_remove(self, mid):
        with self.db:
            import style_corpus
            style_corpus.clear(self)
            self.db.execute('DELETE FROM styles WHERE message_id=?', (mid,))
            self.rebuild_style_profile(); self.bump()
    def style_replace(self, mids, author_confirmed):
        """Replace only style links after an explicit authored-and-sent choice."""
        if author_confirmed is not True: raise ArchiveError('STYLE_SENT_AUTHOR_REQUIRED')
        if not isinstance(mids, list) or not 1 <= len(mids) <= MAX_STYLE_EXAMPLES:
            raise ArchiveError('STYLE_LIMIT_1_TO_3')
        if not all(isinstance(mid, str) and mid for mid in mids): raise ArchiveError('STYLE_MESSAGE_REQUIRED')
        selected = list(dict.fromkeys(mids)); revision = self.revision()
        for mid in selected:
            m = self.message(mid)
            if m['direction'] != 'sent' or m['source_status'] != 'available': raise ArchiveError('STYLE_SENT_AUTHOR_REQUIRED')
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            if self.revision() != revision: raise ArchiveError('STYLE_CHANGED_DURING_SELECTION')
            import style_corpus
            style_corpus.clear(self)
            self.db.execute('DELETE FROM styles')
            self.db.executemany('INSERT INTO styles VALUES(?,1)', ((mid,) for mid in selected))
            self.rebuild_style_profile(require_available=True)
            self.bump()
        return self.style_summary()
    def rebuild_style_profile(self, require_available=False):
        """Extract format statistics once from explicitly approved sent examples.

        No corpus scan, model call, quoted text, names, dates or business facts
        enter this profile. The user-written profile remains separately editable.
        Generation rechecks these few source ranges before using the cache.
        """
        texts = []; manifest = []
        old = self.db.execute('SELECT payload FROM style_profiles WHERE id=1').fetchone()
        status = 'stale' if old and json.loads(old[0]).get('extraction_status') in ('ready', 'stale') else 'not_extracted'
        for r in self.db.execute('SELECT message_id FROM styles WHERE author_confirmed=1 ORDER BY message_id LIMIT ?', (MAX_STYLE_EXAMPLES,)):
            m = self.message(r[0])
            if m['source_status'] != 'available' or m['direction'] != 'sent':
                if require_available: raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
                continue
            text = authored_text(m['body_text'])
            if text: texts.append(text)
            manifest.append({'message_id': m['id'], 'body_hash': m['body_hash']})
        summary = self.style_traits(texts)
        summary.update(self.empty_style_extraction(status))
        self.db.execute('INSERT OR REPLACE INTO style_profiles VALUES(1,?,?)', (packed(summary), packed(manifest)))
        return summary
    @staticmethod
    def empty_style_extraction(status):
        return {'extraction_status': status, 'description': '', 'source_phrases': [],
                'description_origin': 'observed_format_traits', 'extracted_at': None}
    @staticmethod
    def style_traits(texts):
        paragraphs = [p.strip() for text in texts for p in re.split(r'\n\s*\n', text) if p.strip()]
        sentences = [s.strip() for text in texts for s in re.split(r'[。！？.!?]+', text) if s.strip()]
        counts = [len([p for p in re.split(r'\n\s*\n', text) if p.strip()]) for text in texts]
        japanese = any(re.search(r'[\u3040-\u30ff\u3400-\u9fff]', text) for text in texts)
        english = any(re.search(r'[A-Za-z]', text) for text in texts)
        return {'version': 'local-style-2-authored', 'example_count': len(texts),
                   'paragraph_characters_median': int(statistics.median(map(len, paragraphs))) if paragraphs else 0,
                   'sentence_characters_median': int(statistics.median(map(len, sentences))) if sentences else 0,
                   'paragraphs_per_message_median': int(statistics.median(counts)) if counts else 0,
                   'uses_bullets': any(re.search(r'(?m)^\s*(?:[-*•]|\d+[.)])\s', text) for text in texts),
                   'polite_request_ratio': round(sum(bool(re.search(r'\bplease\b|ください|お願い', s, re.I)) for s in sentences) / max(len(sentences), 1), 3),
                   'language': 'Mixed' if japanese and english else 'Japanese' if japanese else 'English' if english else 'Unknown'}
    def text_style_summary(self):
        row = self.db.execute('SELECT payload FROM style_text_profile WHERE id=1').fetchone()
        return json.loads(row[0]) if row else None

    def publish_text_style(self, value):
        description = value.get('description')
        if (type(description) is not str or not description.strip() or len(description) > 64000
                or type(value.get('characters')) is not int or not 1 <= value['characters'] <= 524288
                or type(value.get('messages')) is not int or value['messages'] < 1
                or any(type(value.get(k)) is not str or not value[k] or len(value[k]) > 1024
                       for k in ('source_address', 'source_account_id'))):
            raise ArchiveError('IPC_REQUEST_INVALID')
        summary = dict(self.style_traits([]), example_count=value['messages'], extraction_status='ready',
                       description=description, description_origin='llm_sent_text', extracted_at=now(),
                       source_phrases=[], source_address=value['source_address'], source_account_id=value['source_account_id'],
                       characters=value['characters'])
        with self.db:
            self.db.execute('INSERT OR REPLACE INTO style_text_profile VALUES(1,?)', (packed(summary),))
            self.bump()
        return summary

    def selected_style_messages(self):
        if self.text_style_summary() is not None: return []
        import style_corpus
        if style_corpus.has_profile(self): return style_corpus.selected_messages(self)
        rows = self.db.execute('SELECT message_id,author_confirmed FROM styles ORDER BY message_id LIMIT ?', (MAX_STYLE_EXAMPLES + 1,)).fetchall()
        if len(rows) > MAX_STYLE_EXAMPLES: raise ArchiveError('STYLE_LIMIT_3')
        messages = []
        for row in rows:
            m = self.message(row['message_id'])
            if row['author_confirmed'] != 1 or m['source_status'] != 'available' or m['direction'] != 'sent':
                raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
            messages.append(m)
        return messages
    def invalidate_style_extraction(self):
        row = self.db.execute('SELECT payload FROM style_profiles WHERE id=1').fetchone()
        if not row: return False
        summary = json.loads(row[0])
        if summary.get('extraction_status') != 'ready': return False
        summary.update(self.empty_style_extraction('stale'))
        self.db.execute('UPDATE style_profiles SET payload=? WHERE id=1', (packed(summary),))
        return True
    @staticmethod
    def describe_style(summary):
        """Describe measured format traits without inventing example sentences."""
        compact = summary['sentence_characters_median'] <= 80
        description = ('短い文で要点を伝え、段落ごとに内容を分ける文体です。' if compact else
                       '背景や要点を文章で説明し、段落ごとに内容をまとめる文体です。')
        description += '依頼は丁寧な表現を使います。' if summary['polite_request_ratio'] > 0 else '用件を直接伝える構成です。'
        if summary['uses_bullets']: description += '複数の項目は箇条書きで整理します。'
        return description
    @staticmethod
    def style_source_description(description, phrases):
        if phrases:
            return description + '\n\n原文で確認できた定型フレーズ：\n' + '\n'.join('「'+phrase+'」' for phrase in phrases)
        return description + '\n\n原文の定型フレーズは確認できませんでした。'
    @staticmethod
    def normalize_style_extraction(summary):
        """Remove retired templates from cached output without reading sources.

        Existing, explicitly extracted traits and exact neutral source phrases
        can be retained. Missing phrase provenance requires new extraction;
        cached prose is always rebuilt from measurements, never trusted verbatim.
        """
        value = dict(summary)
        value.pop('examples', None)
        value.pop('example_origin', None)
        if value.get('extraction_status') == 'ready' and 'source_phrases' in value:
            phrases = value.get('source_phrases')
            phrases = list(dict.fromkeys(phrase for phrase in phrases if isinstance(phrase, str) and phrase in NEUTRAL_STYLE_PHRASES))[:3] if isinstance(phrases, list) else []
            try:
                description = Archive.describe_style(value)
            except (KeyError, TypeError, ValueError):
                value.update(Archive.empty_style_extraction('stale'))
            else:
                value.update(description=Archive.style_source_description(description, phrases), source_phrases=phrases,
                             description_origin='observed_format_traits')
        else:
            status = 'stale' if value.get('extraction_status') in ('ready', 'stale') else 'not_extracted'
            value.update(Archive.empty_style_extraction(status))
        return value
    @staticmethod
    def neutral_source_phrases(texts):
        phrases = []
        for text in texts:
            for line in text.splitlines():
                if line in NEUTRAL_STYLE_PHRASES and line not in phrases:
                    phrases.append(line)
                    if len(phrases) == 3: return phrases
        return phrases
    def style_extract(self):
        """Only this explicit command persists a prose style description.

        Work depends on the selected body bytes and paragraph/sentence counts,
        with at most three messages and no model/network call. Revisions,
        identities and range hashes are checked.
        """
        revision = self.revision()
        try: messages = self.selected_style_messages()
        except ArchiveError:
            with self.db:
                if self.invalidate_style_extraction(): self.bump()
            raise
        if not messages: raise ArchiveError('STYLE_EXAMPLES_REQUIRED')
        texts = [text for m in messages for text in [authored_text(m['body_text'])] if text]
        if not texts: raise ArchiveError('STYLE_EXAMPLES_EMPTY_BODY')
        summary = self.style_traits(texts)
        description = self.describe_style(summary)
        phrases = self.neutral_source_phrases(texts)
        description = self.style_source_description(description, phrases)
        summary.update({'extraction_status': 'ready', 'description': description,
                        'source_phrases': phrases,
                        'description_origin': 'observed_format_traits', 'extracted_at': now()})
        manifest = [{'message_id': m['id'], 'body_hash': m['body_hash']} for m in messages]
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            if self.revision() != revision: raise ArchiveError('STYLE_CHANGED_DURING_EXTRACTION')
            # Fingerprints are checked again after CPU work without rereading the
            # corpus. Generation rechecks the selected ranges before using it.
            for m in messages:
                checked = self.message(m['id'], verify=False)
                if checked['source_status'] != 'available' or checked['direction'] != 'sent': raise ArchiveError('STYLE_SOURCE_UNAVAILABLE')
            self.db.execute('INSERT OR REPLACE INTO style_profiles VALUES(1,?,?)', (packed(summary), packed(manifest)))
            self.bump()
        return summary
    def style_summary(self, verify=False, verified_messages=None):
        text_summary = self.text_style_summary()
        if text_summary is not None: return text_summary
        import style_corpus
        if style_corpus.has_profile(self): return style_corpus.summary(self, verify=verify, verified_messages=verified_messages)
        row = self.db.execute('SELECT payload,manifest FROM style_profiles WHERE id=1').fetchone()
        summary = self.normalize_style_extraction(json.loads(row['payload']))
        if summary.get('extraction_status') == 'ready' and (verify or verified_messages is not None):
            try:
                messages = verified_messages if verified_messages is not None else self.selected_style_messages()
                manifest = [{'message_id': m['id'], 'body_hash': m['body_hash']} for m in messages]
                valid = manifest == json.loads(row['manifest']) and bool(messages)
            except ArchiveError: valid = False
            if not valid:
                with self.db:
                    self.invalidate_style_extraction(); self.bump()
                summary.update(self.empty_style_extraction('stale'))
        return summary
    def candidate_previews(self, mids, reasons=None):
        previews = []
        for mid in list(dict.fromkeys(mids))[:MAX_CANDIDATE_PREVIEWS]:
            preview = self.mail_index.preview(mid)
            if preview is None:
                m = self.message(mid, verify=False)
                preview = {k: m[k] for k in ('id', 'subject', 'date', 'direction', 'source_status', 'attachments')}
                if m.get('origin'): preview['origin'] = m['origin']; preview['attachments_fetched'] = False
            if reasons and reasons.get(mid):
                preview['related_reason'] = {'reply_header': '返信ヘッダーが一致',
                                             'sender_terms': '送信者と件名の語句が一致',
                                             'subject_terms': '件名の語句が一致'}.get(reasons[mid], reasons[mid])
            previews.append(preview)
        return previews
    def coverage(self):
        """O(log N) index endpoint reads plus O(1) maintained totals.

        This does not enumerate or stat all sources. Chosen evidence and style
        examples are separately verified. Full source diagnostics are explicit.
        """
        first = self.db.execute('SELECT date FROM messages WHERE date IS NOT NULL ORDER BY date LIMIT 1').fetchone()
        last = self.db.execute('SELECT date FROM messages WHERE date IS NOT NULL ORDER BY date DESC LIMIT 1').fetchone()
        totals = dict(self.db.execute("SELECT key,value FROM meta WHERE key IN ('body_bytes','attachment_bytes','message_count')"))
        return {'count': totals.pop('message_count'), **totals,
                'range_start': first[0] if first else None, 'range_end': last[0] if last else None,
                'revision': self.revision(), 'snapshot_only': True}
    def status(self):
        sources = []
        for r in self.db.execute('SELECT * FROM sources'):
            s = dict(r)
            try: s['status'] = 'available' if fingerprint(s['path']) == s['fingerprint'] else 'changed'
            except (OSError, ArchiveError): s['status'] = 'missing'
            s['errors'] = [dict(x) for x in self.db.execute('SELECT start,reason FROM failures WHERE source_id=? LIMIT 30', (s['id'],))]
            sources.append(s)
        return {'sources': sources, **self.coverage()}
    def delete_source(self, sid):
        with self.db:
            self.db.execute('DELETE FROM sources WHERE id=?', (sid,))
            self.db.execute('DELETE FROM search WHERE id IN (SELECT id FROM messages WHERE NOT EXISTS(SELECT 1 FROM locations WHERE locations.message_id=messages.id) AND NOT EXISTS(SELECT 1 FROM mail_index_versions WHERE mail_index_versions.message_id=messages.id))')
            self.db.execute('DELETE FROM messages WHERE NOT EXISTS(SELECT 1 FROM locations WHERE locations.message_id=messages.id) AND NOT EXISTS(SELECT 1 FROM mail_index_versions WHERE mail_index_versions.message_id=messages.id)')
            self.update_size_totals()
            self.db.execute("UPDATE meta SET value=(SELECT count(*) FROM messages) WHERE key='message_count'")
            self.rebuild_style_profile()
            self.bump()
        self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        self.db.execute('VACUUM')
        self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
