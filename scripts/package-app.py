#!/usr/bin/env python3
"""Build a relocatable Apple Silicon .app / AirDrop zip. No user state is copied."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'
VERSION = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())['CFBundleShortVersionString']

def run(*args):
    subprocess.run(args, check=True, cwd=ROOT)

def macho(path):
    if path.is_symlink() or not path.is_file(): return False
    with path.open('rb') as f: return f.read(4) in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca')

def audit_app(app):
    """Reject stale builds or runtime mail fixtures before making a distribution."""
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != VERSION:
        raise RuntimeError('PACKAGE_BUILD_VERSION_MISMATCH_REBUILD_APP')
    binary = (app/'Contents/MacOS/HarborReply').read_bytes()
    if any(flag in binary for flag in (b'--demo', b'--self-test', b'--snapshot')):
        raise RuntimeError('PACKAGE_RETIRED_RUNTIME_MODE_REBUILD_APP')
    resources = app/'Contents/Resources'
    for resource in resources.rglob('*'):
        name = resource.name.lower()
        if (name.endswith(('.eml', '.mbox')) or name.startswith(('demo-', 'demo.', 'mock-'))
                or name in ('fixtures', 'scenarios', 'scenarios.json')):
            raise RuntimeError('PACKAGE_RUNTIME_MAIL_FIXTURE_REBUILD_APP')

def audit_release(release):
    """Only application/instructions may ship; acceptance fixtures stay in the repo."""
    allowed = {'HarborReply.app', 'はじめに.md', 'docs'}
    if {entry.name for entry in release.iterdir()} != allowed:
        raise RuntimeError('PACKAGE_UNEXPECTED_DISTRIBUTION_CONTENT')
    docs = release/'docs'
    if {entry.name for entry in docs.iterdir()} != {'MAIL_ACCEPTANCE.md'}:
        raise RuntimeError('PACKAGE_UNEXPECTED_DISTRIBUTION_DOCUMENT')
    for entry in release.rglob('*'):
        if entry.name.lower().endswith(('.eml', '.mbox')):
            raise RuntimeError('PACKAGE_DISTRIBUTION_MAIL_FIXTURE')
    audit_app(release/'HarborReply.app')

def package(skip_build=False):
    if sys.version_info < (3, 12): raise RuntimeError('PACKAGE_REQUIRES_PYTHON_3_12_OR_NEWER')
    DIST.mkdir(exist_ok=True)
    if not skip_build:
        run('scripts/build-app.sh')
    audit_app(ROOT/'build/HarborReply.app')
    signing = os.environ.get('HARBOR_SIGN_IDENTITY','-')
    release = DIST / f'HarborReply-{VERSION}'
    # Only replace a generated distribution directory, never Application Support or user apps.
    if release.exists(): shutil.rmtree(release)
    release.mkdir()
    app = release / 'HarborReply.app'
    shutil.copytree(ROOT/'build/HarborReply.app',app,symlinks=True)
    binary = app/'Contents/MacOS/HarborReply'
    if subprocess.check_output(['xcrun','lipo','-archs',str(binary)],text=True).strip() != 'arm64':
        raise RuntimeError('APPLE_SILICON_BUILD_REQUIRED')
    resources = app/'Contents/Resources'
    local_runtime = resources/'runtime.json'
    if local_runtime.exists(): local_runtime.unlink()
    lock = json.loads((ROOT/'scripts/runtime.lock.json').read_text())
    licenses=[]
    for spec in lock['runtimes']:
        archive = ROOT/'.runtime-cache'/spec['filename']
        archive.parent.mkdir(exist_ok=True)
        if not archive.exists(): urllib.request.urlretrieve(spec['url'], archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != spec['sha256']: raise RuntimeError('RUNTIME_CHECKSUM_MISMATCH')
        with tempfile.TemporaryDirectory(dir=ROOT/'.runtime-cache') as tmp:
            with tarfile.open(archive) as t: t.extractall(tmp, filter='data')
            target = resources/('python-'+spec['architecture'])
            shutil.copytree(Path(tmp)/'python',target,symlinks=True)
        # Bundled dependency audit: only SDK/system libs or relocatable relative references.
        for file in target.rglob('*'):
            if not macho(file): continue
            dependencies=subprocess.check_output(['xcrun','otool','-L',str(file)],text=True).splitlines()[1:]
            for line in dependencies:
                dependency=line.strip().split(' (',1)[0]
                if dependency.startswith('/') and not dependency.startswith(('/usr/lib/','/System/Library/')):
                    raise RuntimeError('NONPORTABLE_RUNTIME_DEPENDENCY: '+dependency)
            run('codesign','--force','--sign',signing,*(['--options','runtime','--timestamp'] if signing != '-' else []), str(file))
        licenses.extend(str(p.relative_to(resources)) for p in target.rglob('*') if p.is_file() and 'license' in p.name.lower())
    plist=app/'Contents/Info.plist'
    info=plistlib.loads(plist.read_bytes());info['CFBundleShortVersionString']=VERSION
    plist.write_bytes(plistlib.dumps(info))
    shutil.copy2(ROOT/'scripts/runtime.lock.json',resources/'runtime.lock.json')
    (resources/'THIRD_PARTY.txt').write_text('Python runtime: astral-sh/python-build-standalone '+lock['release']+'\nCPython '+lock['python']+'\nhttps://github.com/astral-sh/python-build-standalone\nOriginal distribution license notices remain in:\n'+'\n'.join(licenses)+'\n')
    run('codesign','--force','--sign',signing,*(['--options','runtime','--timestamp'] if signing != '-' else []),'--entitlements',str(ROOT/'scripts/HarborReply.entitlements'),str(app))
    run('codesign','--verify','--deep','--strict',str(app))
    shutil.copy2(ROOT/'docs/FRIEND_INSTALL.md',release/'はじめに.md')
    (release/'docs').mkdir()
    shutil.copy2(ROOT/'docs/MAIL_ACCEPTANCE.md',release/'docs/MAIL_ACCEPTANCE.md')
    # Acceptance fixtures live only in the development repository, never the distribution.
    # Transfer only the application and instructions, never DB/settings/keys or sample mail.
    audit_release(release)
    archive=DIST/f'HarborReply-{VERSION}-apple-silicon.zip'
    if archive.exists(): archive.unlink()
    run('/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(release),str(archive))
    checksum=hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(checksum+'  '+archive.name+'\n')
    print(json.dumps({'archive':str(archive),'bytes':archive.stat().st_size,'sha256':checksum,'app':str(app)},indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--skip-build',action='store_true');args=p.parse_args();package(args.skip_build)
