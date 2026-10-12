"""Execute shipping bounded bulk orchestration with test-only native recipients.

No Mail process, Mail archive, credentials or owner application state is read.
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


NAMES = ('strictEqual', 'mailText', 'mailDate', 'metadataValues',
         'bodyMetricNow', 'bodyMetricBegin', 'bodyMetricPhase', 'bodyMetricGet', 'bodyMetricResult',
         'indexUsesRange', 'indexDisableRange', 'indexColumnValues', 'indexRangeColumn', 'indexScalarColumn',
         'bodyRangeColumn', 'bodyCheckpoint', 'bodyColumnTexts', 'bodyValidateRows',
         'indexHydrateBatch', 'bodyHydrateDispatch')


def fixture_source(mode='supported', rows=4, number=-1708):
    code = '\n'.join(handler(name) for name in NAMES)
    # AppleScriptObjC changes current-application dispatch into Objective-C;
    # substitute only the clock for this self-addressed native recipient.
    code = code.replace(handler('bodyMetricNow'), 'on bodyMetricNow()\n    return 0.0\nend bodyMetricNow')
    code = code.replace('tell application "Mail"', 'tell current application')
    for word, public in [('all headers', 'alhe'), ('message id', 'meid'), ('message size', 'msze'),
                         ('date sent', 'drcv'), ('date received', 'rdrc'), ('messages', 'mssg'),
                         ('content', 'ctnt'), ('subject', 'subj'), ('sender', 'sndr'), ('id', 'ID  ')]:
        code = re.sub(r'\b' + word + r'\b', '«class ' + public + '»', code)
    code = code.replace('on bodyRangeColumn(b, firstIndex, lastIndex, stageNumber)\n',
                        'on bodyRangeColumn(b, firstIndex, lastIndex, stageNumber)\n'
                        '    if my fixtureMode is "unsupported" then\n'
                        '        set my readFailureStage to stageNumber\n'
                        '        error "TEST_ONLY_UNSUPPORTED" number -1708\n'
                        '    end if\n')
    code = code.replace('set values to reader\'s indexColumnValues(b, firstIndex, lastIndex, stageNumber, reader)',
                        'set values to reader\'s indexColumnValues(b, firstIndex, lastIndex, stageNumber, reader)\n'
                        '        if my fixtureMode is "reordered" and stageNumber is 9171 then set values to reverse of values\n'
                        '        if my fixtureMode is "short" and stageNumber is 9172 then set values to {}\n'
                        '        if my fixtureMode is "changed" and stageNumber is 9173 and my fixtureCheckpoint > 1 then set item 1 of values to "Changed fictional subject"')
    # Count races are caught by the shipping checkpoint before another GET.
    code = code.replace('set rowCount to count of expectedRows\n    set lastIndex',
                        'set my fixtureCheckpoint to my fixtureCheckpoint + 1\n'
                        '    set rowCount to count of expectedRows\n    set lastIndex', 1)
    code = code.replace('set my readFailureStage to stageNumber\n    my bodyMetricGet()',
                        'set my readFailureStage to stageNumber\n'
                        '    if my fixtureMode is "native-error" then error "TEST_ONLY_ERROR" number ' + str(number) + '\n'
                        '    my bodyMetricGet()', 1)
    return '''property readFailureStage : 0
property indexUnsupportedColumns : {}
property bodyMetricPhaseValue : 0
property bodyMetricStarted : 0.0
property bodyMetricTimes : {0,0,0,0}
property bodyMetricGets : {0,0,0,0}
property fixtureCheckpoint : 0
property fixtureFallbacks : 0
property fixtureDisabled : false
property fixtureMode : "''' + mode + '''"
''' + code + f'''
on bodyScope(expectedRows)
    tell current application to return a reference to «class mbxp» "Fictional Sent"
end bodyScope
on bodyMessageCount(b)
    if my fixtureMode is "count-changed" and my fixtureCheckpoint > 1 then return {rows+1}
    return {rows}
end bodyMessageCount
on bodyMessageBox(b, messagePosition)
    if my fixtureMode is "wrong-box" then return "Different fictional box"
    return b
end bodyMessageBox
on bodyAttachmentCount(b, messagePosition)
    if my fixtureMode is "attachments-changed" and my fixtureCheckpoint > 1 then return 1
    return 0
end bodyAttachmentCount
on bodyRangeEnabled()
    return not my fixtureDisabled
end bodyRangeEnabled
on bodyDisableRange(stageNumber)
    set my fixtureDisabled to true
end bodyDisableRange
on bodyScalarHydrate(expectedRows)
    set my fixtureFallbacks to my fixtureFallbacks + 1
    return {{}}
end bodyScalarHydrate
on perform()
    set expectedRows to {{}}
    repeat with p from 1 to {rows}
        set end of expectedRows to {{"fixture-account", {{"Fictional Sent"}}, p as text, "message-" & p & "@fixture.invalid", "Fictional subject " & p, "sender@fixture.invalid", missing value, missing value, "42", "sent", false, "fixture-scan"}}
    end repeat
    try
        set resultValue to my bodyHydrateDispatch(expectedRows, 1, {rows}, me)
        if my fixtureMode is "unsupported" then
            set ignored to my bodyHydrateDispatch(expectedRows, 1, {rows}, me)
            if my fixtureFallbacks is not 2 then error "TEST_ONLY_FALLBACK_COUNT" number 9991
        else
            if (count of item 2 of resultValue) is not {rows} then error "TEST_ONLY_ROW_COUNT" number 9992
            repeat with p from 1 to {rows}
                set rowValue to item p of item 2 of resultValue
                if item 2 of rowValue is not "Fictional body " & p then error "TEST_ONLY_BODY_ORDER" number 9993
                if item 3 of rowValue is not "Message-ID: message-" & p & "@fixture.invalid" then error "TEST_ONLY_HEADERS_ORDER" number 9994
            end repeat
        end if
        return {{"FICTIONAL_NATIVE_ADAPTER_PASSED", 0, 0, my fixtureFallbacks}}
    on error number errorNumber
        return {{"FICTIONAL_NATIVE_ADAPTER_FAILED", errorNumber, my readFailureStage, my fixtureFallbacks}}
    end try
end perform
'''


RECIPIENT = SWIFT_RECIPIENT.replace(
    'case code("msze"): return NSAppleEventDescriptor(int32: 42)',
    'case code("msze"): return NSAppleEventDescriptor(int32: 42)\n'
    '        case code("ctnt"): return NSAppleEventDescriptor(string: "Fictional body \\(position)")\n'
    '        case code("alhe"): return NSAppleEventDescriptor(string: "Message-ID: message-\\(position)@fixture.invalid")')
RECIPIENT = RECIPIENT.replace('NSAppleEventDescriptor(date: Date(timeIntervalSince1970: 0))',
                              'NSAppleEventDescriptor(typeCode: code("msng"))')


class BodyBulkSourceTests(unittest.TestCase):
    def test_fixture_cannot_address_real_mail(self):
        source = fixture_source()
        self.assertNotIn('application "Mail"', source)
        self.assertNotIn('~/Library/Mail', source)
        self.assertIn('return get «class ctnt» of («class mssg» firstIndex thru lastIndex of b)', source)
        self.assertIn('return get «class alhe» of («class mssg» firstIndex thru lastIndex of b)', source)
        self.assertNotRegex(handler('indexHydrateBatch'), r'\b(?:source|properties|whose|every message)\b')
        self.assertIn('strictEqual(beforeCheckpoint, afterCheckpoint)', handler('indexHydrateBatch'))

    @unittest.skipUnless(shutil.which('osascript'), 'host pure AppleScript interpreter unavailable')
    def test_shipping_cache_validation_checks_two_snapshots_without_body_gets(self):
        names = ('strictEqual', 'bodyMetricBegin', 'bodyMetricPhase', 'bodyMetricGet', 'bodyMetricResult', 'validateCachedRows')
        source = '\n'.join(handler(name) for name in names)
        # Only side-effect dependencies are replaced. The shipping checkpoint
        # orchestration and strict before/after comparisons execute unchanged.
        source = source.replace('tell application "Mail" to set m to a reference to «class mssg» id requestedID of b', 'set m to requestedID')
        source = source.replace('tell application "Mail" to set firstAttachments to count of mail attachments of m', 'set firstAttachments to my fixtureAttachments(rowIndex)')
        source = source.replace('tell application "Mail" to set secondAttachments to count of mail attachments of m', 'set secondAttachments to my fixtureAttachments(rowIndex)')
        self.assertNotIn('tell application', source)
        self.assertNotRegex(source, r'\b(?:get content|all headers|properties|source of)\b')
        dependencies = '''
property readFailureStage : 0
property bodyMetricPhaseValue : 0
property bodyMetricStarted : 0.0
property bodyMetricTimes : {0,0,0,0}
property bodyMetricGets : {0,0,0,0}
property fixtureMode : "MODE"
property metadataCalls : 0
property scopeCalls : 0
on bodyMetricNow()
    return 0.0
end bodyMetricNow
on bodyScope(rows)
    set scopeCalls to scopeCalls + 1
    if fixtureMode is "scope" and scopeCalls > 1 then return "Different fictional box"
    return "Fictional box"
end bodyScope
on bodyMessageCount(b)
    if fixtureMode is "count" and scopeCalls > 1 then return 3
    return 2
end bodyMessageCount
on bodyDirectMetadata(m, b, expectedRow)
    set metadataCalls to metadataCalls + 1
    if fixtureMode is "not-found" and m is 1 then error "TEST_ONLY_MISSING" number -1728
    if fixtureMode is "permission" then error "TEST_ONLY_PERMISSION" number -1743
    copy expectedRow to actualRow
    if fixtureMode is "metadata" and metadataCalls is 2 then set item 5 of actualRow to "Changed fictional subject"
    return actualRow
end bodyDirectMetadata
on fixtureAttachments(rowIndex)
    if fixtureMode is "attachments" and rowIndex is 1 then return 1
    return 0
end fixtureAttachments
'''
        call = '''
set rows to {{"fixture-account", {"Sent"}, "1", "1@fixture.invalid", "Fictional first", "author@fixture.invalid", missing value, missing value, "42", "sent", false, "fixture-scan"}, {"fixture-account", {"Sent"}, "2", "2@fixture.invalid", "Fictional second", "author@fixture.invalid", missing value, missing value, "42", "sent", false, "fixture-scan"}}
try
    set resultValue to my validateCachedRows(rows, {0,0})
    set flags to item 2 of resultValue
    return (item 1 of flags as text) & "," & (item 2 of flags as text)
on error number errorNumber
    return "ERROR_" & errorNumber
end try
'''
        for mode, expected in [('valid','true,true'), ('metadata','false,true'), ('attachments','false,true'),
                               ('not-found','false,true'), ('scope','false,false'), ('count','false,false'), ('permission','ERROR_-1743')]:
            with self.subTest(mode=mode):
                response = subprocess.run([shutil.which('osascript'), '-'], input=dependencies.replace('"MODE"','"'+mode+'"')+source+call,
                    text=True, capture_output=True, timeout=10)
                self.assertEqual(response.returncode,0,response.stderr)
                self.assertEqual(response.stdout.strip(), expected)


@unittest.skipUnless(AVAILABLE, 'host Swift/AppKit runtime unavailable')
class BodyBulkNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='harbor-bulk-fixture-')
        cls.root = pathlib.Path(cls.directory.name)
        source = cls.root / 'recipient.swift'; source.write_text(RECIPIENT)
        cls.binary = cls.root / 'recipient'
        built = subprocess.run([shutil.which('swiftc'), str(source), '-o', str(cls.binary)],
                               text=True, capture_output=True, timeout=45)
        if built.returncode:
            cls.directory.cleanup(); raise AssertionError(built.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_fixture(self, mode='supported', rows=4, number=-1708):
        source = self.root / 'bulk.applescript'; source.write_text(fixture_source(mode, rows, number))
        result = subprocess.run([str(self.binary), str(source), 'supported', str(number)],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['execution_error_number'], 0, report)
        self.assertEqual(report['unexpected_events'], 0, report)
        self.assertFalse(report['real_mail_events_executed'])
        return report

    def test_actual_bulk_columns_and_scalar_id_witnesses_use_bounded_native_events(self):
        for rows in (1, 4):
            with self.subTest(rows=rows):
                report = self.run_fixture(rows=rows)
                self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED', report)
                self.assertEqual(report['range_gets'], 14)  # 6 metadata columns twice + body + headers
                self.assertEqual(report['scalar_gets'], 2 * rows)
                self.assertEqual(report['bare_message_gets'], 0)
                self.assertEqual(report['range_attempts'], 0)
                self.assertNotIn(int.from_bytes(b'ID  ', 'big'), report['range_property_codes'])
                self.assertIn(int.from_bytes(b'ctnt', 'big'), report['range_property_codes'])
                self.assertIn(int.from_bytes(b'alhe', 'big'), report['range_property_codes'])

    def test_changed_order_count_metadata_mailbox_and_attachments_never_fall_back(self):
        for mode, code in [('reordered', 9132), ('short', 9134), ('changed', 9132),
                           ('count-changed', 9130), ('wrong-box', 9132), ('attachments-changed', 9132)]:
            with self.subTest(mode=mode):
                report = self.run_fixture(mode)
                self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_FAILED', report)
                self.assertEqual(report['native_number'], code, report)
                self.assertEqual(report['range_attempts'], 0, report)

    def test_native_unsupported_body_range_only_falls_back_and_is_cached(self):
        report = self.run_fixture('unsupported')
        self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED', report)
        self.assertEqual(report['range_attempts'], 2, report)
        self.assertEqual(report['range_gets'], 6)  # No second compatibility probe or headers/body request.

    def test_other_native_errors_never_select_scalar_fallback(self):
        for number in (-1743, -1700, -1728, -1712):
            with self.subTest(number=number):
                report = self.run_fixture('native-error', number=number)
                self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_FAILED', report)
                self.assertEqual(report['native_number'], number, report)
                self.assertEqual(report['range_attempts'], 0, report)


if __name__ == '__main__':
    unittest.main()
