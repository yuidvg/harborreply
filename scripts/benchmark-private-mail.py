#!/usr/bin/env python3
"""External, opt-in benchmark of an isolated native-Mail verification database.

Input is one bounded JSON object on stdin: {db, current, samples (optional)}.
Only aggregate numbers and fixed labels leave the process. The database must
already exist inside a private harborreply-live-state-* temporary directory.
It is opened read-only without Archive's migration/initialization effects.
This helper is never bundled in HarborReply and never calls Mail or a model.
"""
import json
import math
import os
from pathlib import Path
import resource
import sqlite3
import stat
import statistics
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive, ArchiveError, SEARCH_SQL, query_tokens
from context import build_context
from mail_index import MailIndex
from main import failure_code

MAX_INPUT = 2 * 1024 * 1024
MAX_DATABASE = 512 * 1024 * 1024
CURRENT_FIELDS = frozenset(('id', 'account', 'messageID', 'subject', 'sender', 'body', 'headers', 'internal'))
REPORT_VERSION = 'isolated-live-context-1'


class BenchmarkInputError(Exception):
    pass


def empty_report():
    return {'version': REPORT_VERSION, 'succeeded': False, 'read_only': True,
            'mail_called': False, 'model_called': False, 'actual_300gb_verified': False,
            'operations': []}


def _reject_constant(_value):
    raise BenchmarkInputError()


def _object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise BenchmarkInputError()
        value[key] = item
    return value


def read_input(raw):
    if type(raw) is not bytes or len(raw) > MAX_INPUT:
        raise BenchmarkInputError()
    try:
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=_object, parse_constant=_reject_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise BenchmarkInputError() from None
    if type(value) is not dict or set(value) - {'db', 'current', 'samples'}:
        raise BenchmarkInputError()
    if type(value.get('db')) is not str or not value['db'] or '\0' in value['db']:
        raise BenchmarkInputError()
    samples = value.get('samples', 9)
    if type(samples) is not int or not 1 <= samples <= 31:
        raise BenchmarkInputError()
    current = value.get('current')
    if type(current) is not dict or set(current) - CURRENT_FIELDS:
        raise BenchmarkInputError()
    for key, item in current.items():
        if key == 'internal':
            if type(item) is not bool:
                raise BenchmarkInputError()
        elif type(item) is not str or len(item) > (250_000 if key == 'body' else 32_768 if key == 'headers' else 16_384):
            raise BenchmarkInputError()
    return value['db'], current, samples


def private_database(name):
    p = Path(name)
    if not p.is_absolute() or p.is_symlink() or not p.is_file():
        raise BenchmarkInputError()
    p = p.resolve()
    root = Path(tempfile.gettempdir()).resolve()
    parent = p.parent
    if not parent.name.startswith('harborreply-live-state-') or parent == root or root not in parent.parents:
        raise BenchmarkInputError()
    attributes = parent.stat()
    if not stat.S_ISDIR(attributes.st_mode) or attributes.st_uid != os.geteuid() or attributes.st_mode & 0o077:
        raise BenchmarkInputError()
    if p.stat().st_uid != os.geteuid() or p.stat().st_mode & 0o077 or p.stat().st_size > MAX_DATABASE:
        raise BenchmarkInputError()
    return p


def open_read_only(path):
    """Attach the shipping read methods without running constructor migrations."""
    archive = Archive.__new__(Archive)
    archive.snapshot_directory = path.parent / 'mail-snapshots'
    archive.db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=2)
    archive.db.row_factory = sqlite3.Row
    archive.db.execute('PRAGMA query_only=ON')
    archive._sql_step_observer = None
    archive._query_budget = None
    archive.db.set_progress_handler(archive._sql_progress, 100)
    index = MailIndex.__new__(MailIndex)
    index.archive = archive
    index.db = archive.db
    archive.mail_index = index
    # This test accepts only native SQLite snapshots. Imported file sources can
    # cause provenance checks outside this isolated directory, so refuse them.
    if archive.db.execute('SELECT count(*) FROM sources').fetchone()[0]:
        archive.db.close()
        raise BenchmarkInputError()
    return archive


def rss_bytes():
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak if sys.platform == 'darwin' else peak * 1024


def count(value):
    # Even a malformed private database must not turn a metric into text.
    if type(value) is not int or value < 0:
        raise BenchmarkInputError()
    return value


def result_counts(operation, result):
    if operation in ('related', 'search_ids'):
        return {'result_count': len(result)}
    if operation == 'prepare':
        return {'result_count': len(result['candidate_messages']),
                'candidate_count': len(result['context']['candidate_ids']),
                'evidence_count': len(result['context']['thread_evidence']),
                'style_example_count': len(result['context']['style_examples']),
                'unresolved_count': len(result['context']['unresolved_items'])}
    return {'result_count': count(result['style_summary']['example_count']),
            'description_present': bool(result['style_summary'].get('description')),
            'coverage_message_count': count(result['coverage']['count'])}


def measure(archive, operation, function, samples):
    record = {'operation': operation, 'samples': samples, 'succeeded': False}
    walls = []
    try:
        for _ in range(samples):
            begin = time.perf_counter_ns()
            result = function()
            walls.append(time.perf_counter_ns() - begin)
        steps = [0]
        statements = [0]
        metadata_lookups = [0]
        def trace(sql):
            statements[0] += 1
            if 'FROM mail_index_catalog WHERE locator_id=' in sql:
                metadata_lookups[0] += 1
        archive._sql_step_observer = lambda amount: steps.__setitem__(0, steps[0] + amount)
        archive.db.set_trace_callback(trace)
        try:
            measured = function()
        finally:
            archive._sql_step_observer = None
            archive.db.set_trace_callback(None)
        record.update(result_counts(operation, measured))
        ordered = sorted(walls)
        record.update(succeeded=True, first_milliseconds=walls[0] / 1_000_000,
                      p50_milliseconds=statistics.median(walls) / 1_000_000,
                      p95_milliseconds=ordered[math.ceil(samples * .95) - 1] / 1_000_000,
                      minimum_milliseconds=ordered[0] / 1_000_000,
                      maximum_milliseconds=ordered[-1] / 1_000_000,
                      sqlite_vm_steps=steps[0], sqlite_vm_granularity=100,
                      sql_statement_count=statements[0], metadata_point_lookups=metadata_lookups[0])
    except Exception as error:
        record.update(failure=failure_code(error), completed_samples=len(walls))
    return record


def plan_categories(archive):
    # EXPLAIN uses static statements. Neither SQL nor its bound arguments are
    # retained or printed; only recognized plan properties are returned.
    search = [row[3] for row in archive.db.execute('EXPLAIN QUERY PLAN ' + SEARCH_SQL, ('', 60))]
    metadata = [row[3] for row in archive.db.execute(
        'EXPLAIN QUERY PLAN SELECT locator_id,current_message,message_id,subject,sender,last_seen_epoch FROM mail_index_catalog WHERE locator_id=?', ('',))]
    endpoints = [row[3] for row in archive.db.execute(
        'EXPLAIN QUERY PLAN SELECT date FROM messages WHERE date IS NOT NULL ORDER BY date LIMIT 1')]
    return {'fts_virtual_index': any('VIRTUAL TABLE INDEX' in item for item in search),
            'metadata_point_index': any('SEARCH mail_index_catalog' in item for item in metadata),
            'coverage_date_index': any('by_date' in item for item in endpoints),
            'search_uses_temporary_sort': any('TEMP B-TREE' in item for item in search),
            'coverage_scans_messages': any('SCAN messages' in item for item in endpoints)}


def run(raw):
    report = empty_report()
    archive = None
    try:
        db, current, samples = read_input(raw)
        path = private_database(db)
        began = time.perf_counter_ns()
        archive = open_read_only(path)
        report['database_open_milliseconds'] = (time.perf_counter_ns() - began) / 1_000_000
        report['index_counts'] = {key: count(value) for key, value in archive.mail_index.status()['counts'].items()}
        report['database_bytes'] = path.stat().st_size
        report['process_peak_rss_bytes_before'] = rss_bytes()
        report['query_plans'] = plan_categories(archive)
        def prepare():
            context = build_context(archive, current)
            previews = archive.candidate_previews(context['candidate_ids'], context['candidate_reasons'])
            if archive.revision() != context['archive_revision']:
                raise ArchiveError('ARCHIVE_CHANGED_DURING_RETRIEVAL')
            return {'context': context, 'candidate_messages': previews}
        operations = [('related', lambda: archive.related_candidates(current)),
                      ('prepare', prepare),
                      ('overview', lambda: {'coverage': archive.coverage(), 'style_summary': archive.style_summary(verify=True)})]
        terms = query_tokens(current.get('subject', ''))
        if not terms:
            terms = query_tokens(current.get('body', ''))
        if terms:
            query = terms[0]
            operations.append(('search_ids', lambda: archive.search_ids(query)))
        else:
            report['search_query_available'] = False
        report['operations'] = [measure(archive, name, function, samples) for name, function in operations]
        report['succeeded'] = all(row['succeeded'] for row in report['operations'])
        report['process_peak_rss_bytes_after'] = rss_bytes()
        report['python_version'] = '.'.join(str(number) for number in sys.version_info[:3])
        report['sqlite_version'] = sqlite3.sqlite_version
        report['fts_internal_work_in_vm_steps'] = False
        report['rss_is_process_lifetime_high_water_mark'] = True
        report['worker_launch_and_ipc_measured'] = False
    except BenchmarkInputError:
        report['failure'] = 'PRIVATE_BENCHMARK_INPUT_INVALID'
    except Exception as error:
        report['failure'] = failure_code(error)
    finally:
        if archive is not None:
            archive.db.close()
    return report


def main():
    if sys.argv[1:] != ['--allow-real-mail']:
        report = empty_report()
        report['failure'] = 'PRIVATE_BENCHMARK_CONSENT_REQUIRED'
        json.dump(report, sys.stdout, sort_keys=True)
        sys.stdout.write('\n')
        return 64
    report = run(sys.stdin.buffer.read(MAX_INPUT + 1))
    json.dump(report, sys.stdout, sort_keys=True)
    sys.stdout.write('\n')
    return 0 if report['succeeded'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
