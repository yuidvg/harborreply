#!/usr/bin/env python3
"""Explicit read-only real-source benchmark; stdout contains aggregates only."""
import argparse
import json
from pathlib import Path
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive, ArchiveError
import direct_store

parser = argparse.ArgumentParser()
parser.add_argument('--allow-real-mail', action='store_true', required=True)
parser.add_argument('--helper', default=str(Path(__file__).resolve().parents[1]/'.build/debug/HarborMailReader'))
parser.add_argument('--database', required=True, help='App-owned derived index, never inside Mail')
args = parser.parse_args()
root = (Path.home()/'Library/Mail').resolve()
database = Path(args.database).resolve()
if database == root or root in database.parents: raise SystemExit('INVALID_DATABASE_LOCATION')
helper = Path(args.helper).resolve()
archive = Archive(str(database))
results = []
try:
    for label in ('initial_or_incremental', 'repeat_incremental'):
        started = time.monotonic()
        result = direct_store.start(archive, str(helper), str(root))
        while result['status'] == 'running': result = direct_store.step(archive, result['scan_id'])
        results.append({'run': label, 'seconds': time.monotonic()-started,
                        'counts':result['counts'], 'metrics':result['metrics']})
    partial = any(run['counts']['unreadable'] + run['counts']['too_large'] for run in results)
    print(json.dumps({'outcome':'partial' if partial else 'passed', 'runs':results, 'sourceWrites':0}))
except ArchiveError as error:
    allowed = {'DIRECT_SOURCE_PERMISSION','DIRECT_SOURCE_UNAVAILABLE','DIRECT_READER_MISSING','DIRECT_READER_PROTOCOL'}
    code = error.args[0] if error.args and error.args[0] in allowed else 'DIRECT_BENCHMARK_FAILED'
    print(json.dumps({'outcome':'blocked', 'code':code, 'runs':results}))
    sys.exit(1)
finally:
    direct_store.cleanup(); archive.db.close()
