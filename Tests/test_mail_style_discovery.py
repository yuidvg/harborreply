"""Static contracts and pure AppleScript values; no Mail handler/event/data."""
import pathlib
import re
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'Sources/HarborReply/Resources/MailBridge.applescript').read_text()


def handler(name):
    return re.search(rf'^on {name}\(.*?^end {name}$', SCRIPT, re.M | re.S).group(0)


class MailStyleDiscoveryTests(unittest.TestCase):
    def test_account_discovery_reads_only_enabled_identity_choices(self):
        source = handler('styleAccountIdentities')
        self.assertIn('accountCount > 32', source)
        self.assertIn('get email addresses of a', source)
        self.assertIn('if rawEnabled then', source)
        self.assertIn('afterCount is not accountCount', source)
        self.assertNotRegex(source, r'\b(?:messages|content|all headers|selection|password|user name|account directory)\b')

    def test_sent_discovery_uses_genuine_role_and_bounded_container_path(self):
        source = handler('styleSentMailboxes')
        self.assertIn('set sentRoot to sent mailbox', source)
        self.assertIn('scopedRoleMailbox(sentRoot, accountID)', source)
        self.assertIn('styleSentPath(actualSent, accountID, sentRoot, me)', source)
        self.assertIn('repeat with depthIndex from 1 to 32', handler('styleSentPath'))
        self.assertIn('get container of b', handler('stylePathParent'))
        self.assertIn('strictEqual(resolvedSent, actualSent)', source)
        self.assertNotRegex(source, r'\b(?:sender|content|all headers|whose|every message)\b')
        self.assertNotRegex(source, r'(?im)^\s*(send|delete|move|make|set (?:enabled|read status|password) of)\b')

    def test_selection_dereferences_item_and_separates_getters_and_coercion(self):
        source = handler('captureSelected')
        self.assertIn('contents of item 1 of chosen', source)
        self.assertIn('get mailbox of m', source)
        self.assertIn('get account of selectedMailbox', source)
        self.assertIn('mailText(rawHeaderID, false, 9172)', source)
        self.assertNotIn('id of account of mailbox of m as text', source)

    def test_errors_are_stage_codes_without_private_apple_error_text(self):
        self.assertIn('return my mailFailureEnvelope(errorNumber, my readFailureStage)', handler('perform'))
        self.assertIn('stageNumber + 100', handler('mailFailureEnvelope'))
        self.assertIn('return {"HARBOR_MAIL_FAILURE_V1", reportedNumber, stageNumber}', handler('mailFailureEnvelope'))
        self.assertNotRegex(handler('perform'), r'(?m)^\s*error ignoredText\b')
        self.assertNotIn('ignoredText', handler('mailFailureEnvelope'))

    def test_metadata_columns_and_body_getters_have_fixed_distinct_stages(self):
        page = handler('indexHeaderPage')
        for stage, variable in [(9171, 'nativeIDs'), (9172, 'messageIDs'), (9173, 'subjects'),
                                (9174, 'senders'), (9175, 'sentDates'), (9176, 'receivedDates'), (9177, 'sizes')]:
            self.assertIn(f'set {variable} to my indexColumnValues(b, firstIndex, lastIndex, {stage}, me)', page)
            self.assertIn(f'if stageNumber is {stage} then return get ', handler('indexRangeColumn'))
            self.assertIn(f'if stageNumber is {stage} then return get ', handler('indexScalarColumn'))
        self.assertIn('my metadataValues(', page)
        values = handler('metadataValues')
        self.assertIn('mailText(rawSubject, false, 9173)', values)
        self.assertIn('mailDate(rawReceivedDate, 9176)', values)
        hydration = re.sub(r'(?m)^\s*my bodyMetric(?:Phase\([1-4]\)|Get\(\))\s*$', '', handler('indexHydrate'))
        self.assertRegex(hydration, r'set my readFailureStage to 9188\s+tell application "Mail" to set m to')
        self.assertRegex(hydration, r'set my readFailureStage to 9164\s+set rawBody to get content')
        self.assertRegex(hydration, r'set my readFailureStage to 9165\s+set rawHeaders to get all headers')
        self.assertIn('item 2 of failureEnvelope, item 3 of failureEnvelope', hydration)
        self.assertNotRegex(hydration, r'(?m)^\s*(?:return|set end of results to).*errorText')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_missing_values_lists_and_alias_choices_are_typed_without_mail(self):
        # Extract only pure handlers. The interpreter never loads or addresses
        # Mail, and the fixture has no application reference to execute.
        pure = '\n'.join(handler(name) for name in ('mailText', 'mailAddressList', 'strictEqual',
                                                   'mailDate', 'metadataValues', 'mailFailureEnvelope'))
        self.assertNotIn('tell application', pure)
        fixture = '''
set checks to {}
set end of checks to (my mailText(missing value, false, 9163) is "")
set end of checks to (my mailText(42, true, 9163) is "42")
set end of checks to (my mailAddressList("author@fixture.invalid") is {"author@fixture.invalid"})
set end of checks to (my mailAddressList({"author@fixture.invalid", "shared@fixture.invalid"}) is {"author@fixture.invalid", "shared@fixture.invalid"})
set end of checks to (my mailAddressList(missing value) is {})
try
    my mailText({"one", "two"}, false, 9163)
    set end of checks to false
on error number errorNumber
    set end of checks to (errorNumber is 9163)
end try
try
    my mailText(missing value, true, 9162)
    set end of checks to false
on error number errorNumber
    set end of checks to (errorNumber is 9162)
end try
try
    my mailAddressList({{"author@fixture.invalid"}})
    set end of checks to false
on error number errorNumber
    set end of checks to (errorNumber is 9166)
end try
set end of checks to (my mailFailureEnvelope(-1700, 9173) is {"HARBOR_MAIL_FAILURE_V1", 9273, 9173})
set end of checks to (my mailFailureEnvelope(9173, 9171) is {"HARBOR_MAIL_FAILURE_V1", 9173, 9171})
set end of checks to (my mailFailureEnvelope(-1728, 9188) is {"HARBOR_MAIL_FAILURE_V1", -1728, 9188})
set end of checks to (my mailFailureEnvelope(-1700, 0) is {"HARBOR_MAIL_FAILURE_V1", -1700, 0})
set end of checks to (my mailFailureEnvelope(-1700, 9301) is {"HARBOR_MAIL_FAILURE_V1", 9401, 9301})
set end of checks to (my mailFailureEnvelope(-1708, 9307) is {"HARBOR_MAIL_FAILURE_V1", -1708, 9307})
set end of checks to (my mailFailureEnvelope(-1700, 9193) is {"HARBOR_MAIL_FAILURE_V1", 9293, 9193})
set testDate to current date
set fields to my metadataValues(42, missing value, "[FICTIONAL]", "author@fixture.invalid", testDate, missing value, 1024)
set end of checks to (fields is {"42", "", "[FICTIONAL]", "author@fixture.invalid", testDate, missing value, "1024"})
try
    my metadataValues(42, "42@fixture.invalid", {"bad", "subject"}, "author@fixture.invalid", missing value, missing value, 1024)
    set end of checks to false
on error number errorNumber
    set end of checks to (errorNumber is 9173)
end try
try
    my mailDate("not a date", 9176)
    set end of checks to false
on error number errorNumber
    set end of checks to (errorNumber is 9176)
end try
if (count of checks) is 18 and false is not in checks then return "PURE_MAIL_VALUE_CHECKS_PASSED"
error "PURE_MAIL_VALUE_CHECKS_FAILED"
'''
        result = subprocess.run([shutil.which('osascript'), '-'], input=pure+'\n'+fixture,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'PURE_MAIL_VALUE_CHECKS_PASSED')


if __name__ == '__main__':
    unittest.main()
