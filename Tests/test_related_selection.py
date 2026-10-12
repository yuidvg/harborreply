"""Only synthetic .invalid mail; verify the actual prepare-to-provider input."""
import unittest
import test_related
from context import build_context
from main import dispatch

class RelatedSelectionTests(unittest.TestCase):
    setUp = test_related.RelatedRetrievalTests.setUp
    tearDown = test_related.RelatedRetrievalTests.tearDown
    add = test_related.RelatedRetrievalTests.add
    current = test_related.RelatedRetrievalTests.current
    add_history = test_related.RelatedRetrievalTests.add_history
    def test_candidates_default_selected_without_case_confirmation(self):
        mid = self.add_history('AWS Free Tier usage', 'selection')
        prepared = dispatch({'db':str(self.root/'state/db.sqlite'), 'command':'prepare',
            'input':dict(current=self.current(), related_selection={'excluded_ids':[]})})
        self.assertIn(mid, [e['message_id'] for e in prepared['context']['thread_evidence']])
        self.assertIn(mid, [m['id'] for m in prepared['candidate_messages']])
        self.assertEqual(prepared['context']['unresolved_items'], [])
    def test_exclusion_changes_input_but_keeps_candidate_visible(self):
        mid = self.add_history('AWS Free Tier usage', 'excluded')
        result = build_context(self.a, self.current(), related_selection={'excluded_ids':[mid]})
        self.assertNotIn(mid, [e['message_id'] for e in result['thread_evidence']])
        self.assertIn(mid, result['candidate_ids'])
    def test_unknown_direction_is_preserved_not_promoted_to_sent(self):
        mid = self.add_history('AWS Free Tier usage', 'unknown')
        with self.a.db: self.a.db.execute("UPDATE sources SET direction='unknown'")
        result = build_context(self.a, self.current(), related_selection={'excluded_ids':[]})
        item = next(e for e in result['thread_evidence'] if e['message_id']==mid)
        self.assertEqual(item['direction'],'unknown')
        self.assertTrue(any('送信済み' in w for w in result['local_warnings']))
    def test_many_long_selected_messages_use_bounded_visible_excerpts(self):
        for n in range(12): self.add_history('AWS Free Tier usage', 'long'+str(n), body='Content '*1500)
        result = build_context(self.a, self.current(), related_selection={'excluded_ids':[]})
        self.assertEqual(len(result['thread_evidence']),13)
        self.assertLess(sum(len(e['text']) for e in result['thread_evidence']),24000)
        self.assertTrue(any('抜粋' in w for w in result['local_warnings']))
