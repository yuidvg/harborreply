"""Explicit local install safety; never touches /Applications or user Mail state."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('harborreply_deploy', Path(__file__).resolve().parents[1] / 'scripts/deploy.py')
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)
package_spec = importlib.util.spec_from_file_location('harborreply_package', Path(__file__).resolve().parents[1] / 'scripts/package-app.py')
package = importlib.util.module_from_spec(package_spec)
package_spec.loader.exec_module(package)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'source' / 'HarborReply.app'
        self.source.mkdir(parents=True)
        (self.source / 'package.txt').write_text('temporary install contents')
        self.destination = self.root / 'destination'
        self.destination.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def test_only_explicit_existing_absolute_directory_is_accepted(self):
        link = self.root / 'linked'
        link.symlink_to(self.destination, target_is_directory=True)
        for directory in [Path('relative'), self.root / 'missing', link]:
            with self.assertRaises(ValueError):
                deploy.install_app(self.source, directory)

    def test_existing_app_is_preserved_and_not_verified_or_replaced(self):
        old = self.destination / 'HarborReply.app'
        old.mkdir()
        marker = old / 'owner.txt'
        marker.write_text('preserve owner app')
        # The unsigned source would fail verification if installation proceeded.
        with self.assertRaises(ValueError):
            deploy.install_app(self.source, self.destination)
        self.assertEqual(marker.read_text(), 'preserve owner app')

    @unittest.skipUnless(Path('/usr/bin/codesign').is_file(), 'Native codesign unavailable')
    def test_failed_signature_leaves_destination_empty_and_success_is_complete(self):
        # Exercise actual signature rejection and actual verification of an ad-hoc signed app.
        macos = self.source / 'Contents/MacOS'
        macos.mkdir(parents=True)
        shutil.copyfile('/usr/bin/true', macos / 'HarborReply')
        (macos / 'HarborReply').chmod(0o755)
        info = {'CFBundleIdentifier': 'invalid.harborreply.install-test',
                'CFBundleExecutable': 'HarborReply', 'CFBundlePackageType': 'APPL',
                'CFBundleShortVersionString': package.VERSION}
        (self.source / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        resource = self.source / 'Contents/Resources/package.txt'
        resource.parent.mkdir()
        (self.source / 'package.txt').rename(resource)
        signature = subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(self.source)],
                                   capture_output=True, text=True)
        self.assertEqual(signature.returncode, 0, signature.stderr)
        resource.write_text('changed after signing')
        # install_app runs its own native verifier, which must reject the changed resource.
        with self.assertRaises(subprocess.CalledProcessError):
            deploy.install_app(self.source, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [])
        resource.write_text('temporary install contents')
        installed = deploy.install_app(self.source, self.destination)
        self.assertEqual((installed / 'Contents/Resources/package.txt').read_text(), 'temporary install contents')
        self.assertEqual(list(self.destination.iterdir()), [installed])


class PackageAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.app = Path(self.temporary.name) / 'HarborReply.app'
        self.contents = self.app / 'Contents'
        (self.contents / 'MacOS').mkdir(parents=True)
        self.resources = self.contents / 'Resources'
        self.resources.mkdir()
        self.plist = self.contents / 'Info.plist'
        self.plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': package.VERSION}))
        self.binary = self.contents / 'MacOS/HarborReply'
        self.binary.write_bytes(b'public application code')

    def tearDown(self):
        self.temporary.cleanup()

    def test_stale_build_cannot_be_relabelled_as_current_release(self):
        package.audit_app(self.app)
        self.plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.15'}))
        with self.assertRaisesRegex(RuntimeError, 'VERSION_MISMATCH'):
            package.audit_app(self.app)

    def test_old_cli_modes_cannot_ship_in_the_distribution_binary(self):
        for flag in [b'--demo', b'--self-test', b'--snapshot']:
            self.binary.write_bytes(b'application code\0' + flag + b'\0')
            with self.assertRaisesRegex(RuntimeError, 'RETIRED_RUNTIME_MODE'):
                package.audit_app(self.app)

    def test_runtime_mail_samples_cannot_survive_a_stale_resource_copy(self):
        nested = self.resources / 'HarborReply_HarborReply.bundle/Resources'
        nested.mkdir(parents=True)
        for name in ['demo.mbox', 'demo-style.eml', 'sample.eml', 'export.mbox']:
            fixture = nested / name
            fixture.write_text('From: owner@example.invalid\n\nPrepared test message\n')
            with self.assertRaisesRegex(RuntimeError, 'RUNTIME_MAIL_FIXTURE'):
                package.audit_app(self.app)
            fixture.unlink()
        package.audit_app(self.app)

    def test_fictional_scenarios_cannot_ship_inside_application_resources(self):
        scenarios = self.resources / 'scenarios.json'
        scenarios.write_text('{"fictional":true}')
        with self.assertRaisesRegex(RuntimeError, 'RUNTIME_MAIL_FIXTURE'):
            package.audit_app(self.app)


class DistributionAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.release = Path(self.temporary.name) / 'HarborReply-release'
        self.release.mkdir()
        self.app = self.release / 'HarborReply.app'
        contents = self.app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Resources').mkdir()
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': package.VERSION}))
        (contents / 'MacOS/HarborReply').write_bytes(b'public application code')
        (self.release / 'はじめに.md').write_text('Installation instructions\n')
        (self.release / 'docs').mkdir()
        (self.release / 'docs/MAIL_ACCEPTANCE.md').write_text('Owner-started Mail acceptance checklist\n')

    def tearDown(self):
        self.temporary.cleanup()

    def test_only_application_and_instructions_are_allowed(self):
        package.audit_release(self.release)
        fixture = self.release / 'mail-test.eml'
        fixture.write_text('From: owner@example.invalid\n\nPrepared test message\n')
        with self.assertRaisesRegex(RuntimeError, 'UNEXPECTED_DISTRIBUTION_CONTENT'):
            package.audit_release(self.release)
        fixture.unlink()
        scenarios = self.release / 'scenarios.json'
        scenarios.write_text('{"fictional":true}')
        with self.assertRaisesRegex(RuntimeError, 'UNEXPECTED_DISTRIBUTION_CONTENT'):
            package.audit_release(self.release)

    def test_acceptance_documents_cannot_carry_fixture_files(self):
        fixture = self.release / 'docs/mail-test.eml'
        fixture.write_text('From: owner@example.invalid\n\nPrepared test message\n')
        with self.assertRaisesRegex(RuntimeError, 'UNEXPECTED_DISTRIBUTION_DOCUMENT'):
            package.audit_release(self.release)

    def test_nested_mailbox_package_is_rejected(self):
        mailbox = self.app / 'Contents/Resources/export.mbox'
        mailbox.mkdir()
        (mailbox / 'mbox').write_text('Prepared test message\n')
        with self.assertRaisesRegex(RuntimeError, 'DISTRIBUTION_MAIL_FIXTURE'):
            package.audit_release(self.release)
