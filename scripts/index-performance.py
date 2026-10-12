#!/usr/bin/env python3
"""Synthetic native catalog scaling. Never calls Mail or reads a real archive."""
import argparse
import json
from pathlib import Path
import resource
import platform
import sqlite3
import statistics
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive


def run_suite(sizes=(1000, 4000, 16000), samples=5):
    results = []
    current = {'id':'selected', 'subject':'AWS Free Tier limit alert', 'sender':'alerts@provider.invalid', 'body':'Fictional notification.'}
    with tempfile.TemporaryDirectory(prefix='harbor-native-index-fictional-') as temporary:
        archive = Archive(Path(temporary).resolve()/'private/db.sqlite')
        try:
            state = archive.mail_index.start()
            archive.mail_index.discovery(state['scan_id'], state['epoch'], None, None,
                                          [{'accountID':'account@fixture.invalid','mailboxPath':['Archive'],'messageCount':max(sizes), 'role':'received','isLocal':False}], True)
            inserted = 0; target = None; total_input_bytes = 0; started = time.perf_counter()
            for size in sizes:
                while inserted < size:
                    next_box = archive.mail_index.next(state['scan_id'], state['epoch'])
                    end = min(inserted+128, size)
                    records = [{'id':str(number), 'accountID':'account@fixture.invalid','mailboxPath':['Archive'],
                                'messageID':str(number)+'@history.invalid', 'subject':'AWS Free Tier usage' if number == 0 else 'AWS billing overview' if number % 2 else 'Unrelated laundry notification',
                                'sender':'service@provider.invalid','messageSize':350,'direction':'received','dateSent':'2026-10-09T00:00:00Z',
                                'body':'Fictional plaintext snapshot. No raw MIME or attachments are copied. '+('x'*200), 'attachmentCount':0}
                               for number in range(inserted,end)]
                    total_input_bytes += len(json.dumps(records,ensure_ascii=False).encode())
                    response = archive.mail_index.page(state['scan_id'], state['epoch'], next_box['mailbox_id'], next_box['cursor'],
                                                        dict(next_box['cursor'], offset=end), records, False)
                    if target is None: target = response['message_ids'][0]
                    inserted = end
                steps = [0]; queries = []; elapsed = []; result = None
                archive._sql_step_observer = lambda amount: steps.__setitem__(0, steps[0]+amount)
                archive.db.set_trace_callback(queries.append)
                for _ in range(samples):
                    begin = time.perf_counter(); result = archive.related_candidates(current); elapsed.append(time.perf_counter()-begin)
                archive._sql_step_observer = None; archive.db.set_trace_callback(None)
                assert result[0]['id'] == target, 'Older relevant mail was starved by the common provider pool'
                unique_queries = list(dict.fromkeys(q for q in queries if 'FROM search WHERE' in q or 'FROM mail_index_catalog WHERE locator_id=' in q))
                plans = [' '.join(str(r[3]) for r in archive.db.execute('EXPLAIN QUERY PLAN '+query)) for query in unique_queries]
                db_bytes = sum(path.stat().st_size for path in (Path(temporary)/'private').iterdir() if path.is_file())
                actual = archive.db.execute('SELECT count(*),coalesce(sum(body_bytes),0),coalesce(sum(message_size),0) FROM mail_index_catalog').fetchone()
                version_rows = archive.db.execute('SELECT count(*) FROM mail_index_versions').fetchone()[0]
                checkpoint_rows = archive.db.execute('SELECT count(*) FROM mail_index_pages').fetchone()[0]
                results.append({'count':size,'input_bytes':total_input_bytes,'index_bytes':db_bytes,
                                'catalog_rows':actual[0],'captured_plaintext_bytes':actual[1],
                                'declared_native_message_size_bytes':actual[2], 'body_version_rows':version_rows,
                                'checkpoint_rows':checkpoint_rows,
                                'ingest_elapsed_seconds':time.perf_counter()-started,'peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                                'rank_wall_median_seconds':statistics.median(elapsed),'rank_wall_p95_seconds':max(elapsed),
                                'sqlite_vm_steps_per_query':steps[0]/samples,'query_plans':list(dict.fromkeys(plans)),
                                'rank_result_count':len(result),'plaintext_copies':size,'raw_mime_copies':0,
                                'ranked_metadata_pool_limit':180})
            next_box = archive.mail_index.next(state['scan_id'], state['epoch'])
            archive.mail_index.page(state['scan_id'], state['epoch'], next_box['mailbox_id'], next_box['cursor'], None, [], True)
            archive.mail_index.finish(state['scan_id'], state['epoch'])
        finally: archive.db.close()
    failures = []
    for result in results:
        if result['sqlite_vm_steps_per_query'] > 20000: failures.append('rank query exceeded bounded VM work')
        if any('TEMP B-TREE' in plan for plan in result['query_plans']): failures.append('global sort in bounded rank query')
        if result['index_bytes'] > 384*1024*1024: failures.append('synthetic benchmark exceeded disk cap')
    first, last = results[0]['sqlite_vm_steps_per_query'], results[-1]['sqlite_vm_steps_per_query']
    if last > max(500,first)*3: failures.append('rank metadata work grew too rapidly')
    return {'version':'native-index-scaling-1','python':platform.python_version(),'sqlite':sqlite3.sqlite_version,
            'platform':platform.system(),'architecture':platform.machine(),
            'synthetic_only':True,'actual_300gb_verified':False,'live_mail_verified':False,
            'datasets':results,'gates':{'passed':not failures,'failures':failures,'elapsed_times_are_gates':False},
            'complexity':{'scan':'O(total captured bytes + N indexed writes), bounded page memory',
                          'rank':'bounded FTS posting traversal + <=180 metadata point lookups; no general O(log N) guarantee',
                          'checkpoint':'atomic indexed scan/page/cursor records, no full catalog iteration',
                          'provenance':'selected immutable SQLite plaintext version hash; live Mail not verified'},
            'limitations':['Synthetic small text does not prove a 300GB, attachment-heavy corpus.',
                           'SQLite VM counters omit some internal FTS posting work.',
                           'RSS is process lifetime high-water mark, not per-query allocation.',
                           'FTS metadata candidates are bounded by recent index order within each lexical lane.']}


if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--quick',action='store_true'); parser.add_argument('--output',type=Path)
    args=parser.parse_args(); result=run_suite((1000,4000,16000) if args.quick else (1000,10000,100000))
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'counts':[row['count'] for row in result['datasets']],'gates':result['gates'],'actual_300gb_verified':False},indent=2))
    raise SystemExit(0 if result['gates']['passed'] else 1)
