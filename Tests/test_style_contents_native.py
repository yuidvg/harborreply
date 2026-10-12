"""Execute style-only native getters against a test-only in-process recipient.

No real Mail, archive, credentials or owner state is addressed by these tests.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from Tests.test_mail_native_adapter_events import SWIFT_RECIPIENT

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'Sources/HarborReply/Resources/MailBridge.applescript').read_text()
AVAILABLE = sys.platform == 'darwin' and shutil.which('swiftc') is not None


def handler(name):
    return re.search(rf'^on {name}\(.*?^end {name}$', SOURCE, re.M | re.S).group(0)


NAMES = ('strictEqual', 'styleContentsScope', 'mailText', 'bodyMetricBegin', 'bodyMetricPhase', 'bodyMetricGet', 'bodyMetricResult',
         'styleSenderColumn', 'styleSizeColumn', 'styleCandidatePage', 'styleContentRange',
         'styleContentScalar', 'styleValidateCandidates', 'styleContentText', 'styleContentGroups', 'styleReadContents')


def fixture_source(mode='contents', number=-1708):
    source = '\n'.join(handler(name) for name in NAMES).replace('tell application "Mail"', 'tell current application')
    for word, code in [('message size', 'msze'), ('messages', 'mssg'), ('sender', 'sndr'), ('content', 'ctnt')]:
        source = re.sub(r'\b' + word + r'\b', '«class ' + code + '»', source)
    if mode in ('fallback', 'unavailable', 'fatal'):
        source = source.replace('tell current application to return get «class ctnt» of («class mssg» firstIndex thru lastIndex of b)',
                                'error "FICTIONAL_RANGE_FAILURE" number ' + str(number))
    if mode == 'unavailable':
        source = source.replace('tell current application to return get «class ctnt» of («class mssg» messagePosition of b)',
                                'if messagePosition is 2 then error "FICTIONAL_TIMEOUT" number -1712\n'
                                '    tell current application to return get «class ctnt» of («class mssg» messagePosition of b)')
    if mode == 'shape':
        source = source.replace("set values to reader's styleContentRange(b, firstIndex, lastIndex)",
                                "set ignoredValues to reader's styleContentRange(b, firstIndex, lastIndex)\n    set values to {}")
    positions = '{1, 3, 4, 8}' if mode == 'sparse' else '{1, 2, 3, 4}'
    candidates_size = '2097153' if mode == 'size' else '42'
    return '''property readFailureStage : 0
property bodyMetricPhaseValue : 0
property bodyMetricStarted : 0.0
property bodyMetricTimes : {0,0,0,0}
property bodyMetricGets : {0,0,0,0}
property fallbackCalls : 0
property styleContentsScopeKey : missing value
property styleContentsScopeValue : missing value
property fixtureScopeResolves : 0
on bodyMetricNow()
    return 0.0
end bodyMetricNow
on indexMailbox(accountID, pathNames, localValue)
    set my fixtureScopeResolves to my fixtureScopeResolves + 1
    tell current application to return a reference to «class mbxp» "Fictional Sent"
end indexMailbox
on styleMessageCount(b)
    my bodyMetricGet()
    return 128
end styleMessageCount
''' + source + f'''
on perform()
    set cursorData to {{"fixture-account", {{"Fictional Sent"}}, 0, 128, "fixture-scan", false, "sent"}}
    try
        if "{mode}" is "candidates" then
            set resultValue to my styleCandidatePage(cursorData, 128, me)
            if (count of item 3 of resultValue) is not 128 then error "FICTIONAL_COUNT" number 9991
            repeat with p from 1 to 128
                set rowValue to item p of item 3 of resultValue
                if item 1 of rowValue is not p or item 2 of rowValue is not "sender@fixture.invalid" or item 3 of rowValue is not 42 then error "FICTIONAL_COLUMNS" number 9992
            end repeat
        else
            set candidates to {{}}
            repeat with p in {positions}
                set end of candidates to {{p as integer, "sender@fixture.invalid", {candidates_size}}}
            end repeat
            if "{mode}" is "cached" then set initialCandidates to my styleCandidatePage(cursorData, 128, me)
            try
                set resultValue to my styleReadContents(cursorData, candidates, me, false)
            on error number errorNumber
                if errorNumber is not -1708 and errorNumber is not -1712 then error "FICTIONAL_FATAL" number errorNumber
                set allRows to {{}}
                repeat with candidateRef in candidates
                    set candidateValue to contents of candidateRef
                    set my fallbackCalls to my fallbackCalls + 1
                    set scalarValue to my styleReadContents(cursorData, {{candidateValue}}, me, true)
                    set allRows to allRows & item 2 of scalarValue
                end repeat
                set resultValue to {{"HARBOR_STYLE_CONTENTS_V1", allRows, {{}}}}
            end try
            if "{mode}" is "cached" then
                set repeatedValue to my styleReadContents(cursorData, candidates, me, false)
                if my fixtureScopeResolves is not 1 then error "FICTIONAL_SCOPE_REPEATED" number 9996
                set changedCursor to {{"fixture-account", {{"Fictional Sent"}}, 0, 128, "fixture-other-capture", false, "sent"}}
                set changedValue to my styleReadContents(changedCursor, candidates, me, false)
                if my fixtureScopeResolves is not 2 then error "FICTIONAL_SCOPE_NOT_CHANGED" number 9997
            end if
            if (count of item 2 of resultValue) is not 4 then error "FICTIONAL_COUNT" number 9991
            repeat with p from 1 to 4
                set rowValue to item p of item 2 of resultValue
                set positionValue to item 1 of item p of candidates
                if item 1 of rowValue is not positionValue then error "FICTIONAL_ORDER" number 9993
                if "{mode}" is "unavailable" and positionValue is 2 then
                    if item 2 of rowValue is not "" or item 3 of rowValue is not -1712 then error "FICTIONAL_TIMEOUT_ROW" number 9994
                else
                    if item 2 of rowValue is not "Fictional body " & positionValue or item 3 of rowValue is not 0 then error "FICTIONAL_BODY" number 9995
                end if
            end repeat
        end if
        return {{"FICTIONAL_NATIVE_ADAPTER_PASSED", 0, 0, my fallbackCalls}}
    on error number errorNumber
        return {{"FICTIONAL_NATIVE_ADAPTER_FAILED", errorNumber, my readFailureStage, my fallbackCalls}}
    end try
end perform
'''


RECIPIENT = SWIFT_RECIPIENT.replace(
    'case code("msze"): return NSAppleEventDescriptor(int32: 42)',
    'case code("msze"): return NSAppleEventDescriptor(int32: 42)\n'
    '        case code("ctnt"): return NSAppleEventDescriptor(string: "Fictional body \\(position)")')


class StyleContentsSourceTests(unittest.TestCase):
    def test_production_style_path_has_only_sender_size_and_content_getters(self):
        for name in ('styleCandidatePage', 'styleContentGroups', 'styleReadContents'):
            self.assertNotRegex(handler(name), r'\b(?:bodyCheckpoint|bodyDirectMetadata|indexRole|indexHeaderPage|indexHydrate|attachment|headers|nativeID)\b')
        self.assertIn('get sender of (messages firstIndex thru lastIndex of b)', handler('styleSenderColumn'))
        self.assertIn('get message size of (messages firstIndex thru lastIndex of b)', handler('styleSizeColumn'))
        self.assertIn('get content of (messages firstIndex thru lastIndex of b)', handler('styleContentRange'))
        self.assertIn('get content of («class mssg» messagePosition of b)', handler('styleContentScalar'))
        self.assertNotIn('styleMessageCount', handler('styleReadContents'))
        self.assertNotRegex(handler('styleReadContents'), r'\b(?:after|whose|every|properties)\b')

    def test_defaults_never_fall_back_to_archive_identity_acquisition(self):
        source = (ROOT / 'Sources/HarborReply/MailSelectionBridge.swift').read_text()
        for name in ('styleCandidates', 'styleContents'):
            implementation = re.search(rf'    func {name}\(.*?\n    }}', source[source.index('extension MailSelectionBridge'):], re.S).group(0)
            self.assertIn('throw StyleContentError.unsupported', implementation)
            self.assertNotRegex(implementation, r'\b(?:indexPage|hydrateIndexed)\b')
        engine = (ROOT / 'Sources/HarborReply/MailBridge.swift').read_text()
        implementation = engine[engine.index('    func styleContents(batch: StyleContentBatch, gate:'):engine.index('    func styleAccounts(gate:')]
        self.assertNotRegex(implementation, r'\b(?:hydrateIndexed|indexPage|validateCachedIndexed)\b')
        self.assertIn('operation: "style_content_scalar"', implementation)
        self.assertIn('!context.isShapeFailure', implementation)

    def test_fixture_cannot_address_mail(self):
        self.assertNotIn('application "Mail"', fixture_source())
        self.assertNotIn('~/Library/Mail', fixture_source())

    @unittest.skipUnless(shutil.which('osascript'), 'host pure AppleScript interpreter unavailable')
    def test_capture_scope_cache_resolves_once_and_changes_scan_account_or_path_locally(self):
        source = '\n'.join(handler(name) for name in ('strictEqual', 'styleContentsScope'))
        self.assertNotIn('application "Mail"', source)
        dependencies = '\nproperty styleContentsScopeKey : missing value\nproperty styleContentsScopeValue : missing value\nproperty fixtureScopeResolves : 0\non indexMailbox(accountID, pathNames, localValue)\n    set my fixtureScopeResolves to my fixtureScopeResolves + 1\n    return my fixtureScopeResolves\nend indexMailbox\n'
        calls = '\nset original to {"fixture-account", {"Fictional Sent"}, 0, 128, "fixture-capture-1", false, "sent"}\nset firstValue to my styleContentsScope(original)\nset sameValue to my styleContentsScope(original)\nset nextPage to {"fixture-account", {"Fictional Sent"}, 128, 256, "fixture-capture-1", false, "sent"}\nset nextValue to my styleContentsScope(nextPage)\nif firstValue is not 1 or sameValue is not 1 or nextValue is not 1 or my fixtureScopeResolves is not 1 then error "FICTIONAL_SCOPE_REPEATED" number 9991\nset newCapture to {"fixture-account", {"Fictional Sent"}, 0, 128, "fixture-capture-2", false, "sent"}\nset captureValue to my styleContentsScope(newCapture)\nset newAccount to {"other-fixture-account", {"Fictional Sent"}, 0, 128, "fixture-capture-2", false, "sent"}\nset accountValue to my styleContentsScope(newAccount)\nset newPath to {"other-fixture-account", {"Archive", "Fictional Sent"}, 0, 128, "fixture-capture-2", false, "sent"}\nset pathValue to my styleContentsScope(newPath)\nif captureValue is not 2 or accountValue is not 3 or pathValue is not 4 or my fixtureScopeResolves is not 4 then error "FICTIONAL_SCOPE_NOT_INVALIDATED" number 9992\nreturn "FICTIONAL_SCOPE_CACHE_PASSED"\n'
        result = subprocess.run([shutil.which('osascript'), '-'], input=dependencies + source + calls,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'FICTIONAL_SCOPE_CACHE_PASSED')

    def test_engine_epoch_reset_discards_the_script_scope_cache(self):
        source = (ROOT / 'Sources/HarborReply/MailBridge.swift').read_text()
        engine_reset = source[source.index('    func clearTracking() {', source.index('private final class MailScriptEngine')):]
        self.assertIn('script = nil', engine_reset.split('    private func call(', 1)[0])


@unittest.skipUnless(AVAILABLE, 'host Swift/AppKit runtime unavailable')
class StyleContentsNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='harbor-style-content-fixture-')
        cls.root = pathlib.Path(cls.directory.name)
        source = cls.root / 'recipient.swift'; source.write_text(RECIPIENT)
        cls.binary = cls.root / 'recipient'
        built = subprocess.run([shutil.which('swiftc'), str(source), '-o', str(cls.binary)], text=True, capture_output=True, timeout=45)
        if built.returncode:
            cls.directory.cleanup(); raise AssertionError(built.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_fixture(self, mode='contents', number=-1708):
        source = self.root / 'style.applescript'; source.write_text(fixture_source(mode, number))
        result = subprocess.run([str(self.binary), str(source), 'supported', str(number)], text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['execution_error_number'], 0, report)
        self.assertEqual(report['unexpected_events'], 0, report)
        self.assertEqual(report['bare_message_gets'], 0, report)
        self.assertFalse(report['real_mail_events_executed'])
        return report

    def test_128_candidates_use_two_property_gets_and_no_scalar_identification(self):
        report = self.run_fixture('candidates')
        self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED', report)
        self.assertEqual(report['range_gets'], 2)
        self.assertEqual(report['scalar_gets'], 0)
        self.assertEqual(report['property_codes'], sorted(int.from_bytes(p, 'big') for p in (b'sndr', b'msze')))

    def test_four_contiguous_bodies_use_one_content_get(self):
        report = self.run_fixture()
        self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED', report)
        self.assertEqual(report['range_gets'], 1)
        self.assertEqual(report['scalar_gets'], 0)
        self.assertEqual(report['property_codes'], [int.from_bytes(b'ctnt', 'big')])

    def test_resolved_candidate_scope_is_reused_for_two_body_calls_and_new_capture_misses(self):
        report = self.run_fixture('cached')
        self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED', report)
        self.assertEqual(report['range_gets'], 5)  # Two candidate columns + three body calls.
        self.assertEqual(report['scalar_gets'], 0)
        self.assertEqual(report['property_codes'], sorted(int.from_bytes(p, 'big') for p in (b'sndr', b'msze', b'ctnt')))

    def test_sparse_positions_are_grouped_into_three_ranges_without_other_getters(self):
        report = self.run_fixture('sparse')
        self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED', report)
        self.assertEqual(report['range_gets'], 3)
        self.assertEqual(report['scalar_gets'], 0)
        self.assertEqual(report['property_codes'], [int.from_bytes(b'ctnt', 'big')])

    def test_narrow_range_failure_uses_only_scalar_content_and_preserves_siblings(self):
        for mode, number, expected in [('fallback', -1708, 4), ('fallback', -1712, 4), ('unavailable', -1712, 3)]:
            with self.subTest(mode=mode, number=number):
                report = self.run_fixture(mode, number)
                self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED', report)
                self.assertEqual(report['range_attempts'], 4)
                self.assertEqual(report['range_gets'], 0)
                self.assertEqual(report['scalar_gets'], expected)
                self.assertEqual(report['property_codes'], [int.from_bytes(b'ctnt', 'big')])

    def test_permission_coercion_shape_and_size_do_not_retry(self):
        for mode, number, expected in [('fatal', -1743, -1743), ('fatal', -1700, -1700), ('fatal', -1728, -1728), ('shape', -1708, 9164), ('size', -1708, 9135)]:
            with self.subTest(mode=mode, number=number):
                report = self.run_fixture(mode, number)
                self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_FAILED', report)
                self.assertEqual(report['native_number'], expected)
                self.assertEqual(report['range_attempts'], 0)
                self.assertEqual(report['scalar_gets'], 0)


if __name__ == '__main__':
    unittest.main()
