"""Deterministic index-work gates, separate from actual Mail/300GB acceptance."""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('native_index_performance',Path(__file__).resolve().parents[1]/'scripts/index-performance.py')
performance=importlib.util.module_from_spec(spec); spec.loader.exec_module(performance)


class NativeIndexPerformanceTests(unittest.TestCase):
    def test_bounded_metadata_rank_with_older_target_and_growing_catalog(self):
        report=performance.run_suite((256,1024,4096),samples=3)
        self.assertTrue(report['gates']['passed'],report['gates']['failures'])
        self.assertFalse(report['actual_300gb_verified']); self.assertFalse(report['live_mail_verified'])
        self.assertFalse(report['gates']['elapsed_times_are_gates'])
        for dataset in report['datasets']:
            self.assertGreater(dataset['input_bytes'],0); self.assertGreater(dataset['index_bytes'],0)
            self.assertGreater(dataset['peak_rss_bytes'],0); self.assertGreater(dataset['rank_wall_p95_seconds'],0)
            self.assertEqual(dataset['raw_mime_copies'],0); self.assertEqual(dataset['rank_result_count'],60)
            self.assertTrue(any('SEARCH mail_index_catalog' in plan for plan in dataset['query_plans']))


if __name__ == '__main__': unittest.main()
