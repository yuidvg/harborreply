"""Native script dispatch with a fictional self reader; never addresses Mail.

This exercises NSAppleScript's subroutine event entry point before any run
handler, including the shipping dispatcher's ``reader = me`` path. It does not
prove Mail understands the adapter's property/object-specifier events.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'Sources/HarborReply/Resources/MailBridge.applescript').read_text()


def handler(name):
    return re.search(rf'^on {name}\(.*?^end {name}$', SCRIPT, re.M | re.S).group(0)


PURE = '\n'.join(handler(name) for name in (
    'indexColumnValues', 'indexUsesRange', 'indexDisableRange'))
FIXTURE = '''
property indexUnsupportedColumns : {}
property readFailureStage : 0
property rangeCalls : 0
property scalarCalls : 0
property fixtureMode : "supported"
property fixtureError : -1728

on fixtureValue(positionValue)
    return "fixture.invalid-" & positionValue
end fixtureValue

on indexRangeColumn(b, firstIndex, lastIndex, stageNumber)
    set my readFailureStage to stageNumber
    set rangeCalls to rangeCalls + 1
    if fixtureMode is "range-failed" then error "FICTIONAL_FAILURE" number fixtureError
    if fixtureMode is "unsupported" or fixtureMode is "scalar-failed" then error "FICTIONAL_FAILURE" number -1708
    set columnValues to {}
    repeat with positionValue from firstIndex to lastIndex
        set end of columnValues to my fixtureValue(positionValue as integer)
    end repeat
    return columnValues
end indexRangeColumn

on indexScalarColumn(b, positionValue, stageNumber)
    set my readFailureStage to stageNumber + 130
    set scalarCalls to scalarCalls + 1
    if fixtureMode is "scalar-failed" then error "FICTIONAL_FAILURE" number fixtureError
    return my fixtureValue(positionValue)
end indexScalarColumn

on perform(operation, values)
    if operation is not "indexPage" then error "FICTIONAL_OPERATION" number 9131
    set fixtureMode to item 1 of values
    set fixtureError to item 2 of values
    set stageValue to item 3 of values
    try
        set firstValues to my indexColumnValues("mailbox.invalid", 1, 3, stageValue, me)
        set nextValues to my indexColumnValues("mailbox.invalid", 4, 6, stageValue, me)
        return {0, my readFailureStage, my rangeCalls, my scalarCalls, my indexUnsupportedColumns, firstValues, nextValues}
    on error number errorNumber
        return {errorNumber, my readFailureStage, my rangeCalls, my scalarCalls, my indexUnsupportedColumns, {}, {}}
    end try
end perform
'''

# These are the actual native engine's event class, ID and parameter keys.
# Source and arguments contain only the fixed fictional fixtures above.
HARNESS = r'''
import Foundation

func descriptorList(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let list = NSAppleEventDescriptor.list()
    for (offset, value) in values.enumerated() { list.insert(value, at: offset + 1) }
    return list
}

func numbers(_ value: NSAppleEventDescriptor) -> [Int] {
    if value.numberOfItems == 0 { return [] }
    return (1...value.numberOfItems).map { Int(value.atIndex($0)!.int32Value) }
}

func strings(_ value: NSAppleEventDescriptor) -> [String] {
    if value.numberOfItems == 0 { return [] }
    return (1...value.numberOfItems).map { value.atIndex($0)!.stringValue! }
}

let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
guard let script = NSAppleScript(source: source) else { exit(2) }
let mode = CommandLine.arguments[2]
let failureNumber = Int32(CommandLine.arguments[3])!
let requestCount = Int(CommandLine.arguments[4])!
let stageValue = Int32(CommandLine.arguments[5])!
var results: [[String: Any]] = []
for _ in 0..<requestCount {
    // No executeAndReturnError/run invocation precedes this subroutine event.
    let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272,
        targetDescriptor: nil, returnID: -1, transactionID: 0)
    event.setParam(NSAppleEventDescriptor(string: "perform"), forKeyword: 0x736E616D)
    let arguments = descriptorList([
        NSAppleEventDescriptor(string: "indexPage"),
        descriptorList([NSAppleEventDescriptor(string: mode), NSAppleEventDescriptor(int32: failureNumber), NSAppleEventDescriptor(int32: stageValue)])
    ])
    event.setParam(arguments, forKeyword: 0x2D2D2D2D)
    var error: NSDictionary?
    let result = script.executeAppleEvent(event, error: &error)
    if let error {
        // Native descriptions can contain variable data; never return them.
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        results.append(["engine_error": number])
        break
    }
    guard result.numberOfItems == 7 else { exit(3) }
    results.append([
        "error_number": Int(result.atIndex(1)!.int32Value),
        "stage": Int(result.atIndex(2)!.int32Value),
        "range_calls": Int(result.atIndex(3)!.int32Value),
        "scalar_calls": Int(result.atIndex(4)!.int32Value),
        "disabled_columns": numbers(result.atIndex(5)!),
        "first_values": strings(result.atIndex(6)!),
        "next_values": strings(result.atIndex(7)!)
    ])
}
let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''


class SelfReaderFixtureSafetyTests(unittest.TestCase):
    def test_native_harness_cannot_address_mail_or_execute_a_run_handler(self):
        self.assertNotIn('tell application', PURE + FIXTURE)
        self.assertNotIn('executeAndReturnError(', HARNESS)
        self.assertNotIn('NSWorkspace', HARNESS)
        self.assertIn('stageValue, me)', FIXTURE)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'host macOS/Xcode harness unavailable in sandbox or empty PATH')
class NativeSelfReaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='harborreply-self-reader-')
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = pathlib.Path(cls.temporary.name)
        cls.source_path = directory / 'fictional.applescript'
        cls.source_path.write_text(FIXTURE + '\n' + PURE)
        swift_path = directory / 'harness.swift'
        swift_path.write_text(HARNESS)
        cls.binary = directory / 'harness'
        result = subprocess.run([shutil.which('xcrun'), 'swiftc', str(swift_path),
                                 '-o', str(cls.binary)], text=True, capture_output=True, timeout=45)
        if result.returncode:
            raise AssertionError('Fictional native harness compilation failed: ' + result.stderr)

    def run_fixture(self, mode, number=-1728, requests=1, stage=9171):
        result = subprocess.run([str(self.binary), str(self.source_path), mode,
                                 str(number), str(requests), str(stage)], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)
        self.assertEqual(len(rows), requests)
        for row in rows:
            self.assertNotIn('engine_error', row)
        return rows

    def assert_order(self, row):
        self.assertEqual(row['first_values'], ['fixture.invalid-1', 'fixture.invalid-2', 'fixture.invalid-3'])
        self.assertEqual(row['next_values'], ['fixture.invalid-4', 'fixture.invalid-5', 'fixture.invalid-6'])

    def test_self_handler_and_properties_work_without_running_script_first(self):
        rows = self.run_fixture('supported', requests=2)
        for request, row in enumerate(rows, start=1):
            self.assert_order(row)
            self.assertEqual(row['error_number'], 0)
            self.assertEqual(row['stage'], 9301)
            self.assertEqual(row['range_calls'], 0)
            self.assertEqual(row['scalar_calls'], request * 6)
            self.assertEqual(row['disabled_columns'], [])

    def test_self_reader_fallback_capability_cache_survives_native_subroutine_calls(self):
        rows = self.run_fixture('unsupported', requests=2, stage=9172)
        for request, row in enumerate(rows, start=1):
            self.assert_order(row)
            self.assertEqual(row['error_number'], 0)
            self.assertEqual(row['stage'], 9302)
            self.assertEqual(row['range_calls'], 1)
            self.assertEqual(row['scalar_calls'], request * 6)
            self.assertEqual(row['disabled_columns'], [9172])

    def test_other_range_failures_preserve_number_and_stage_without_scalar_reads(self):
        for number in (-1743, -1728, -1700, -1712):
            with self.subTest(number=number):
                row = self.run_fixture('range-failed', number, stage=9172)[0]
                self.assertEqual(row['error_number'], number)
                self.assertEqual(row['stage'], 9172)
                self.assertEqual(row['range_calls'], 1)
                self.assertEqual(row['scalar_calls'], 0)
                self.assertEqual(row['disabled_columns'], [])

    def test_scalar_failure_preserves_number_and_stage_without_recursing(self):
        for number in (-1743, -1728, -1708, -1700, -1712):
            with self.subTest(number=number):
                row = self.run_fixture('scalar-failed', number)[0]
                self.assertEqual(row['error_number'], number)
                self.assertEqual(row['stage'], 9301)
                self.assertEqual(row['range_calls'], 0)
                self.assertEqual(row['scalar_calls'], 1)
                self.assertEqual(row['disabled_columns'], [])
