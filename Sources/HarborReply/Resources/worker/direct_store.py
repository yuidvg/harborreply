"""Incremental derived index. Source capability lives only in sandboxed helper.

Discovery is O(files); content IO is O(changed MIME bytes), bounded per message.
No original files or attachment payloads are persisted. Mail databases are never opened.
"""
import atexit
import copy
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

SESSIONS = {}
PROFILE = '(version 1) (allow default) (deny file-write*) (deny network*)'


def schema(db):
    db.executescript('''
    CREATE TABLE IF NOT EXISTS direct_files(key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
        message TEXT, seen TEXT NOT NULL, active INTEGER NOT NULL, error TEXT NOT NULL, search_rowid INTEGER);
    CREATE INDEX IF NOT EXISTS direct_message ON direct_files(message);
    CREATE INDEX IF NOT EXISTS direct_seen ON direct_files(seen);
    CREATE TABLE IF NOT EXISTS direct_status(id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL);
    ''')


def close(key):
    session = SESSIONS.pop(key, None)
    if session:
        process = session['process']
        process.stdin.close()
        if process.poll() is None: process.terminate()
        try: process.wait(timeout=2)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
        process.stdout.close()


@atexit.register
def cleanup():
    for key in list(SESSIONS): close(key)


def state(db):
    schema(db)
    row = db.execute('SELECT value FROM direct_status WHERE id=1').fetchone()
    return json.loads(row[0]) if row else None


def save(db, value):
    db.execute('INSERT OR REPLACE INTO direct_status VALUES(1,?)', (json.dumps(value),))


def start(archive, helper, root):
    from archive import ArchiveError
    schema(archive.db)
    key = str(archive.db.execute('PRAGMA database_list').fetchone()[2])
    close(key)
    # This is intentionally mandatory, including developer builds: never fall
    # back to an unsandboxed helper when the platform denies sandbox creation.
    if not Path(helper).is_file() or not os.access(helper, os.X_OK): raise ArchiveError('DIRECT_READER_MISSING')
    process = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', PROFILE, helper, root],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        env={'PATH': '/usr/bin:/bin'}, bufsize=65536)
    value = {'scan_id': str(uuid.uuid4()), 'epoch': 1, 'status': 'running', 'discovery_done': False,
        'warning': '', 'counts': dict(mailboxes=0, mailboxes_done=0, metadata=0, captured=0,
            unreadable=0, too_large=0, metadata_only=0, body_bytes=0, pages=0),
        'metrics': dict(visited=0, body_reads=0, unchanged=0, mime_bytes=0,
            source_seconds=0.0, parse_seconds=0.0, save_seconds=0.0)}
    SESSIONS[key] = {'process': process, 'value': value, 'namespace': hashlib.sha256(root.encode()).hexdigest()}
    with archive.db: save(archive.db, value)
    return value


def frame(process):
    from archive import ArchiveError
    # Largest allowed MIME (16 MiB) becomes ~22 MiB of base64. Not UI IPC.
    line = process.stdout.readline(23 * 1024 * 1024)
    if not line.endswith(b'\n'): raise ArchiveError('DIRECT_READER_PROTOCOL')
    try: value = json.loads(line)
    except (ValueError, TypeError): raise ArchiveError('DIRECT_READER_PROTOCOL') from None
    if type(value) is not dict: raise ArchiveError('DIRECT_READER_PROTOCOL')
    return value


def step(archive, scan_id):
    from archive import ArchiveError, parse_message, packed, tokens, digest
    key = str(archive.db.execute('PRAGMA database_list').fetchone()[2])
    session = SESSIONS.get(key)
    if not session or session['value']['scan_id'] != scan_id: raise ArchiveError('DIRECT_SCAN_RESTART_REQUIRED')
    process, value = session['process'], session['value']
    metrics, counts = value['metrics'], value['counts']
    started = time.monotonic()
    committed = copy.deepcopy(value)
    try:
        with archive.db:
            for _ in range(64):
                timer = time.monotonic(); item = frame(process)
                metrics['source_seconds'] += time.monotonic() - timer
                if item.get('done') is True:
                    # Absence is applied only after a successful full traversal.
                    for absent in archive.db.execute('SELECT search_rowid FROM direct_files WHERE seen<>? AND active=1', (scan_id,)):
                        if absent[0] is not None: archive.db.execute('DELETE FROM search WHERE rowid=?', (absent[0],))
                    archive.db.execute('UPDATE direct_files SET active=0,search_rowid=NULL WHERE seen<>?', (scan_id,))
                    value.update(status='complete', discovery_done=True)
                    close(key); break
                if 'error' in item:
                    if item['error'] == 'permission': raise ArchiveError('DIRECT_SOURCE_PERMISSION')
                    raise ArchiveError('DIRECT_SOURCE_UNAVAILABLE')
                if not all(type(item.get(k)) is str for k in ('key', 'fingerprint', 'mailbox')): raise ArchiveError('DIRECT_READER_PROTOCOL')
                source_key = session['namespace'] + ':' + item['key']
                old = archive.db.execute('SELECT fingerprint,message,error,active,search_rowid FROM direct_files WHERE key=?', (source_key,)).fetchone()
                metrics['visited'] += 1; counts['metadata'] += 1
                # Failed items are retried: a server can finish downloading a
                # previously incomplete message without a successful parse yet.
                unchanged = old and old['fingerprint'] == item['fingerprint'] and old['active'] and not old['error']
                timer = time.monotonic()
                process.stdin.write(b'skip\n' if unchanged else b'read\n'); process.stdin.flush()
                if unchanged:
                    metrics['unchanged'] += 1; counts['captured'] += 1
                    archive.db.execute('UPDATE direct_files SET seen=?,active=1 WHERE key=?', (scan_id, source_key))
                else:
                    metrics['body_reads'] += 1
                    content = frame(process)
                    metrics['source_seconds'] += time.monotonic() - timer
                    error, message = content.get('error', ''), None
                    if not error:
                        timer = time.monotonic()
                        try:
                            raw = base64.b64decode(content['content'], validate=True)
                            metrics['mime_bytes'] += len(raw)
                            # Folder names are not proof of sent status. Unknown
                            # direction remains excluded from factual/style evidence.
                            message = parse_message(raw, direction='unknown')
                            message['id'] = 'direct:' + digest((source_key + ':' + message['id']).encode())
                        except ArchiveError as failure:
                            # Parser errors are fixed internal codes, never MIME text.
                            error = failure.args[0] if len(failure.args) == 1 and type(failure.args[0]) is str else 'malformed'
                        except (ValueError, KeyError, RecursionError): error = 'malformed'
                        metrics['parse_seconds'] += time.monotonic() - timer
                    timer = time.monotonic()
                    search_rowid = None
                    if old and old['search_rowid'] is not None:
                        archive.db.execute('DELETE FROM search WHERE rowid=?', (old['search_rowid'],))
                    if message:
                        mid = message['id']
                        existed = archive.db.execute('SELECT 1 FROM messages WHERE id=?', (mid,)).fetchone()
                        if not existed:
                            archive.db.execute('INSERT INTO messages VALUES(?,?,?,?,?)', (mid, message['message_id'], message['date'], message['body_hash'], packed(message)))

                            for parent in set(message['in_reply_to'] + message['references']):
                                archive.db.execute('INSERT OR IGNORE INTO reply_edges VALUES(?,?)', (mid, parent))
                            archive.db.execute("UPDATE meta SET value=value+1 WHERE key='message_count'")
                            archive.db.execute("UPDATE meta SET value=value+? WHERE key='body_bytes'", (message['body_bytes'],))
                        search_rowid = archive.db.execute('INSERT INTO search VALUES(?,?)', (mid, ' '.join(tokens(message['subject'] + '\n' + message['body_text'] + '\n' + message['from'])))).lastrowid
                        counts['captured'] += 1; counts['body_bytes'] += message['body_bytes']
                    else:
                        counts['too_large' if error == 'tooLarge' else 'unreadable'] += 1
                    archive.db.execute('INSERT OR REPLACE INTO direct_files VALUES(?,?,?,?,1,?,?)',
                        (source_key, item['fingerprint'], message['id'] if message else None, scan_id, error, search_rowid))
                    metrics['save_seconds'] += time.monotonic() - timer
                if time.monotonic() - started >= 1: break
            counts['pages'] += 1
            archive.bump(); save(archive.db, value)
        return value
    except Exception:
        close(key)
        # Transactions never sweep unseen files after an interrupted traversal.
        value = committed
        value['status'] = 'paused'
        with archive.db: save(archive.db, value)
        raise


def pause(archive, scan_id):
    from archive import ArchiveError
    key = str(archive.db.execute('PRAGMA database_list').fetchone()[2])
    value = state(archive.db)
    if not value or value['scan_id'] != scan_id: raise ArchiveError('DIRECT_SCAN_RESTART_REQUIRED')
    close(key); value['status'] = 'paused'
    with archive.db: save(archive.db, value)
    return value


def message(archive, mid):
    from archive import ArchiveError, digest
    if not mid.startswith('direct:'): return None
    schema(archive.db)
    row = archive.db.execute('SELECT payload FROM messages WHERE id=?', (mid,)).fetchone()
    if not row: raise ArchiveError('MESSAGE_NOT_FOUND')
    result = json.loads(row[0])
    active = archive.db.execute('SELECT 1 FROM direct_files WHERE message=? AND active=1 LIMIT 1', (mid,)).fetchone()
    valid = bool(active) and digest(result['body_text'].encode()) == result['body_hash']
    result.update(source_status='available' if valid else 'missing_or_changed',
        origin='mail_store_readonly', range_verified=False, live_verified=False, snapshot_hash_verified=valid,
        snapshot={'origin': 'mail_store_readonly', 'live_verified': False, 'attachments_analyzed': False})
    return result
