"""Release boundaries use synthetic public metadata; no network or credentials."""
import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('release_workflow', Path(__file__).resolve().parents[1]/'scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.info = {'CFBundleVersion': '28', 'CFBundleShortVersionString': '0.1.27', 'LSMinimumSystemVersion': '14.0'}
        self.config = {'repository': 'fictional/distribution', 'signing_identity': 'Developer ID Application: Fictional',
                       'notary_profile': 'fictional', 'sparkle_key_account': 'fictional',
                       'sparkle_public_key': base64.b64encode(b'x'*32).decode(),
                       'minimum_build': 28, 'mandatory_after_hours': 72, 'policy_valid_days': 90}

    def test_missing_or_unsafe_prerequisites_are_rejected(self):
        release.validate_config(self.config, self.info)
        for field, value in [('repository', None), ('repository', '../private'), ('signing_identity', '-'),
                             ('sparkle_public_key', 'bad'), ('minimum_build', 29), ('minimum_build', True),
                             ('mandatory_after_hours', -1), ('policy_valid_days', 0)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.validate_config(dict(self.config, **{field: value}), self.info)

    def test_feed_matches_build_url_signature_and_hardware(self):
        xml = release.appcast(self.info, 'https://updates.invalid/app.zip?a=1&b=2', 42, 'signed')
        root = ET.fromstring(xml); item = root.find('channel/item')
        self.assertEqual(item.find('{'+release.NS+'}version').text, '28')
        self.assertEqual(item.find('{'+release.NS+'}hardwareRequirements').text, 'arm64')
        self.assertEqual(item.find('enclosure').get('url'), 'https://updates.invalid/app.zip?a=1&b=2')
        self.assertEqual(item.find('enclosure').get('{'+release.NS+'}edSignature'), 'signed')

    def stage(self, folder):
        names = ['HarborReply-0.1.27-apple-silicon.zip', 'appcast.xml', 'policy.json', 'SHA256SUMS']
        for name in names: (folder/name).write_text('synthetic artifact')
        manifest = {'source_commit': 'abc', 'version': '0.1.27', 'build': 28,
                    'config_sha256': release.config_digest(self.config),
                    'files': {name: release.sha(folder/name) for name in names}}
        (folder/'release-manifest.json').write_text(json.dumps(manifest))
        return manifest

    def test_resume_rejects_modified_artifacts_and_unexpected_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); manifest = self.stage(folder)
            self.assertEqual(release.validate_stage(folder, self.config, self.info, 'abc'), manifest)
            (folder/'policy.json').write_text('tampered')
            with self.assertRaises(ValueError): release.validate_stage(folder, self.config, self.info, 'abc')
            self.stage(folder); (folder/'private.txt').write_text('must not upload')
            with self.assertRaises(ValueError): release.validate_stage(folder, self.config, self.info, 'abc')

    def test_resume_rejects_different_source_and_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); self.stage(folder)
            with self.assertRaises(ValueError): release.validate_stage(folder, self.config, self.info, 'other')
            with self.assertRaises(ValueError): release.validate_stage(folder, dict(self.config, minimum_build=27), self.info, 'abc')

    def test_archive_failure_cannot_publish_feed(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); manifest = self.stage(folder)
            (folder/'policy.json').write_text(json.dumps({'payload': base64.b64encode(b'{"expiresAt":"2099-01-01T00:00:00Z"}').decode()}))
            class Result:
                returncode = 1
                stderr = '(HTTP 404)'
            with patch.object(release.subprocess, 'run', return_value=Result()), \
                 patch.object(release, 'run'), patch.object(release, 'api', return_value={'draft': True, 'assets': []}) as api, \
                 patch.object(release.urllib.request, 'urlopen', side_effect=OSError('offline')):
                with self.assertRaises(OSError): release.publish(self.config, self.info, folder, manifest)
                self.assertFalse(any('git/trees' in call.args for call in api.call_args_list))

    def test_success_publishes_only_allowlisted_metadata_after_archive_verification(self):
        import io
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); manifest = self.stage(folder)
            (folder/'policy.json').write_text(json.dumps({'payload': base64.b64encode(b'{"expiresAt":"2099-01-01T00:00:00Z"}').decode()}))
            calls = []
            class Result:
                returncode = 1
                stderr = '(HTTP 404)'
            def fake_api(repo, endpoint, method='GET', body=None):
                calls.append((endpoint, body))
                if endpoint.startswith('releases/'): return {'draft': True, 'assets': []}
                if endpoint == 'git/trees': return {'sha': 'tree'}
                if endpoint == 'git/commits': return {'sha': 'commit'}
                return {}
            def download(*args, **kwargs):
                calls.append(('download-verified-next', None))
                return io.BytesIO(b'synthetic artifact')
            with patch.object(release.subprocess, 'run', return_value=Result()), \
                 patch.object(release, 'run'), patch.object(release, 'api', side_effect=fake_api), \
                 patch.object(release.urllib.request, 'urlopen', side_effect=download):
                release.publish(self.config, self.info, folder, manifest)
            tree = next(body for endpoint, body in calls if endpoint == 'git/trees')
            self.assertEqual({entry['path'] for entry in tree['tree']}, {'appcast.xml', 'policy.json', 'release-manifest.json'})
            endpoints = [endpoint for endpoint, _ in calls]
            self.assertLess(endpoints.index('download-verified-next'), endpoints.index('git/trees'))
            self.assertEqual(calls[-1], ('git/refs', {'ref': 'refs/heads/updates', 'sha': 'commit'}))


@unittest.skipUnless((release.SPARKLE/'sign_update').is_file() and Path('/usr/bin/swift').is_file(), 'Native Sparkle tools unavailable')
class SparkleSigningTests(unittest.TestCase):
    def test_official_signer_matches_crypto_verifier_and_detects_tampering(self):
        import subprocess
        with tempfile.TemporaryDirectory(prefix='harbor-synthetic-update-key-') as tmp:
            folder = Path(tmp)
            keygen = folder/'keygen.swift'
            keygen.write_text('''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
            keyfile = folder/'synthetic.key'
            public = subprocess.check_output(['/usr/bin/swift', str(keygen), str(keyfile)], text=True).strip()
            keyfile.chmod(0o600)
            payload = folder/'payload.json'; payload.write_text('{"synthetic":true}')
            signer = [str(release.SPARKLE/'sign_update'), '--ed-key-file', str(keyfile)]
            signature = subprocess.check_output([*signer, '-p', str(payload)], text=True).strip()
            verifier = ['/usr/bin/swift', str(release.ROOT/'scripts/verify-update-signature.swift'), public, str(payload), signature]
            subprocess.run(verifier, check=True, capture_output=True)
            payload.write_text('{"synthetic":false}')
            self.assertNotEqual(subprocess.run(verifier, capture_output=True).returncode, 0)
            feed = folder/'appcast.xml'
            feed.write_bytes(release.appcast({'CFBundleVersion': '28', 'CFBundleShortVersionString': '0.1.27',
                                             'LSMinimumSystemVersion': '14.0'}, 'https://updates.invalid/app.zip', 42, signature))
            subprocess.run([*signer, '-p', str(feed)], check=True, capture_output=True)
            subprocess.run([*signer, '--verify', str(feed)], check=True, capture_output=True)
            feed.write_bytes(feed.read_bytes().replace(b'>28<', b'>29<'))
            self.assertNotEqual(subprocess.run([*signer, '--verify', str(feed)], capture_output=True).returncode, 0)
