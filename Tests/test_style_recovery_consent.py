"""A real-style workflow test must reject missing consent before any build/read."""
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StyleRecoveryConsentTests(unittest.TestCase):
    def test_missing_duplicate_and_unknown_options_exit_before_runtime_access(self):
        for arguments in ([], ['--allow-real-mail', '--allow-real-mail'],
                          ['--build-only', '--allow-real-mail'], ['--preflight'],
                          ['--allow-real-mail', '--allow-cloud-generation']):
            environment = dict(os.environ, HARBOR_LIVE_RUNTIME_APP='/unreadable-runtime-sentinel',
                               HARBOR_STYLE_RECOVERY_STATE_PARENT='/private-state-sentinel')
            result = subprocess.run(['/bin/zsh', str(ROOT / 'scripts/verify-style-recovery.sh'), *arguments],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env=environment, timeout=5, check=False)
            self.assertEqual(result.returncode, 64, arguments)
            self.assertEqual(result.stdout, b'')
            self.assertEqual(result.stderr, b'Use --build-only or --allow-real-mail. No Mail read was started.\n')
            self.assertNotIn(b'sentinel', result.stderr)

