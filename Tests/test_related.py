"""Rank bounded, fictional metadata; candidates never become mail facts."""
import json
from pathlib import Path
import resource
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
import archive as archive_module
from archive import ArchiveError, packed, rank_related_rows, tokens
from context import build_context
from main import dispatch
import test_archive as fixtures


class RelatedRetrievalTests(unittest.TestCase):
    setUp = fixtures.ArchiveTests.setUp
    tearDown = fixtures.ArchiveTests.tearDown
    add = fixtures.ArchiveTests.add

    def current(self, **changes):
        return dict({'id': 'selected-native', 'messageID': 'selected@aws-fixture.invalid',
                     'subject': 'AWS Free Tier limit alert', 'sender': 'alerts@aws-fixture.invalid',
                     'body': 'Fictional current notification.', 'headers': ''}, **changes)

    def add_history(self, title, identity, sender='notifications@aws-fixture.invalid', body='Fictional historical details.'):
        message = fixtures.mail(body, mid=identity+'@history.invalid', subject=title)
        message.replace_header('From', sender)
        return self.add(message, identity+'.eml')[1]

    def test_generic_overlap_ranks_more_shared_terms_first(self):
        topic = self.add_history('AWS Free Tier usage', 'topic')
        alias = self.add_history('Amazon Web Services Free Tier warning', 'alias', 'notice@amazon-fixture.invalid')
        billing = self.add_history('AWS billing overview', 'billing')
        spam = self.add_history('FREE laundry limit alert', 'spam', 'offers@laundry.invalid')
        self.assertEqual(self.a.search_ids(self.current()['subject']), [])  # Manual search remains AND.
        ranked = self.a.related_candidates(self.current())
        self.assertEqual({row['id'] for row in ranked}, {topic, alias, billing, spam})
        self.assertEqual(next(row['reason'] for row in ranked if row['id'] == billing), 'subject_terms')
        self.assertGreater(next(row['score'] for row in ranked if row['id'] == topic),
                           next(row['score'] for row in ranked if row['id'] == billing))
        context = build_context(self.a, self.current())
        self.assertEqual(set(context['candidate_ids']), {topic, alias, billing, spam})
        self.assertEqual(len(context['thread_evidence']), 1)
        self.assertEqual(context['case_events'], [])
        self.assertTrue(context['unresolved_items'])
        previews = self.a.candidate_previews(context['candidate_ids'], context['candidate_reasons'])
        self.assertIn('件名の語句', next(p['related_reason'] for p in previews if p['id'] == billing))
        self.assertNotIn('Fictional historical details', json.dumps(previews))

    def test_header_parent_wins_and_native_and_archive_share_rank_contract(self):
        topic = self.add_history('AWS Free Tier usage', 'topic')
        parent = self.add_history('Changed old subject', 'parent', 'old@correspondence.invalid')
        current = self.current(headers='In-Reply-To: <parent@history.invalid>\r\n')
        ranked = self.a.related_candidates(current)
        # Header graph expands outside the lexical pool, retaining highest priority.
        context = build_context(self.a, current)
        self.assertEqual(context['candidate_ids'][0], parent)
        self.assertIn(topic, context['candidate_ids'])
        native = [{'id': 'native-topic', 'subject': 'AWS Free Tier usage', 'sender': 'notifications@aws-fixture.invalid', 'messageID': 'topic@history.invalid'},
                  {'id': 'native-parent', 'subject': 'Changed old subject', 'sender': 'old@correspondence.invalid', 'messageID': 'parent@history.invalid'},
                  {'id': current['id'], 'subject': current['subject'], 'sender': current['sender'], 'messageID': ''},
                  {'id': 'current-duplicate', 'subject': current['subject'], 'sender': current['sender'], 'messageID': current['messageID']}]
        response = dispatch({'db': str(self.root/'state/db.sqlite'), 'command': 'rank_mail_headers', 'current': current, 'records': native})
        self.assertEqual(response['ids'], ['native-parent', 'native-topic'])
        self.assertEqual(response['matches'][0]['reason'], 'reply_header')
        self.assertEqual(response['matches'][1]['score'], ranked[0]['score'])
        self.assertGreater(response['matches'][0]['score'], response['matches'][1]['score'])

    def test_generic_notifications_and_same_sender_alone_are_insufficient(self):
        current = self.current(subject='Notification alert', sender='person@shared.invalid')
        rows = [{'id': 'other', 'subject': 'Notification alert', 'sender': 'other@shared.invalid'},
                {'id': 'same', 'subject': 'Dinner invitation', 'sender': 'person@shared.invalid'}]
        self.assertEqual(rank_related_rows(current, rows), [])

    def test_brand_renaming_preserves_scores_and_candidate_retrieval(self):
        results = []
        for brand in ('AWS', 'Zephyr', 'Cobalt'):
            current = self.current(subject=brand+' capacity report')
            rows = [{'id': 'matching', 'subject': brand+' capacity summary', 'sender': 'a@sample.invalid'},
                    {'id': 'brand-only', 'subject': brand+' invoice', 'sender': 'b@sample.invalid'},
                    {'id': 'different', 'subject': 'Dinner invitation', 'sender': current['sender']}]
            results.append(rank_related_rows(current, rows))
            for row in rows[:2]: self.add_history(row['subject'], brand+row['id'], row['sender'])
            matches = self.a.related_candidates(current)
            self.assertEqual(matches[0]['score'], results[-1][0]['score'])
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[1], results[2])

    def test_no_implicit_brand_aliases_or_sender_domain_classification(self):
        rows = [{'id': 'alias', 'subject': 'Amazon Web Services invoice', 'sender': 'a@sample.invalid'},
                {'id': 'domain', 'subject': 'Dinner invitation', 'sender': 'a@amazonaws.com.example.invalid'}]
        self.assertEqual(rank_related_rows(self.current(subject='AWS report'), rows), [])

    def test_bounds_and_budget_failure_return_no_partial_success_and_reset(self):
        rows = [{'id': 'native-'+str(i), 'subject': 'AWS billing overview', 'sender': 'notice@aws-fixture.invalid'} for i in range(768)]
        self.assertEqual(len(rank_related_rows(self.current(), rows)), 20)
        with self.assertRaisesRegex(ArchiveError, 'RELATED_RECORD_LIMIT'):
            rank_related_rows(self.current(), rows + [dict(rows[0], id='extra')])
        with self.assertRaisesRegex(ArchiveError, 'RELATED_DUPLICATE_ID'):
            rank_related_rows(self.current(), [rows[0], rows[0]])
        with self.assertRaisesRegex(ArchiveError, 'RELATED_INPUT_LIMIT'):
            rank_related_rows(None, [])
        topic = self.add_history('AWS Free Tier usage', 'topic')
        with patch.object(archive_module, 'SEARCH_MAX_VM_STEPS', 1):
            with self.assertRaisesRegex(ArchiveError, 'SEARCH_BUDGET_EXCEEDED_NARROW_QUERY'):
                self.a.related_candidates(self.current())
        self.assertIsNone(self.a._query_budget)
        self.assertEqual(self.a.related_candidates(self.current())[0]['id'], topic)
        with patch.object(archive_module, 'SEARCH_MAX_SECONDS', 0):
            with self.assertRaisesRegex(ArchiveError, 'SEARCH_BUDGET_EXCEEDED_NARROW_QUERY'):
                rank_related_rows(self.current(), rows)

    def test_ranked_pool_work_stays_bounded_with_common_provider_and_rare_topic(self):
        # Actual query VM work is gated over growing indexed datasets. This is
        # an index regression, not evidence of a 300GB Mail installation.
        target = self.add_history('AWS Free Tier usage', 'rare-target')
        steps_by_size = []; self.metrics = []
        for count in (128, 1024, 4096):
            with self.a.db:
                for index in range(count):
                    mid = 'noise-'+str(index)
                    subject = 'AWS billing overview' if index % 2 else 'FREE laundry alert'
                    payload = {'id': mid, 'subject': subject, 'from': 'noise@provider-fixture.invalid',
                               'message_id': mid+'@noise.invalid', 'body_text': 'No candidate body should be hydrated.'}
                    inserted = self.a.db.execute('INSERT OR IGNORE INTO messages(id,message_id,payload) VALUES(?,?,?)', (mid, payload['message_id'], packed(payload)))
                    if inserted.rowcount:
                        self.a.db.execute('INSERT INTO search VALUES(?,?)', (mid, ' '.join(tokens(subject))))
            steps = [0]; queries = []; started = time.perf_counter()
            self.a._sql_step_observer = lambda amount: steps.__setitem__(0, steps[0]+amount)
            self.a.db.set_trace_callback(queries.append)
            try:
                with patch.object(self.a, 'message', side_effect=AssertionError('BODY_OR_SOURCE_HYDRATION_IN_RANK')):
                    ranked = self.a.related_candidates(self.current())
            finally:
                self.a._sql_step_observer = None; self.a.db.set_trace_callback(None)
            self.metrics.append({'N': count, 'wall_seconds': time.perf_counter()-started,
                                 'sqlite_vm_steps': steps[0], 'peak_rss': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
            self.assertEqual(ranked[0]['id'], target)  # Not starved by common provider rows.
            search_queries = [q for q in queries if 'FROM search WHERE search MATCH' in q]
            metadata_queries = [q for q in queries if 'FROM messages WHERE id=' in q]
            self.assertLessEqual(len(search_queries), 3)
            self.assertLessEqual(len(metadata_queries), 180)
            self.assertLess(steps[0], 10000)
            for query in search_queries + metadata_queries:
                plan = ' '.join(str(r[3]) for r in self.a.db.execute('EXPLAIN QUERY PLAN '+query))
                self.assertNotIn('TEMP B-TREE', plan)
                if 'FROM messages' in query: self.assertIn('SEARCH messages', plan)
            steps_by_size.append(steps[0])
        # FTS segment trees add logarithmic traversal work as indexing grows;
        # this tolerance still rejects an N-proportional metadata walk at 4096.
        self.assertLessEqual(steps_by_size[-1], steps_by_size[0] + 2500)


if __name__ == '__main__': unittest.main()
