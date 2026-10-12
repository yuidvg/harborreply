import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive
import direct_store

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / '.build/debug/HarborMailReader'

@unittest.skipUnless(sys.platform == 'darwin' and HELPER.exists(), 'build HarborMailReader on macOS first')
class DirectStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.mail = self.base / 'Mail'
        self.mail.mkdir()
        self.archive = Archive(str(self.base / 'index.sqlite'))
    def tearDown(self):
        direct_store.cleanup()
        self.archive.db.close()
        self.temp.cleanup()
    def write(self, name, body='Sample text'):
        raw = ('From: person@example.invalid\nTo: other@example.invalid\nSubject: Harbor test\nMessage-ID: <'+name+'@example.invalid>\n\n'+body).encode()
        (self.mail / (name+'.emlx')).write_bytes(str(len(raw)).encode()+b'\n'+raw+b'\n<plist/>')
    def scan(self):
        state = direct_store.start(self.archive, str(HELPER), str(self.mail))
        while state['status'] == 'running': state = direct_store.step(self.archive, state['scan_id'])
        return state
    def test_initial_unchanged_changed_deleted_and_source_preserved(self):
        for n in range(20): self.write(str(n))
        before = {p.name:p.read_bytes() for p in self.mail.iterdir()}
        first = self.scan()
        self.assertEqual(first['metrics']['body_reads'], 20)
        self.assertEqual(first['counts']['captured'], 20)
        second = self.scan()
        self.assertEqual(second['metrics']['body_reads'], 0)
        self.assertEqual(second['metrics']['unchanged'], 20)
        self.assertEqual(before, {p.name:p.read_bytes() for p in self.mail.iterdir()})
        self.write('1', 'A modified message'); (self.mail/'2.emlx').unlink()
        third = self.scan()
        self.assertEqual(third['metrics']['body_reads'], 1)
        self.assertEqual(third['metrics']['unchanged'], 18)
        self.assertEqual(self.archive.db.execute('SELECT count(*) FROM direct_files WHERE active=1').fetchone()[0], 19)
        self.assertEqual(self.archive.db.execute('SELECT count(*) FROM search').fetchone()[0], 19)
        self.scan()
        self.assertEqual(self.archive.db.execute('SELECT count(*) FROM search').fetchone()[0], 19)
    def test_partial_failure_does_not_remove_unseen(self):
        self.write('1'); self.scan()
        state = direct_store.start(self.archive, str(HELPER), str(self.mail/'missing'))
        with self.assertRaises(Exception): direct_store.step(self.archive, state['scan_id'])
        self.assertEqual(self.archive.db.execute('SELECT count(*) FROM direct_files WHERE active=1').fetchone()[0], 1)
    def test_sandbox_write_delete_and_rename_denied(self):
        self.write('1')
        source = self.mail/'1.emlx'; original = source.read_bytes()
        # Only test fixtures are mutation targets. This never probes real Mail.
        for code in ['open(p,"wb").write(b"changed")', 'os.unlink(p)', 'os.rename(p,p+".moved")', 'open(p+".new","wb")']:
            script = 'import os,errno; p='+repr(str(source))+'; assert len(open(p,"rb").read()) > 0\ntry:\n '+code+'\nexcept OSError as e:\n assert e.errno in (errno.EPERM,errno.EACCES)\n print("denied")\nelse:\n raise AssertionError("write allowed")'
            result = subprocess.run(['/usr/bin/sandbox-exec','-p',direct_store.PROFILE,sys.executable,'-B','-c',script], capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), b'denied')
            self.assertEqual(source.read_bytes(), original)
    def test_type_capability_has_no_write_or_descriptor_escape(self):
        modules = ROOT/'.build/debug'
        if (modules/'Modules').exists(): modules = modules/'Modules'
        for expression in ('try entry.write(Data())', 'entry.descriptor', 'entry.key = "other"'):
            source = self.base/'Rejected.swift'
            source.write_text('import Foundation\nimport MailStoreReadOnly\nfunc client(_ entry: MailEntry) throws { '+expression+' }')
            result = subprocess.run(['swiftc','-typecheck','-I',str(modules),str(source)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b'no such module', result.stderr)
    def test_scaling_operation_counts(self):
        measurements = []
        for size in (32,128,512):
            for n in range(size): self.write(str(n))
            self.scan(); result = self.scan()
            self.assertEqual(result['metrics']['visited'], size)
            self.assertEqual(result['metrics']['body_reads'], 0)
            self.assertEqual(result['metrics']['unchanged'], size)
            measurements.append(dict(files=size, **result['metrics']))
        print('SYNTHETIC_DIRECT_INDEX_SCALING', json.dumps(measurements))
