"""Exercise shipping adapter Apple events against an in-process fictional recipient.

Target and dictionary words become current-application/literal public class codes.
Native IDs always use scalar GETs. Other-property fallback cases inject -1708
before the range getter: OSA treats an unhandled self-addressed event specially
and otherwise changes it to -1728. The shipping scalar adapter still executes
real core/getd events against our recipient. This does not reproduce an actual
Mail failure. No Mail/archive/credentials/body is read.
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
SOURCE = (ROOT / 'Sources/HarborReply/Resources/MailBridge.applescript').read_text()
NATIVE_AVAILABLE = sys.platform == 'darwin' and shutil.which('swiftc') is not None


def handler(name):
    return re.search(rf'^on {name}\(.*?^end {name}$', SOURCE, re.M | re.S).group(0)


def fixture_source(rows, old_object_get=False, stage=0, reject_range=False):
    names = ('bodyMetricGet', 'indexColumnValues', 'indexUsesRange', 'indexDisableRange',
             'indexRangeColumn', 'indexScalarColumn')
    source = '\n'.join(handler(name) for name in names)
    # A deliberately rejected fixture range selects the shipping fallback; all
    # scalar property and accidental object reads remain real native events.
    source = source.replace('on indexRangeColumn(b, firstIndex, lastIndex, stageNumber)\n',
                            'on indexRangeColumn(b, firstIndex, lastIndex, stageNumber)\n'
                            '    set my fixtureRangeAttempts to my fixtureRangeAttempts + 1\n'
                            '    if my fixtureRejectRange then error "FICTIONAL_UNSUPPORTED_RANGE" number -1708\n')
    if old_object_get:
        source = source.replace('a reference to «class mssg» messagePosition of b',
                                '«class mssg» messagePosition of b')
    source = source.replace('tell application "Mail"', 'tell current application')
    # The installed Mail.sdef exposes these fixed, public terminology codes.
    # Literal codes avoid loading or referring to Mail even during compilation.
    for word, code in [('message id', 'meid'), ('message size', 'msze'),
                       ('date sent', 'drcv'), ('date received', 'rdrc'),
                       ('messages', 'mssg'), ('subject', 'subj'), ('sender', 'sndr'),
                       ('id', 'ID  ')]:
        source = re.sub(r'\b' + word + r'\b', '«class ' + code + '»', source)
    assert 'application "Mail"' not in source
    stage_sequence = str(stage) if stage else '9171, 9172, 9173, 9174, 9175, 9176, 9177, 9171'
    return '''property readFailureStage : 0
property bodyMetricPhaseValue : 0
property bodyMetricGets : {0,0,0,0}
property indexUnsupportedColumns : {}
property fixtureRangeAttempts : 0
property fixtureRejectRange : ''' + str(reject_range).lower() + '''
''' + source + f'''
on perform()
    tell current application to set b to a reference to «class mbxp» "Fictional Sent"
    try
        repeat with pageNumber from 0 to 1
            set firstPosition to pageNumber * {rows} + 1
            set lastPosition to firstPosition + {rows} - 1
            repeat with stageRef in {{{stage_sequence}}}
                set stageValue to stageRef as integer
                set values to my indexColumnValues(b, firstPosition, lastPosition, stageValue, me)
                if (count of values) is not {rows} then error "FICTIONAL_ROW_COUNT" number 9991
                repeat with rowPosition from 1 to {rows}
                    set positionValue to firstPosition + rowPosition - 1
                    set actualValue to item rowPosition of values
                    if stageValue is 9171 and actualValue is not positionValue then error "FICTIONAL_ID_ORDER" number 9992
                    if stageValue is 9172 and actualValue is not "message-" & positionValue & "@fixture.invalid" then error "FICTIONAL_HEADER_ID" number 9993
                    if stageValue is 9173 and actualValue is not "Fictional subject " & positionValue then error "FICTIONAL_SUBJECT" number 9994
                    if stageValue is 9174 and actualValue is not "sender@fixture.invalid" then error "FICTIONAL_SENDER" number 9995
                    if (stageValue is 9175 or stageValue is 9176) and class of actualValue is not date then error "FICTIONAL_DATE" number 9996
                    if stageValue is 9177 and actualValue is not 42 then error "FICTIONAL_SIZE" number 9997
                end repeat
            end repeat
        end repeat
        return {{"FICTIONAL_NATIVE_ADAPTER_PASSED", 0, 0, my fixtureRangeAttempts}}
    on error number errorNumber
        return {{"FICTIONAL_NATIVE_ADAPTER_FAILED", errorNumber, my readFailureStage, my fixtureRangeAttempts}}
    end try
end perform
'''


SWIFT_RECIPIENT = r'''
import AppKit

func code(_ text: String) -> UInt32 {
    text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}
func field(_ descriptor: NSAppleEventDescriptor, _ name: String) -> NSAppleEventDescriptor? {
    descriptor.paramDescriptor(forKeyword: code(name))
}
final class FictionalRecipient: NSObject {
    let mode: String
    let nativeFailure: Int32
    var rangeGets = 0
    var scalarGets = 0
    var bareMessageGets = 0
    var unexpectedEvents = 0
    var propertyCodes: Set<UInt32> = []
    var rangePropertyCodes: Set<UInt32> = []
    init(mode: String, nativeFailure: Int32) { self.mode = mode; self.nativeFailure = nativeFailure }
    func fail(_ reply: NSAppleEventDescriptor, _ number: Int32) {
        reply.setParam(NSAppleEventDescriptor(int32: number), forKeyword: code("errn"))
    }
    func position(_ descriptor: NSAppleEventDescriptor) -> Int32? {
        guard field(descriptor, "want")?.typeCodeValue == code("mssg"),
              field(descriptor, "form")?.typeCodeValue == code("indx"),
              let selection = field(descriptor, "seld") else { return nil }
        return selection.int32Value
    }
    func value(_ property: UInt32, _ position: Int32) -> NSAppleEventDescriptor? {
        switch property {
        case code("ID  "): return NSAppleEventDescriptor(int32: position)
        case code("meid"): return NSAppleEventDescriptor(string: "message-\(position)@fixture.invalid")
        case code("subj"): return NSAppleEventDescriptor(string: "Fictional subject \(position)")
        case code("sndr"): return NSAppleEventDescriptor(string: "sender@fixture.invalid")
        case code("drcv"), code("rdrc"): return NSAppleEventDescriptor(date: Date(timeIntervalSince1970: 0))
        case code("msze"): return NSAppleEventDescriptor(int32: 42)
        default: return nil
        }
    }
    @objc func getData(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: code("----")),
              let want = field(direct, "want") else {
            unexpectedEvents += 1; fail(replyEvent, 9981); return
        }
        if want.typeCodeValue == code("mssg") {
            bareMessageGets += 1
            if mode == "scalar-supported-objects" {
                replyEvent.setParam(direct, forKeyword: code("----")); return
            }
            // This deliberately unsupported object fetch exposes the old adapter.
            fail(replyEvent, -1728); return
        }
        guard want.typeCodeValue == code("prop"),
              field(direct, "form")?.typeCodeValue == code("prop"),
              let property = field(direct, "seld")?.typeCodeValue,
              let from = field(direct, "from") else {
            unexpectedEvents += 1; fail(replyEvent, 9982); return
        }
        propertyCodes.insert(property)
        guard field(from, "want")?.typeCodeValue == code("mssg") else {
            unexpectedEvents += 1; fail(replyEvent, 9983); return
        }
        if field(from, "form")?.typeCodeValue == code("rang") {
            rangeGets += 1
            rangePropertyCodes.insert(property)
            if mode == "native-range-failure" { fail(replyEvent, nativeFailure); return }
            if mode != "supported" { fail(replyEvent, -1708); return }
            guard let bounds = field(from, "seld"),
                  let startDescriptor = field(bounds, "star"),
                  let endDescriptor = field(bounds, "stop"),
                  let start = position(startDescriptor), let end = position(endDescriptor),
                  start >= 1, end >= start, end - start < 128 else {
                unexpectedEvents += 1; fail(replyEvent, 9984); return
            }
            let result = NSAppleEventDescriptor.list()
            for index in start...end {
                guard let item = value(property, index) else {
                    unexpectedEvents += 1; fail(replyEvent, 9985); return
                }
                result.insert(item, at: Int(index - start + 1))
            }
            replyEvent.setParam(result, forKeyword: code("----")); return
        }
        scalarGets += 1
        if mode == "native-scalar-failure" { fail(replyEvent, nativeFailure); return }
        guard let index = position(from), index >= 1, let item = value(property, index) else {
            unexpectedEvents += 1; fail(replyEvent, 9986); return
        }
        replyEvent.setParam(item, forKeyword: code("----"))
    }
    @objc func unexpected(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        unexpectedEvents += 1; fail(replyEvent, 9987)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let args = CommandLine.arguments
let recipient = FictionalRecipient(mode: args[2], nativeFailure: Int32(args[3])!)
let manager = NSAppleEventManager.shared()
manager.setEventHandler(recipient, andSelector: #selector(FictionalRecipient.getData(_:replyEvent:)), forEventClass: code("core"), andEventID: code("getd"))
manager.setEventHandler(recipient, andSelector: #selector(FictionalRecipient.unexpected(_:replyEvent:)), forEventClass: code("ascr"), andEventID: code("psbr"))
let source = try String(contentsOfFile: args[1], encoding: .utf8)
let script = NSAppleScript(source: source)!
let event = NSAppleEventDescriptor(eventClass: code("ascr"), eventID: code("psbr"), targetDescriptor: nil, returnID: -1, transactionID: 0)
event.setParam(NSAppleEventDescriptor(string: "perform"), forKeyword: code("snam"))
event.setParam(NSAppleEventDescriptor.list(), forKeyword: code("----"))
var error: NSDictionary?
let result = script.executeAppleEvent(event, error: &error)
let report: [String: Any] = [
    "status": result.atIndex(1)?.stringValue ?? "FICTIONAL_SCRIPT_ERROR",
    "native_number": result.atIndex(2)?.int32Value ?? 0,
    "stage": result.atIndex(3)?.int32Value ?? 0,
    "range_attempts": result.atIndex(4)?.int32Value ?? 0,
    "execution_error_number": error?[NSAppleScript.errorNumber] as? Int ?? 0,
    "range_gets": recipient.rangeGets, "scalar_gets": recipient.scalarGets,
    "bare_message_gets": recipient.bareMessageGets,
    "unexpected_events": recipient.unexpectedEvents,
    "property_codes": recipient.propertyCodes.sorted(),
    "range_property_codes": recipient.rangePropertyCodes.sorted(),
    "real_mail_events_executed": false
]
let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
'''


class NativeAdapterSourceTests(unittest.TestCase):
    def test_fixture_never_addresses_mail_and_keeps_public_getter_codes(self):
        generated = fixture_source(128)
        self.assertNotIn('application "Mail"', generated)
        self.assertNotRegex(generated, r'\b(?:content|source|all headers|properties|whose|every message|mail attachments)\b')
        self.assertIn('a reference to «class mssg» messagePosition of b', generated)
        for code in ('ID  ', 'meid', 'subj', 'sndr', 'drcv', 'rdrc', 'msze'):
            self.assertIn('«class ' + code + '»', generated)


@unittest.skipUnless(NATIVE_AVAILABLE, 'host Swift/AppKit runtime unavailable')
class NativeAdapterEventTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='harborreply fictional native events ')
        cls.root = pathlib.Path(cls.directory.name)
        host = cls.root / 'recipient.swift'
        host.write_text(SWIFT_RECIPIENT)
        cls.binary = cls.root / 'recipient'
        result = subprocess.run([shutil.which('swiftc'), str(host), '-o', str(cls.binary)],
                                text=True, capture_output=True, timeout=45)
        if result.returncode:
            cls.directory.cleanup()
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_recipient(self, mode, rows=128, old_object_get=False, number=-1708, stage=0):
        source = self.root / 'adapter.applescript'
        reject_range = mode in ('unsupported', 'native-scalar-failure', 'scalar-supported-objects')
        source.write_text(fixture_source(rows, old_object_get, stage, reject_range))
        result = subprocess.run([str(self.binary), str(source), mode, str(number)],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['execution_error_number'], 0)
        self.assertEqual(report['unexpected_events'], 0)
        self.assertFalse(report['real_mail_events_executed'])
        self.assertNotIn(int.from_bytes(b'ID  ', 'big'), report['range_property_codes'])
        return report

    def test_old_eager_object_get_stops_before_property_then_reference_passes(self):
        old = self.run_recipient('unsupported', rows=1, old_object_get=True, stage=9171)
        self.assertEqual(old['status'], 'FICTIONAL_NATIVE_ADAPTER_FAILED')
        self.assertEqual(old['native_number'], -1728)
        self.assertEqual(old['stage'], 9301)
        self.assertEqual((old['range_gets'], old['bare_message_gets'], old['scalar_gets']), (0, 1, 0))
        self.assertEqual(old['range_attempts'], 0)
        new = self.run_recipient('unsupported', rows=1, stage=9171)
        self.assertEqual(new['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED')
        self.assertEqual((new['range_gets'], new['bare_message_gets'], new['scalar_gets']), (0, 0, 2))
        self.assertEqual(new['range_attempts'], 0)
        # When the recipient supports both operations, each old scalar value
        # requires an object GET followed by a property GET; the patch needs one.
        old_supported = self.run_recipient('scalar-supported-objects', rows=1,
                                           old_object_get=True, stage=9171)
        new_supported = self.run_recipient('scalar-supported-objects', rows=1, stage=9171)
        for report in (old_supported, new_supported):
            self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED')
            self.assertEqual((report['range_gets'], report['scalar_gets']), (0, 2))
        self.assertEqual(old_supported['bare_message_gets'], 2)
        self.assertEqual(new_supported['bare_message_gets'], 0)

    def test_supported_range_preserves_native_class_property_order_and_bounds(self):
        for rows in (1, 128):
            with self.subTest(rows=rows):
                report = self.run_recipient('supported', rows=rows)
                self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED')
                self.assertEqual((report['range_gets'], report['bare_message_gets'], report['scalar_gets']), (12, 0, rows * 4))
                self.assertEqual(len(report['property_codes']), 7)
                self.assertEqual(len(report['range_property_codes']), 6)

    def test_all_scalar_columns_native_events_are_bounded_and_capability_is_cached(self):
        for rows in (1, 128):
            with self.subTest(rows=rows):
                report = self.run_recipient('unsupported', rows=rows)
                self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_PASSED')
                self.assertEqual((report['range_gets'], report['bare_message_gets'], report['scalar_gets']), (0, 0, rows * 16))
                self.assertEqual(report['range_attempts'], 6)
                self.assertEqual(len(report['property_codes']), 7)

    def test_other_native_range_errors_never_fall_back_or_acquire_objects(self):
        for number in (-1743, -1728, -1700, -1712):
            with self.subTest(number=number):
                report = self.run_recipient('native-range-failure', number=number, stage=9172)
                self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_FAILED')
                self.assertEqual((report['native_number'], report['stage']), (number, 9172))
                self.assertEqual((report['range_gets'], report['bare_message_gets'], report['scalar_gets']), (1, 0, 0))

    def test_each_scalar_getter_retains_its_native_error_and_distinct_stage(self):
        for stage in range(9171, 9178):
            with self.subTest(stage=stage):
                report = self.run_recipient('native-scalar-failure', stage=stage, number=-1743)
                self.assertEqual(report['status'], 'FICTIONAL_NATIVE_ADAPTER_FAILED')
                self.assertEqual((report['native_number'], report['stage']), (-1743, stage + 130))
                self.assertEqual((report['range_gets'], report['bare_message_gets'], report['scalar_gets']), (0, 0, 1))
                self.assertEqual(report['range_attempts'], 0 if stage == 9171 else 1)


if __name__ == '__main__':
    unittest.main()
