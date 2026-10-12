"""External comparison rejects missing consent before runtime or Mail access."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StyleContentComparisonConsentTests(unittest.TestCase):
    def test_missing_duplicate_and_unknown_options_do_not_initialize_runtime(self):
        for arguments in ([], ['--allow-real-mail', '--allow-real-mail'], ['--build-only', '--allow-real-mail'],
                          ['--preflight'], ['--allow-real-mail', '--allow-cloud-generation']):
            environment = dict(os.environ, HARBOR_LIVE_RUNTIME_APP='/unreadable-runtime-sentinel',
                               HARBOR_STYLE_CONTENT_COMPARE_PARENT='/private-state-sentinel')
            process = subprocess.run(['/bin/zsh', str(ROOT / 'scripts/compare-style-content.sh'), *arguments],
                                     capture_output=True, timeout=5, env=environment, check=False)
            self.assertEqual(process.returncode, 64)
            self.assertEqual(process.stdout, b'')
            self.assertEqual(process.stderr, b'Use --build-only or --allow-real-mail. No Mail read was started.\n')
            self.assertNotIn(b'sentinel', process.stderr)


if __name__ == '__main__':
    unittest.main()
