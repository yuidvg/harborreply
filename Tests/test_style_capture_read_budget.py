"""Persistent acquisition quotas, with synthetic private SQLite state only."""
import json
from pathlib import Path
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/HarborReply/Resources/worker'))
from archive import Archive, ArchiveError
from main import dispatch, process_request
from style_capture import StyleCapture
from style_capture_read_budget import (StyleCaptureReadBudget, MAX_ATTEMPTS,
                                       MAX_BYTES, MAX_READ_BYTES)
import test_archive as fixtures
from test_style_capture import sent


class StyleCaptureReadBudgetTests(unittest.TestCase):
    setUp = fixtures.ArchiveTests.setUp
    tearDown = fixtures.ArchiveTests.tearDown

    def start(self, **changes):
        self.capture = StyleCapture(self.a)
        arguments = dict(account_id='budget-account.invalid', selected_address='operator@fixture.invalid',
                         own_addresses=['operator@fixture.invalid'], author_confirmed=True, token_budget=4096)
        arguments.update(changes)
        state = self.capture.start(**arguments)
        self.budget = StyleCaptureReadBudget(self.a)
        return state['capture_id']

    def token(self):
        return str(uuid.uuid4())

    def request(self, command, **values):
        return dict(db=str(self.root / 'state' / 'db.sqlite'), command=command, **values)

    def test_exact_reserve_and_ack_retries_do_not_double_charge_attempts_or_bytes(self):
        capture = self.start()
        token = self.token()
        before = self.a.revision()
        reserved = self.budget.reserve(capture, token, 8)
        self.assertEqual(reserved, dict(reserved_attempts=8, captured_bytes=0,
                                       unresolved_bytes=8*MAX_READ_BYTES))
        self.assertEqual(self.budget.reserve(capture, token.upper(), 8), reserved)
        charged = self.budget.charge(capture, token, 999)
        self.assertEqual(charged, dict(reserved_attempts=8, captured_bytes=999, unresolved_bytes=0))
        self.assertEqual(self.budget.charge(capture, token.upper(), 999), charged)
        self.assertEqual(self.budget.reserve(capture, token, 8), charged)
        self.assertEqual(self.a.db.execute('SELECT count(*) FROM style_capture_read_requests').fetchone()[0], 1)
        self.assertEqual(self.a.revision(), before)

    def test_changed_reserve_or_ack_and_unknown_token_are_rejected_atomically(self):
        capture = self.start()
        token = self.token()
        self.budget.reserve(capture, token, 2)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_RETRY_CHANGED'):
            self.budget.reserve(capture, token, 3)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_CHARGE_INVALID'):
            self.budget.charge(capture, token, 2*MAX_READ_BYTES+1)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_REQUEST_UNKNOWN'):
            self.budget.charge(capture, self.token(), 0)
        retained = self.budget.status(capture)
        self.assertEqual(retained['unresolved_bytes'], 2*MAX_READ_BYTES)
        charged = self.budget.charge(capture, token, 12)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_RETRY_CHANGED'):
            self.budget.charge(capture, token, 13)
        self.assertEqual(self.budget.status(capture), charged)

    def test_crash_pending_reservation_survives_new_process_pause_and_resume(self):
        capture = self.start()
        token = self.token()
        expected = self.budget.reserve(capture, token, 8)
        self.capture.finish(capture, status='cancelled')
        self.a.db.close()
        self.a = Archive(self.root / 'state' / 'db.sqlite')
        capture_again = self.start(restart=False)
        self.assertEqual(capture_again, capture)
        self.assertEqual(self.budget.status(capture), expected)
        self.assertEqual(self.budget.reserve(capture, token, 8), expected)
        settled = self.budget.charge(capture, token, 0)
        self.assertEqual(settled['reserved_attempts'], 8)
        self.assertEqual(settled['unresolved_bytes'], 0)
        self.assertEqual(settled['captured_bytes'], 0)

    def test_attempt_limit_remains_in_force_across_resumptions(self):
        capture = self.start()
        for index in range(MAX_ATTEMPTS // 8):
            token = self.token()
            self.budget.reserve(capture, token, 8)
            self.budget.charge(capture, token, 0)
            if index in (30, 80):
                self.capture.finish(capture, status='paused')
                self.assertEqual(self.start(restart=False), capture)
        self.assertEqual(self.budget.status(capture)['reserved_attempts'], MAX_ATTEMPTS)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_LIMIT'):
            self.budget.reserve(capture, self.token(), 1)
        self.assertEqual(self.a.db.execute('SELECT count(*) FROM style_capture_read_requests').fetchone()[0], 128)

    def test_unresolved_worst_case_bytes_remain_charged_and_bound_failed_retries(self):
        capture = self.start()
        self.budget.reserve(capture, self.token(), 28)
        self.capture.finish(capture, status='cancelled')
        self.assertEqual(self.start(restart=False), capture)
        prior = self.budget.status(capture)
        self.assertEqual(prior['unresolved_bytes'], 28*MAX_READ_BYTES)
        self.assertLessEqual(prior['unresolved_bytes'], MAX_BYTES)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_LIMIT'):
            self.budget.reserve(capture, self.token(), 3)
        self.assertEqual(self.budget.status(capture), prior)

    def test_charged_and_unresolved_bytes_share_one_limit(self):
        capture = self.start()
        token = self.token()
        self.budget.reserve(capture, token, 28)
        self.budget.charge(capture, token, 28*MAX_READ_BYTES)
        self.assertEqual(self.budget.status(capture)['captured_bytes'], 28*MAX_READ_BYTES)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_LIMIT'):
            self.budget.reserve(capture, self.token(), 3)

    def test_new_configuration_gets_independent_budget_and_gc_retains_published_capture(self):
        original = self.start()
        token = self.token()
        self.budget.reserve(original, token, 4)
        self.budget.charge(original, token, 300)
        self.capture.page(original, None, {'fixture': 1}, [sent(1, accountID='budget-account.invalid')], 1)
        self.capture.finish(original)
        self.capture.extract(original)
        for _ in range(5):
            current = self.start(restart=True)
            self.assertNotEqual(current, original)
            self.assertEqual(self.budget.status(current), dict(reserved_attempts=0, captured_bytes=0, unresolved_bytes=0))
            self.budget.reserve(current, token, 1)
            self.budget.charge(current, token, 0)
            self.assertLessEqual(self.a.db.execute('SELECT count(*) FROM style_capture_read_totals').fetchone()[0], 2)
        retained = {row[0] for row in self.a.db.execute('SELECT capture_id FROM style_capture_read_totals')}
        self.assertEqual(retained, {original, current})
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_CAPTURE_CHANGED'):
            self.budget.status(original)

    def test_unknown_capture_and_nonrunning_reserve_or_pending_ack_are_refused(self):
        capture = self.start()
        token = self.token()
        self.budget.reserve(capture, token, 2)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_CAPTURE_CHANGED'):
            self.budget.reserve(self.token(), self.token(), 2)
        self.capture.finish(capture, status='paused')
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_NOT_RUNNING'):
            self.budget.reserve(capture, self.token(), 2)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_NOT_RUNNING'):
            self.budget.reserve(capture, token, 2)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_NOT_RUNNING'):
            self.budget.charge(capture, token, 0)
        self.assertEqual(self.budget.status(capture)['unresolved_bytes'], 2*MAX_READ_BYTES)

    def test_exact_ack_retry_is_readonly_after_completion(self):
        capture = self.start()
        token = self.token()
        self.budget.reserve(capture, token, 2)
        charged = self.budget.charge(capture, token, 13)
        self.capture.finish(capture)
        before = self.a.revision()
        self.assertEqual(self.budget.charge(capture, token, 13), charged)
        self.assertEqual(self.a.revision(), before)
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_RETRY_CHANGED'):
            self.budget.charge(capture, token, 14)

    def test_invalid_numbers_and_non_uuid_tokens_do_not_create_reservations(self):
        capture = self.start()
        for reads in (True, 0, -1, 41, 1.0, '2', None):
            with self.subTest(reads=reads), self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_INPUT_INVALID'):
                self.budget.reserve(capture, self.token(), reads)
        for token in ('', 'body@fixture.invalid', str(uuid.uuid4())+'\n', None):
            with self.subTest(token=token), self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_INPUT_INVALID'):
                self.budget.reserve(capture, token, 2)
        for size in (True, -1, MAX_BYTES+1, 1.0, None):
            with self.subTest(size=size), self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_INPUT_INVALID'):
                self.budget.charge(capture, self.token(), size)
        self.assertEqual(self.budget.status(capture), dict(reserved_attempts=0, captured_bytes=0, unresolved_bytes=0))

    def test_corrupt_aggregate_is_detected_before_new_native_authorization(self):
        capture = self.start()
        self.budget.reserve(capture, self.token(), 2)
        with self.a.db:
            self.a.db.execute('UPDATE style_capture_read_totals SET reserved_attempts=3 WHERE capture_id=?', (capture,))
        with self.assertRaisesRegex(ArchiveError, 'STYLE_READ_BUDGET_STATE_INVALID'):
            self.budget.reserve(capture, self.token(), 2)
        self.assertEqual(self.a.db.execute('SELECT count(*) FROM style_capture_read_requests').fetchone()[0], 1)

    def test_ipc_dispatch_has_exact_numeric_contract_and_fixed_failures(self):
        capture = self.start()
        token = self.token()
        reserve = dispatch(self.request('style_capture_read_reserve', capture_id=capture, attempt_id=token, reads=8))
        self.assertEqual(set(reserve), {'reserved_attempts', 'captured_bytes', 'unresolved_bytes'})
        charged = dispatch(self.request('style_capture_read_charge', capture_id=capture,
                                        attempt_id=token, captured_bytes=500))
        self.assertEqual(charged['captured_bytes'], 500)
        self.assertEqual(dispatch(self.request('style_capture_read_budget', capture_id=capture)), charged)
        raw = json.dumps(self.request('style_capture_read_charge', capture_id=capture,
                                     attempt_id=token, captured_bytes=501)).encode()
        self.assertEqual(process_request(raw), {'ok': False, 'error': 'STYLE_READ_BUDGET_RETRY_CHANGED'})
        missing = json.dumps(self.request('style_capture_read_reserve', capture_id=capture, reads=8)).encode()
        self.assertEqual(process_request(missing), {'ok': False, 'error': 'IPC_REQUEST_INVALID'})


if __name__ == '__main__':
    unittest.main()
