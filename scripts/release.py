#!/usr/bin/env python3
"""Signed, notarized releases. Only allowlisted artifacts leave this checkout."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = ROOT/'.build/artifacts/sparkle/Sparkle/bin'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)


def run(*args, capture=False, input=None, env=None):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True,
                            text=True, input=input, stdout=subprocess.PIPE if capture else None, env=env)
    return result.stdout.strip() if capture else None


def api(repo, endpoint, method='GET', body=None):
    args = ['gh', 'api', '--hostname', 'github.com', f'repos/{repo}/{endpoint}'.rstrip('/'), '--method', method]
    if body is not None: args += ['--input', '-']
    return json.loads(run(*args, capture=True, input=json.dumps(body) if body is not None else None))


def validate_config(config, info):
    if not isinstance(config.get('repository'), str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', config['repository']):
        raise ValueError('release.json: repository にリリース先の公開 owner/repo を設定してください')
    identity = config.get('signing_identity')
    if not isinstance(identity, str) or not identity.startswith('Developer ID Application: '):
        raise ValueError('release.json: signing_identity に Developer ID Application 証明書を設定してください')
    try: key = base64.b64decode(config['sparkle_public_key'], validate=True)
    except (ValueError, TypeError, KeyError): key = b''
    if len(key) != 32: raise ValueError('release.json: sparkle_public_key は generate_keys の公開鍵が必要です')
    for field in ('notary_profile', 'sparkle_key_account'):
        if not isinstance(config.get(field), str) or not config[field].strip(): raise ValueError(f'{field} required')
    build = int(info['CFBundleVersion'])
    if not re.fullmatch(r'\d+\.\d+\.\d+', info['CFBundleShortVersionString']): raise ValueError('Use a numeric x.y.z version')
    if config.get('minimum_build') is not None and (type(config['minimum_build']) is not int or not 1 <= config['minimum_build'] <= build):
        raise ValueError('minimum_build must be between 1 and CFBundleVersion')
    if type(config.get('mandatory_after_hours')) is not int or not 0 <= config['mandatory_after_hours'] <= 720:
        raise ValueError('mandatory_after_hours must be 0..720')
    if type(config.get('policy_valid_days')) is not int or not 1 <= config['policy_valid_days'] <= 365:
        raise ValueError('policy_valid_days must be 1..365')
    if config['mandatory_after_hours'] >= config['policy_valid_days'] * 24:
        raise ValueError('Policy must remain valid after the mandatory deadline')


def config_digest(config): return hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def appcast(info, archive_url, size, signature):
    root = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'HarborReply'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'HarborReply ' + info['CFBundleShortVersionString']
    for key, value in [('version', info['CFBundleVersion']), ('shortVersionString', info['CFBundleShortVersionString']),
                       ('minimumSystemVersion', info['LSMinimumSystemVersion'])]:
        ET.SubElement(item, f'{{{NS}}}{key}').text = value
    ET.SubElement(item, f'{{{NS}}}hardwareRequirements').text = 'arm64'
    ET.SubElement(item, 'enclosure', {'url': archive_url, 'length': str(size), 'type': 'application/octet-stream',
                                    f'{{{NS}}}edSignature': signature})
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def signing(config, file):
    return run(SPARKLE/'sign_update', '--account', config['sparkle_key_account'], '-p', file, capture=True)


def verify_signature(config, file, signature):
    # Use the configured public key, not the signing tool's currently selected key.
    run('/usr/bin/swift', ROOT/'scripts/verify-update-signature.swift', config['sparkle_public_key'], file, signature)


def relocation_check(app):
    """Load the real relocated binary, but reject options before any owner state/Mail initialization."""
    import shutil
    with tempfile.TemporaryDirectory(prefix='HarborReply release check ') as tmp:
        relocated = Path(tmp)/'HarborReply.app'
        shutil.copytree(app, relocated, symlinks=True)
        result = subprocess.run([str(relocated/'Contents/MacOS/HarborReply'), '--unsupported-release-check'],
                                cwd=tmp, env={'PATH': '/usr/bin:/bin'}, capture_output=True, timeout=20)
        if result.returncode != 64 or '未対応の起動オプション'.encode() not in result.stderr:
            raise ValueError('Relocated application failed its loader/early-exit check')
        runtime = relocated/'Contents/Resources/python-arm64/bin/python3'
        subprocess.run([str(runtime), '-s', '-B', '-c',
                        "import sqlite3; sqlite3.connect(':memory:').execute('CREATE VIRTUAL TABLE x USING fts5(body)')"],
                       cwd=tmp, env={'PATH': '/usr/bin:/bin'}, check=True, timeout=20)


def assert_source_unchanged(commit):
    if run('git', 'status', '--porcelain', capture=True) or run('git', 'rev-parse', 'HEAD', capture=True) != commit:
        raise ValueError('Source changed during release preparation; publication stopped')


def prepare(config, info, stage, commit):
    env = dict(os.environ, HARBOR_SIGN_IDENTITY=config['signing_identity'])
    run('/bin/zsh', 'scripts/test.sh', env=env)
    run('/bin/zsh', 'scripts/build-app.sh', env=env)
    run(sys.executable, 'scripts/package-app.py', '--skip-build', env=env)
    version = info['CFBundleShortVersionString']
    app = ROOT/f'dist/HarborReply-{version}/HarborReply.app'
    plist = app/'Contents/Info.plist'
    settings = plistlib.loads(plist.read_bytes())
    base = f"https://raw.githubusercontent.com/{config['repository']}/updates"
    settings.update(SUFeedURL=base+'/appcast.xml', SUPublicEDKey=config['sparkle_public_key'],
                    HarborUpdatePolicyURL=base+'/policy.json', SUEnableAutomaticChecks=True,
                    SUAutomaticallyUpdate=True, SUAllowsAutomaticUpdates=True, SUEnableSystemProfiling=False,
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                    SUSignedFeedFailureExpirationInterval=0)
    plist.write_bytes(plistlib.dumps(settings))
    run('/usr/bin/codesign', '--force', '--sign', config['signing_identity'], '--timestamp', '--options', 'runtime',
        '--entitlements', ROOT/'scripts/HarborReply.entitlements', app)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    relocation_check(app)
    stage.mkdir(parents=True)
    archive = stage/f'HarborReply-{version}-apple-silicon.zip'
    run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
    assert_source_unchanged(commit)
    run('/usr/bin/xcrun', 'notarytool', 'submit', archive, '--keychain-profile', config['notary_profile'], '--wait')
    run('/usr/bin/xcrun', 'stapler', 'staple', app)
    run('/usr/bin/xcrun', 'stapler', 'validate', app)
    run('/usr/sbin/spctl', '--assess', '--type', 'execute', app)
    archive.unlink()
    run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
    signature = signing(config, archive)
    verify_signature(config, archive, signature)
    feed = stage/'appcast.xml'
    url = f"https://github.com/{config['repository']}/releases/download/v{version}/{archive.name}"
    feed.write_bytes(appcast(info, url, archive.stat().st_size, signature))
    signing(config, feed)  # Sparkle signs XML in place.
    run(SPARKLE/'sign_update', '--account', config['sparkle_key_account'], '--verify', feed)
    now = datetime.now(timezone.utc).replace(microsecond=0)
    iso = lambda value: value.isoformat().replace('+00:00', 'Z')
    payload = {'schema': 1, 'sequence': int(info['CFBundleVersion']), 'minimumBuild': config['minimum_build'] or int(info['CFBundleVersion']),
               'issuedAt': iso(now), 'deadline': iso(now+timedelta(hours=config['mandatory_after_hours'])),
               'expiresAt': iso(now+timedelta(days=config['policy_valid_days']))}
    policy = stage/'policy-payload.json'
    policy.write_text(json.dumps(payload, sort_keys=True, separators=(',', ':')))
    signature = signing(config, policy)
    verify_signature(config, policy, signature)
    (stage/'policy.json').write_text(json.dumps({'payload': base64.b64encode(policy.read_bytes()).decode(), 'signature': signature}))
    policy.unlink()
    (stage/'SHA256SUMS').write_text(f'{sha(archive)}  {archive.name}\n')
    manifest = {'source_commit': commit, 'version': version, 'build': int(info['CFBundleVersion']),
                'config_sha256': config_digest(config), 'files': {p.name: sha(p) for p in stage.iterdir() if p.is_file()}}
    (stage/'release-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    return manifest


def validate_stage(stage, config, info, commit):
    manifest = json.loads((stage/'release-manifest.json').read_text())
    archive_name = f"HarborReply-{info['CFBundleShortVersionString']}-apple-silicon.zip"
    expected = {archive_name, 'appcast.xml', 'policy.json', 'SHA256SUMS'}
    if manifest['config_sha256'] != config_digest(config) or manifest['source_commit'] != commit or manifest['build'] != int(info['CFBundleVersion']):
        raise ValueError('Prepared release does not match current source/configuration')
    if set(manifest['files']) != expected or {p.name for p in stage.iterdir()} != expected | {'release-manifest.json'}:
        raise ValueError('Unexpected release files')
    if any(sha(stage/name) != digest for name, digest in manifest['files'].items()):
        raise ValueError('Prepared release was modified; do not overwrite a published version')
    return manifest


def publish(config, info, stage, manifest):
    envelope = json.loads((stage/'policy.json').read_text())
    policy = json.loads(base64.b64decode(envelope['payload']))
    if datetime.fromisoformat(policy['expiresAt'].replace('Z', '+00:00')) <= datetime.now(timezone.utc):
        raise ValueError('Prepared update policy has expired; release a new version')
    repo = config['repository']; version = info['CFBundleShortVersionString']; tag = 'v'+version
    # Read all remote state before mutations. Non-404 API errors are fatal.
    def optional(endpoint):
        result = subprocess.run(['gh', 'api', '--hostname', 'github.com', f'repos/{repo}/{endpoint}'.rstrip('/')], capture_output=True, text=True)
        if result.returncode == 0: return json.loads(result.stdout)
        if '(HTTP 404)' in result.stderr: return None
        raise RuntimeError('GitHub read failed; publication stopped')
    ref = optional('git/ref/heads/updates')
    previous = ref['object']['sha'] if ref else None
    if previous:
        remote_file = api(repo, f'contents/release-manifest.json?ref={previous}')
        remote = json.loads(base64.b64decode(remote_file['content']))
        if remote['build'] > manifest['build']: raise ValueError('A newer release is already live')
        if remote['build'] == manifest['build']:
            if remote != manifest: raise ValueError('This build number is already in use')
            print('This exact release is already live.'); return
    release = optional('releases/tags/'+tag)
    if release:
        # Never overwrite release assets, even on a retry.
        with tempfile.TemporaryDirectory(prefix='harbor-release-check-') as tmp:
            for name in manifest['files'].keys() | {'release-manifest.json'}:
                matches = [a for a in release['assets'] if a['name'] == name]
                if not matches:
                    if not release['draft']: raise ValueError('Published release is incomplete; use a new version')
                    continue
                run('gh', 'release', 'download', tag, '--repo', repo, '--pattern', name, '--dir', tmp)
                if sha(Path(tmp)/name) != sha(stage/name): raise ValueError('Remote asset differs; use a new version')
    else:
        # GitHub needs an initialized distribution repo; create it separately with a README.
        notes = stage/'release-notes.txt'
        notes.write_text(f'HarborReply {version}\nBuild {manifest["build"]}\nSource commit: {manifest["source_commit"]}\n')
        try:
            run('gh', 'release', 'create', tag, '--repo', repo, '--draft', '--title', f'HarborReply {version}', '--notes-file', notes)
        finally: notes.unlink()
        release = api(repo, 'releases/tags/'+tag)
    existing = {a['name'] for a in release['assets']}
    for name in sorted(manifest['files'].keys() | {'release-manifest.json'}):
        if name not in existing: run('gh', 'release', 'upload', tag, stage/name, '--repo', repo)
    if release['draft']: run('gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest')
    # Verify the anonymous ZIP route before advertising an update.
    archive_name = next(name for name in manifest['files'] if name.endswith('.zip'))
    url = f'https://github.com/{repo}/releases/download/{tag}/{archive_name}'
    digest = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=60) as response:
        while chunk := response.read(1024*1024): digest.update(chunk)
    if digest.hexdigest() != manifest['files'][archive_name]: raise ValueError('Published archive checksum mismatch')
    # One Git commit atomically changes both public documents. No source checkout is pushed.
    tree = api(repo, 'git/trees', 'POST', {'tree': [
        {'path': name, 'mode': '100644', 'type': 'blob', 'content': (stage/name).read_text()}
        for name in ('appcast.xml', 'policy.json', 'release-manifest.json')]})
    commit = api(repo, 'git/commits', 'POST', {'message': f'HarborReply {version}', 'tree': tree['sha'],
                                            'parents': [previous] if previous else []})
    if previous:
        api(repo, 'git/refs/heads/updates', 'PATCH', {'sha': commit['sha'], 'force': False})
    else:
        api(repo, 'git/refs', 'POST', {'ref': 'refs/heads/updates', 'sha': commit['sha']})
    print(f'Published: https://github.com/{repo}/releases/tag/{tag}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Read-only prerequisite check')
    parser.add_argument('--prepare-only', action='store_true', help='Test, sign, notarize; do not publish to GitHub')
    parser.add_argument('--resume', action='store_true', help='Reuse a verified prepared release after publication failure')
    args = parser.parse_args()
    config = json.loads((ROOT/'release.json').read_text())
    info = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())
    validate_config(config, info)
    if run('git', 'status', '--porcelain', capture=True): raise ValueError('Commit reviewed source changes before deploying; never auto-add private files')
    commit = run('git', 'rev-parse', 'HEAD', capture=True)
    identities = run('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', capture=True)
    if config['signing_identity'] not in identities: raise ValueError('Developer ID signing identity is unavailable')
    repository = api(config['repository'], '')
    if repository.get('private'):
        raise ValueError('Use an initialized public repository for releases')
    api(config['repository'], 'git/ref/heads/' + repository['default_branch'])
    if not repository.get('permissions', {}).get('push'): raise ValueError('GitHub write access is required')
    run('/usr/bin/xcrun', 'notarytool', 'history', '--keychain-profile', config['notary_profile'], capture=True)
    if args.check:
        print('Source, Developer ID, GitHub and notarization preflight passed. Sparkle key is verified during preparation.'); return
    stage = ROOT/f'dist/releases/v{info["CFBundleShortVersionString"]}'
    if args.resume:
        manifest = validate_stage(stage, config, info, commit)
    else:
        if stage.exists(): raise ValueError('Release staging already exists. Use --resume for a completed preparation; otherwise inspect it before removal.')
        manifest = prepare(config, info, stage, commit)
    validate_stage(stage, config, info, commit)
    if args.prepare_only: print(f'Prepared, not published: {stage}'); return
    assert_source_unchanged(commit)
    publish(config, info, stage, manifest)


if __name__ == '__main__':
    try: main()
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Release stopped: {error}', file=sys.stderr); sys.exit(1)
