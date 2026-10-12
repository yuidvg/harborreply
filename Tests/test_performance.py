"""Bounded query-work regressions, not claims about a real 300GB mailbox."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('harbor_performance', Path(__file__).resolve().parents[1] / 'scripts/performance.py')
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)

class ScalingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = performance.run_suite((256, 1024, 4096), samples=3)

    def test_common_rare_disjoint_queries_and_fixed_case_have_bounded_work(self):
        self.assertTrue(self.report['gates']['passed'], self.report['gates']['failures'])
        self.assertTrue(self.report['gates']['negative_linear_controls_detected'])
        for row in self.report['datasets']:
            self.assertEqual(row['measurements']['common']['result_count'], 40)
            self.assertEqual(row['measurements']['rare']['result_count'], 1)
            self.assertEqual(row['measurements']['disjoint']['result_count'], 0)
            self.assertEqual(row['measurements']['coverage']['result_count'], row['count'])

    def test_reports_actual_metrics_and_preserves_evidence_boundaries(self):
        self.assertTrue(self.report['synthetic_only'])
        self.assertFalse(self.report['actual_300gb_verified'])
        self.assertFalse(self.report['gates']['elapsed_times_are_gates'])
        for row in self.report['datasets']:
            self.assertGreater(row['source_bytes'], 0)
            self.assertGreater(row['index_bytes'], 0)
            self.assertGreater(row['process_peak_rss_bytes'], 0)
            self.assertGreater(row['measurements']['context']['wall_p95_seconds'], 0)
            self.assertEqual(row['verified_ranges'], 20)
            self.assertLess(row['verified_range_bytes'], row['source_bytes'])
            self.assertFalse(row['reply_enumerated_all_sources'])

if __name__ == '__main__': unittest.main()
