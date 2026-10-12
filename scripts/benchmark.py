#!/usr/bin/env python3
"""Synthetic only. Temporary data is capped at 384 MiB and removed on exit."""
import argparse
from pathlib import Path
import json
import resource
import statistics
import sys
import tempfile
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive
from context import build_context
p = argparse.ArgumentParser(); p.add_argument('--count', type=int, default=1000); args = p.parse_args()
if not 1 <= args.count <= 100000: p.error('count must be 1..100000')
with tempfile.TemporaryDirectory(prefix='harbor-benchmark-') as temporary:
    root = Path(temporary).resolve(); source = root / 'fictional.mbox'
    with source.open('wb') as f:
        for i in range(args.count):
            f.write(('From captain@fixture.invalid Thu Oct  8 09:00:00 2026\n'
                     'From: captain@fixture.invalid\nTo: operator@fixture.invalid\n'
                     f'Message-ID: <bench{i}@fixture.invalid>\n'
                     'Date: Thu, 08 Oct 2026 09:00:00 +0900\nSubject: FICTIONAL HARBOR-LIGHT\n'
                     'Content-Type: text/plain; charset=utf-8\n\n'
                     f'架空・業務利用禁止 証明書 TML Voyage {i // 20} Lot {i} report requested.\n\n').encode())
    a = Archive(root/'state'/'archive.sqlite'); sid = a.add_source(str(source), 'received', 'fictional', False)
    start = time.perf_counter()
    while True:
        r = a.ingest_batch(sid, 200)
        size = sum(f.stat().st_size for f in root.rglob('*') if f.is_file())
        if size > 384 * 1024 * 1024: raise SystemExit('DISK_CAP_EXCEEDED')
        if r['done']: break
    elapsed = time.perf_counter()-start
    cid = a.case_create('fictional benchmark', 'HARBOR-LIGHT', 'A', 'A')
    for row in a.db.execute('SELECT id FROM messages LIMIT 20').fetchall(): a.membership(cid, row[0], True)
    samples=[]
    for i in range(30):
        start=time.perf_counter()
        result=build_context(a, {'id':'current','messageID':'new@fixture.invalid','body':'Please report current status.','subject':'Fictional','fictional':True},case_id=cid,user_intent='確認結果を報告させて')
        samples.append(time.perf_counter()-start)
    a.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    print(json.dumps({'synthetic_only':True,'count':args.count,'case_size':20,'source_bytes':source.stat().st_size,
                      'import_seconds':elapsed,'messages_per_second':args.count/elapsed,'bytes_per_second':source.stat().st_size/elapsed,
                      'peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'index_bytes':(root/'state'/'archive.sqlite').stat().st_size,
                      'context_samples':len(samples),'context_p95_seconds':sorted(samples)[int(len(samples)*.95)-1],
                      'failures':r['failures'],'python':sys.version.split()[0]},indent=2))
    a.db.close()
