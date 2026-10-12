#!/usr/bin/python3
"""One local request via stdin, one JSON result via stdout. Never a shell payload."""
import errno
import json
from pathlib import Path
import sqlite3
import sys
from archive import Archive, ArchiveError, source_files, MAX_CANDIDATE_PREVIEWS, rank_related_rows
from context import build_context
from contract import SCHEMA, SYSTEM_PROMPT, validate


def _load_failure_codes():
    """The bundled literal list is authoritative; never approve error text by shape."""
    try:
        with Path(__file__).with_name('failure_codes.json').open('rb') as source:
            raw = source.read(64 * 1024 + 1)
        if len(raw) > 64 * 1024: return None
        value = json.loads(raw)
        codes = value['codes']
        if type(value['version']) is not int or value['version'] != 1 or type(codes) is not list:
            return None
        if not codes or any(type(code) is not str or not code or len(code) > 128 for code in codes):
            return None
        result = frozenset(codes)
        if len(result) != len(codes) or not {'LOCAL_OPERATION_FAILED', 'WORKER_RESOURCE_MISSING'} <= result:
            return None
        return result
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        return None


FAILURE_CODES = _load_failure_codes()


def failure_code(error):
    """Classify only typed failures/numeric codes, excluding messages and paths."""
    if FAILURE_CODES is None: return 'WORKER_RESOURCE_MISSING'
    code = 'LOCAL_OPERATION_FAILED'
    if isinstance(error, ArchiveError):
        # str(error) may contain mail, paths or a custom __str__; use one exact literal.
        if len(error.args) == 1 and type(error.args[0]) is str:
            code = error.args[0]
    elif isinstance(error, sqlite3.Error):
        number = getattr(error, 'sqlite_errorcode', None)
        primary = number & 255 if type(number) is int else None
        if primary in (getattr(sqlite3, 'SQLITE_CORRUPT', 11), getattr(sqlite3, 'SQLITE_NOTADB', 26)):
            code = 'SQLITE_DATABASE_CORRUPT'
        elif primary in (getattr(sqlite3, 'SQLITE_BUSY', 5), getattr(sqlite3, 'SQLITE_LOCKED', 6)):
            code = 'SQLITE_DATABASE_BUSY'
        elif primary in (getattr(sqlite3, 'SQLITE_PERM', 3), getattr(sqlite3, 'SQLITE_AUTH', 23), getattr(sqlite3, 'SQLITE_READONLY', 8)):
            code = 'SQLITE_DATABASE_PERMISSION'
        else:
            code = 'SQLITE_DATABASE_ERROR'
    elif isinstance(error, OSError):
        if isinstance(error, PermissionError) or error.errno in (errno.EACCES, errno.EPERM):
            code = 'OS_SOURCE_PERMISSION'
        else:
            code = 'OS_SOURCE_UNAVAILABLE'
    return code if code in FAILURE_CODES else 'LOCAL_OPERATION_FAILED'


def failure_response(error):
    return {'ok': False, 'error': failure_code(error)}


# Check structural omissions before opening the DB. Domain validation remains in
# the command implementation so its existing, specific ArchiveError codes survive.
REQUIRED_FIELDS = {
    'direct_start': ('helper', 'root'),
    'direct_step': ('scan_id',),
    'direct_pause': ('scan_id',),
    'index_discovery': ('scan_id', 'epoch', 'mailboxes', 'done'),
    'index_next': ('scan_id', 'epoch'),
    'index_rewind_mailbox': ('scan_id', 'epoch', 'mailbox_id', 'expected_checkpoint'),
    'index_page': ('scan_id', 'epoch', 'mailbox_id', 'records', 'done'),
    'index_finish': ('scan_id', 'epoch'),
    'rank_mail_headers': ('current', 'records'),
    'mail_snapshot': ('records',),
    'mail_body_cache_lookup': ('locators',),
    'mail_body_cache_store': ('records',),
    'register': ('path',),
    'register_style_source': ('path', 'author_confirmed'),
    'ingest': ('source_id',),
    'source_message_ids': ('source_id',),
    'search': ('query',),
    'message': ('id',),
    'case_create': ('label',),
    'membership': ('case_id', 'message_id', 'include'),
    'case_detail': ('case_id',),
    'event_add': ('event',),
    'policy_add': ('policy',),
    'style_add': ('message_id', 'author_confirmed'),
    'style_remove': ('message_id',),
    'style_replace': ('message_ids', 'author_confirmed'),
    'style_corpus_extract': ('account_id', 'own_addresses'),
    'style_capture_start': ('account_id', 'address', 'own_addresses'),
    'style_capture_page': ('capture_id', 'records', 'candidates_checked'),
    'style_capture_content_page': ('capture_id', 'records', 'candidates_checked'),
    'style_capture_finish': ('capture_id',),
    'style_capture_extract': ('capture_id',),
    'style_capture_read_budget': ('capture_id',),
    'style_capture_read_reserve': ('capture_id', 'attempt_id', 'reads'),
    'style_capture_read_charge': ('capture_id', 'attempt_id', 'captured_bytes'),
    'policy_remove': ('id',),
    'delete_source': ('source_id',),
    'context': ('input',),
    'prepare': ('input',),
    'validate': ('output', 'context'),
}
CONTEXT_FIELDS = frozenset(('current', 'case_id', 'user_intent', 'language', 'tone',
                            'style_profile', 'request_id', 'context_revision', 'related_selection'))


def validate_request(request):
    if type(request) is not dict:
        raise ArchiveError('IPC_REQUEST_INVALID')
    if any(type(request.get(key)) is not str or not request[key] or '\0' in request[key]
           for key in ('db', 'command')):
        raise ArchiveError('IPC_REQUEST_INVALID')
    if any(key not in request for key in REQUIRED_FIELDS.get(request['command'], ())):
        raise ArchiveError('IPC_REQUEST_INVALID')
    if request['command'] in ('context', 'prepare'):
        fields = request['input']
        if type(fields) is not dict or type(fields.get('current')) is not dict or set(fields) - CONTEXT_FIELDS:
            raise ArchiveError('IPC_REQUEST_INVALID')


def dispatch(a):
    validate_request(a)
    command = a['command']
    if command == 'contract': return {'schema': SCHEMA, 'instructions': SYSTEM_PROMPT}
    archive = Archive(a['db'])
    try:
        if command == 'style_text_publish': return archive.publish_text_style(a)
        if command == 'status': return archive.status()
        if command == 'index_status':
            from direct_store import state
            return state(archive.db) or archive.mail_index.status()
        if command in ('direct_start', 'direct_step', 'direct_pause'):
            import direct_store
            if command == 'direct_start': return direct_store.start(archive, a['helper'], a['root'])
            if command == 'direct_step': return direct_store.step(archive, a['scan_id'])
            return direct_store.pause(archive, a['scan_id'])
        if command == 'index_start': return archive.mail_index.start(a.get('restart', False))
        if command == 'index_discovery': return archive.mail_index.discovery(a['scan_id'], a['epoch'], a.get('expected_checkpoint'), a.get('checkpoint'), a['mailboxes'], a['done'], a.get('accounts', []))
        if command == 'index_rewind_mailbox': return archive.mail_index.rewind_mailbox(a['scan_id'], a['epoch'], a['mailbox_id'], a['expected_checkpoint'])
        if command == 'index_next': return archive.mail_index.next(a['scan_id'], a['epoch'])
        if command == 'index_page': return archive.mail_index.page(a['scan_id'], a['epoch'], a['mailbox_id'], a.get('expected_checkpoint'), a.get('checkpoint'), a['records'], a['done'])
        if command == 'index_finish': return archive.mail_index.finish(a['scan_id'], a['epoch'], a.get('expected_checkpoint'), a.get('status', 'complete'), a.get('warning', ''))
        if command == 'overview':
            summary = archive.style_summary(verify=True)
            return {'coverage': archive.coverage(), 'style_summary': summary}
        if command == 'rank_mail_headers':
            matches = rank_related_rows(a['current'], a['records'], MAX_CANDIDATE_PREVIEWS)
            return {'ids': [match['id'] for match in matches], 'matches': matches}
        if command == 'mail_snapshot': return archive.ingest_mail_snapshot(a['records'])
        if command in ('mail_body_cache_lookup', 'mail_body_cache_store'):
            from mail_body_cache import MailBodyCache
            cache = MailBodyCache(archive)
            return cache.lookup(a['locators']) if command == 'mail_body_cache_lookup' else cache.store(a['records'])
        if command == 'register': return {'source_ids': [archive.add_source(p, a.get('direction', 'unknown'), a.get('account', ''), a.get('internal', False)) for p in source_files(a['path'])]}
        if command == 'register_style_source': return {'source_ids': [archive.add_style_source(a['path'], a['author_confirmed'])]}
        if command == 'ingest': return archive.ingest_batch(a['source_id'], a.get('limit', 100))
        if command == 'source_message_ids': return {'message_ids': archive.source_message_ids(a['source_id'])}
        if command == 'search': return archive.search(a['query'])
        if command == 'message': return archive.message(a['id'])
        if command == 'case_create': return {'id': archive.case_create(a['label'], a.get('vessel', ''), a.get('voyage', ''), a.get('cargo', ''))}
        if command == 'cases': return [dict(r) for r in archive.db.execute('SELECT * FROM cases ORDER BY label')]
        if command == 'membership': archive.membership(a['case_id'], a['message_id'], a['include']); return {'ok': True}
        if command == 'case_detail':
            return {'messages': [archive.message(mid, False) for mid in archive.case_message_ids(a['case_id'])],
                    'events': archive.case_events(a['case_id'])}
        if command == 'event_add': return {'id': archive.event_add(a['event'])}
        if command == 'policy_add': return {'id': archive.policy_add(a['policy'])}
        if command == 'style_add': archive.style_add(a['message_id'], a['author_confirmed']); return {'ok': True}
        if command == 'style_remove':
            archive.style_remove(a['message_id']); return {'ok': True}
        if command == 'style_replace': return archive.style_replace(a['message_ids'], a['author_confirmed'])
        if command == 'style_summary': return archive.style_summary(verify=True)
        if command == 'style_extract': return archive.style_extract()
        if command == 'style_corpus_extract':
            import style_corpus
            return style_corpus.extract(archive, a['account_id'], a['own_addresses'], a.get('shared_addresses', []), a.get('author_confirmed', False), a.get('token_budget', 32768))
        if command in ('style_capture_read_budget', 'style_capture_read_reserve', 'style_capture_read_charge'):
            from style_capture_read_budget import StyleCaptureReadBudget
            budget = StyleCaptureReadBudget(archive)
            if command == 'style_capture_read_budget': return budget.status(a['capture_id'])
            if command == 'style_capture_read_reserve': return budget.reserve(a['capture_id'], a['attempt_id'], a['reads'])
            return budget.charge(a['capture_id'], a['attempt_id'], a['captured_bytes'])
        if command.startswith('style_capture_'):
            from style_capture import StyleCapture
            capture = StyleCapture(archive)
            if command == 'style_capture_start':
                return capture.start(a['account_id'], a['address'], a['own_addresses'], a.get('shared_addresses', []),
                                     a.get('author_confirmed', False), a.get('token_budget', 32768), a.get('restart', True))
            if command == 'style_capture_status': return capture.status(a.get('capture_id'))
            if command == 'style_capture_page':
                return capture.page(a['capture_id'], a.get('expected_checkpoint'), a.get('checkpoint'),
                                    a['records'], a['candidates_checked'], a.get('done', False))
            if command == 'style_capture_content_page':
                return capture.content_page(a['capture_id'], a.get('expected_checkpoint'), a.get('checkpoint'),
                                            a['records'], a['candidates_checked'], a.get('done', False))
            if command == 'style_capture_finish':
                return capture.finish(a['capture_id'], a.get('status', 'complete'), a.get('source_exhausted', False))
            if command == 'style_capture_extract': return capture.extract(a['capture_id'])
        if command == 'policy_remove':
            with archive.db:
                archive.db.execute('DELETE FROM policies WHERE id=?', (a['id'],)); archive.bump()
            return {'ok': True}
        if command == 'profile_data':
            return {'policies': archive.policies(), 'styles': [archive.message(r[0], False) for r in archive.db.execute('SELECT message_id FROM styles LIMIT 3')],
                    'style_summary': archive.style_summary(verify=True)}
        if command == 'delete_source': archive.delete_source(a['source_id']); return {'ok': True}
        if command == 'context': return build_context(archive, **a['input'])
        if command == 'prepare':
            context = build_context(archive, **a['input'])
            previews = archive.candidate_previews(context['candidate_ids'], context['candidate_reasons'])
            if archive.revision() != context['archive_revision']: raise ArchiveError('ARCHIVE_CHANGED_DURING_RETRIEVAL')
            return {'context': context, 'candidate_messages': previews,
                    'candidate_count': len(context['candidate_ids']), 'candidate_preview_limit': MAX_CANDIDATE_PREVIEWS}
        if command == 'validate':
            if archive.revision() != a['context']['archive_revision']: raise ArchiveError('ARCHIVE_REVISION_CHANGED')
            for e in a['context']['thread_evidence'][1:]:
                if archive.message(e['message_id'])['source_status'] != 'available': raise ArchiveError('EVIDENCE_SOURCE_CHANGED')
            try:
                for m in archive.selected_style_messages():
                    if m['source_status'] != 'available' or m['direction'] != 'sent':
                        raise ArchiveError('STYLE_SOURCE_CHANGED')
            except ArchiveError:
                raise ArchiveError('STYLE_SOURCE_CHANGED') from None
            return validate(a['output'], a['context'])
        raise ArchiveError('UNKNOWN_COMMAND')
    finally: archive.db.close()

def _invalid_json_constant(_value):
    raise ArchiveError('IPC_INVALID_JSON')


def _json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ArchiveError('IPC_INVALID_JSON')
        result[key] = value
    return result


def process_request(raw):
    """One bounded request, with only a fixed failure code crossing stdout."""
    try:
        if FAILURE_CODES is None: raise ArchiveError('WORKER_RESOURCE_MISSING')
        if type(raw) is not bytes: raise ArchiveError('IPC_REQUEST_INVALID')
        if len(raw) > 2 * 1024 * 1024: raise ArchiveError('IPC_INPUT_LIMIT')
        try:
            request = json.loads(raw.decode('utf-8'), parse_constant=_invalid_json_constant,
                                 object_pairs_hook=_json_object)
        except (ValueError, UnicodeError, RecursionError):
            raise ArchiveError('IPC_INVALID_JSON') from None
        return {'ok': True, 'result': dispatch(request)}
    except Exception as error:
        return failure_response(error)


def serve(source, destination):
    """Bounded independent requests; EOF ends the private child process.

    Keep imports alive, not request data or database connections. Each dispatch
    still closes its connection, so committed revisions remain authoritative.
    """
    while True:
        raw = source.readline(2 * 1024 * 1024 + 2)
        if not raw:
            return
        if len(raw) > 2 * 1024 * 1024 + 1 or not raw.endswith(b'\n'):
            destination.write(json.dumps({'ok': False, 'error': 'IPC_INPUT_LIMIT'}) + '\n')
            destination.flush()
            return
        destination.write(json.dumps(process_request(raw[:-1]), ensure_ascii=False) + '\n')
        destination.flush()
        del raw  # Do not retain the previous mail payload while idle.


if __name__ == '__main__':
    if sys.argv[1:] == ['--serve']:
        serve(sys.stdin.buffer, sys.stdout)
    else:
        try:
            result = process_request(sys.stdin.buffer.read(2 * 1024 * 1024 + 1))
            encoded = json.dumps(result, ensure_ascii=False)
        except Exception as error:
            encoded = json.dumps(failure_response(error))
        sys.stdout.write(encoded)
