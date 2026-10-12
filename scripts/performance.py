#!/usr/bin/env python3
"""Reproducible fictional-only scaling measurements, with deterministic work gates.

Real streaming MIME import constructs every corpus. No sparse-file throughput
claim, real mail, API or model is used. Temporary source + index + WAL stay under
384 MiB and are removed. SQLite VM steps do not count all work inside FTS native
posting-list traversal: wall timings, plans and that limitation are also reported.
"""
import argparse
import json
import math
from pathlib import Path
import platform
import resource
import sqlite3
import statistics
import sys
import tempfile
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
import archive as archive_module
from archive import Archive, CASE_MESSAGES_SQL, CASE_EVENTS_SQL, SEARCH_SQL
from context import build_context

DISK_CAP = 384 * 1024 * 1024
CURRENT = {'id': 'fixture-current', 'messageID': 'current@fixture.invalid',
           'body': 'Fictional only. Please report the current status.', 'subject': 'FICTIONAL', 'fictional': True}

def rss_bytes():
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return value if sys.platform == 'darwin' else value * 1024

def bytes_on_disk(root):
    return sum(p.stat().st_size for p in root.rglob('*') if p.is_file())

def write_corpus(path, count):
    with path.open('wb') as f:
        for i in range(count):
            f.write(('From captain@fixture.invalid Thu Oct  8 09:00:00 2026\n'
                     'From: captain@fixture.invalid\nTo: operator@fixture.invalid\n'
                     f'Message-ID: <scale{i}@fixture.invalid>\n'
                     'Date: Thu, 08 Oct 2026 09:00:00 +0900\nSubject: FICTIONAL SCALE\n'
                     'Content-Type: text/plain; charset=utf-8\n\n'
                     f'FICTIONAL NOT FOR BUSINESS USE commonword {"leftword" if i % 2 else "rightword"} '
                     f'uniqueword{i} report requested.\n\n').encode())

def measure(archive, operation, samples):
    # Time ordinary execution without the observer; step measurement is separate.
    walls = []
    for _ in range(samples):
        started = time.perf_counter(); result = operation(); walls.append(time.perf_counter() - started)
    steps = [0]
    def observe(amount): steps[0] += amount
    archive._sql_step_observer = observe
    try: operation()
    finally: archive._sql_step_observer = None
    return {'samples': samples, 'wall_median_seconds': statistics.median(walls),
            'wall_p95_seconds': sorted(walls)[max(0, math.ceil(samples * .95) - 1)],
            'sqlite_vm_steps': steps[0], 'step_granularity': 100,
            'result_count': len(result) if isinstance(result, list) else result.get('count')}

def plan(archive, sql, args):
    return [r[3] for r in archive.db.execute('EXPLAIN QUERY PLAN ' + sql, args)]

def corpus_measurement(count, samples=7):
    with tempfile.TemporaryDirectory(prefix='harbor-scaling-') as temporary:
        root = Path(temporary).resolve(); source = root / 'fictional.mbox'
        write_corpus(source, count)
        a = Archive(root / 'state' / 'archive.sqlite')
        try:
            sid = a.add_source(str(source), 'received', 'fixture', False)
            started = time.perf_counter()
            while True:
                state = a.ingest_batch(sid, 200)
                if bytes_on_disk(root) > DISK_CAP: raise RuntimeError('DISK_CAP_EXCEEDED')
                if state['done']: break
            ingest_seconds = time.perf_counter() - started
            cid = a.case_create('Fictional fixed-size case')
            mids = [r[0] for r in a.db.execute('SELECT id FROM messages ORDER BY rowid DESC LIMIT 20')]
            for mid in mids: a.membership(cid, mid, True)
            queries = {'common': 'commonword', 'rare': 'uniqueword' + str(count - 1), 'disjoint': 'leftword rightword'}
            measurements = {key: measure(a, lambda q=q: a.search(q), samples) for key, q in queries.items()}
            measurements['coverage'] = measure(a, a.coverage, samples)
            measurements['case_ids'] = measure(a, lambda: a.case_message_ids(cid), samples)
            measurements['context'] = measure(a, lambda: build_context(a, CURRENT, case_id=cid, user_intent='Request the report.'), samples)
            # Baselines intentionally retain the old linear work for sensitivity.
            measurements['linear_coverage_control'] = measure(a, lambda: list(a.db.execute('SELECT min(date),max(date),count(*) FROM messages')), 1)
            measurements['linear_rank_control'] = measure(a, lambda: list(a.db.execute('SELECT id FROM search WHERE search MATCH ? ORDER BY rank LIMIT 40', ('commonword',))), 1)
            reads = []; actual_read = archive_module.read_source_range
            def read_range(path, start, end, fp):
                reads.append(end - start); return actual_read(path, start, end, fp)
            with patch.object(archive_module, 'read_source_range', side_effect=read_range):
                context = build_context(a, CURRENT, case_id=cid, user_intent='Request the report.')
            # Reply context must not run full source diagnostics even for many
            # registered sources. A sentinel catches that regression directly.
            with patch.object(a, 'status', side_effect=AssertionError('REPLY_ENUMERATED_ALL_SOURCES')):
                build_context(a, CURRENT, case_id=cid, user_intent='Request the report.')
            plans = {'search': plan(a, SEARCH_SQL, ('commonword', 40)),
                     'case_ids': plan(a, CASE_MESSAGES_SQL, (cid, 101)),
                     'case_events': plan(a, CASE_EVENTS_SQL, (cid, 101)),
                     'coverage_start': plan(a, 'SELECT date FROM messages WHERE date IS NOT NULL ORDER BY date LIMIT 1', ()),
                     'coverage_end': plan(a, 'SELECT date FROM messages WHERE date IS NOT NULL ORDER BY date DESC LIMIT 1', ())}
            a.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            result = {'count': count, 'case_size': len(mids), 'source_bytes': source.stat().st_size,
                      'index_bytes': (root / 'state' / 'archive.sqlite').stat().st_size,
                      'temporary_disk_bytes': bytes_on_disk(root), 'ingest_seconds': ingest_seconds,
                      'ingest_messages_per_second': count / ingest_seconds, 'ingest_failures': state['failures'],
                      'process_peak_rss_bytes': rss_bytes(), 'measurements': measurements, 'query_plans': plans,
                      'verified_ranges': len(reads), 'verified_range_bytes': sum(reads),
                      'evidence_count': len(context['thread_evidence']), 'reply_enumerated_all_sources': False}
            if result['temporary_disk_bytes'] > DISK_CAP: raise RuntimeError('DISK_CAP_EXCEEDED')
            return result
        finally: a.db.close()

def evaluate_gates(rows):
    failures = []
    for row in rows:
        if row['ingest_failures'] or row['verified_ranges'] != row['case_size']:
            failures.append('fixture_or_provenance_failure')
        for operation in ('common', 'rare', 'disjoint', 'coverage', 'case_ids', 'context'):
            if row['measurements'][operation]['sqlite_vm_steps'] > 60_000:
                failures.append(operation + '_work_budget')
        for key, statements in row['query_plans'].items():
            if any('TEMP B-TREE' in s or 'SCAN messages' in s for s in statements): failures.append(key + '_full_scan_or_sort')
        if not any('memberships_recent' in s for s in row['query_plans']['case_ids']): failures.append('missing_case_index')
        if not any('VIRTUAL TABLE INDEX' in s for s in row['query_plans']['search']): failures.append('missing_fts_index')
    first, last = rows[0], rows[-1]
    growth = {}
    for operation in ('common', 'rare', 'disjoint', 'coverage', 'case_ids', 'context'):
        small = first['measurements'][operation]['sqlite_vm_steps']; large = last['measurements'][operation]['sqlite_vm_steps']
        ratio = (large + 500) / (small + 500)
        exponent = math.log(ratio) / math.log(last['count'] / first['count'])
        growth[operation] = {'step_ratio_with_500_step_floor': ratio, 'observed_work_exponent': exponent}
        if ratio > 3: failures.append(operation + '_linear_growth')
    for operation in ('linear_coverage_control', 'linear_rank_control'):
        small = max(1, first['measurements'][operation]['sqlite_vm_steps']); large = last['measurements'][operation]['sqlite_vm_steps']
        if large / small < 3: failures.append(operation + '_regression_detector_insensitive')
    if last['verified_range_bytes'] > first['verified_range_bytes'] * 1.3:
        failures.append('provenance_read_scaled_with_archive')
    return {'passed': not failures, 'failures': sorted(set(failures)), 'observed_growth': growth,
            'elapsed_times_are_gates': False, 'negative_linear_controls_detected': not any('insensitive' in s for s in failures)}

def run_suite(counts=(1000, 4000, 16000), samples=7):
    if len(counts) < 2 or any(n < 100 or n > 100_000 for n in counts) or sorted(set(counts)) != list(counts):
        raise ValueError('counts must be increasing distinct values in 100..100000')
    rows = [corpus_measurement(n, samples) for n in counts]
    return {'version': 'archive-scaling-1', 'synthetic_only': True, 'actual_300gb_verified': False,
            'python': platform.python_version(), 'sqlite': sqlite3.sqlite_version,
            'platform': platform.system(), 'architecture': platform.machine(), 'disk_cap_bytes': DISK_CAP,
            'datasets': rows, 'gates': evaluate_gates(rows),
            'complexity': {'ingest': 'O(total source bytes), bounded per-message/batch memory',
                           'coverage': 'O(log N) index endpoints + maintained O(1) totals',
                           'case': 'O(log N + bounded case size), excess evidence fails closed',
                           'fts': 'posting-list traversal + bounded result hydration; general AND queries are not guaranteed O(log N)',
                           'provenance': 'bounded selected-message range hashes + stat checks, no whole-source hash',
                           'style': 'precomputed on explicit selected-example changes; at most 3 source ranges reverified per reply'},
            'limitations': ['SQLite VM steps do not include every native FTS posting-list operation.',
                            'Small synthetic bodies do not prove 300GB or attachment-heavy real-mail performance.',
                            'RSS is process lifetime high-water mark; it is measured, not an exact per-dataset allocation.',
                            'Broad matching results prioritize later indexed matches, not global BM25 relevance or message date.']}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--quick', action='store_true', help='Use 1000,4000,16000 synthetic messages (the default).')
    parser.add_argument('--counts', help='Explicit increasing comma-separated counts, up to 100000.')
    parser.add_argument('--output', type=Path, help='Write the metadata-only JSON report here.')
    args = parser.parse_args()
    if args.quick and args.counts: parser.error('choose --quick or --counts')
    try: counts = tuple(int(n) for n in args.counts.split(',')) if args.counts else (1000, 4000, 16000)
    except ValueError: parser.error('counts must be integers')
    try: report = run_suite(counts)
    except ValueError as exc: parser.error(str(exc))
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(encoded)
    sys.stdout.write(encoded)
    return 0 if report['gates']['passed'] else 1

if __name__ == '__main__': raise SystemExit(main())
