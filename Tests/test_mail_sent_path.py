"""Execute the shipping path traversal with fictional script readers, no Mail."""
import pathlib
import re
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'Sources/HarborReply/Resources/MailBridge.applescript').read_text()


def handler(name):
    return re.search(rf'^on {name}\(.*?^end {name}$', SCRIPT, re.M | re.S).group(0)


PURE = '\n'.join(handler(name) for name in ('strictEqual', 'mailText', 'styleSentPath'))

READER = '''
script fixtureReader
    property modeValue : "MODE"
    property lookups : 0
    property parents : 0
    on stylePathName(b)
        if b is "folder" then return "Projects"
        return "Sent"
    end stylePathName
    on stylePathResolve(accountID, pathNames)
        set lookups to lookups + 1
        if accountID is not "fixture-personal" then error "FIXTURE_ACCOUNT" number 9130
        if modeValue is "permission" then error "PRIVATE_FIXTURE_ERROR" number -1743
        if modeValue is "timeout" then error "PRIVATE_FIXTURE_ERROR" number -1712
        if modeValue is "stale" then error "PRIVATE_FIXTURE_ERROR" number 9130
        if modeValue is "direct" then return "sent-object"
        if modeValue is "nested" or modeValue is "nested-missing" then
            if pathNames is {"Projects", "Sent"} then return "sent-object"
            if modeValue is "nested-missing" then error "NOT_AT_ROOT" number -1728
        end if
        if modeValue is "account-gone" then error "NOT_FOUND" number -1728
        return "other-mailbox"
    end stylePathResolve
    on stylePathParent(b)
        set parents to parents + 1
        if modeValue is "direct" or modeValue is "parent-failed" then error "NO_ACCOUNT_CONTAINER" number -1728
        if modeValue is "nested" or modeValue is "nested-missing" then return "folder"
        if modeValue is "missing" then return missing value
        if modeValue is "depth" then return b
        return "unified-sent-root"
    end stylePathParent
end script
'''


class SentPathContractTests(unittest.TestCase):
    def test_path_proof_keeps_role_and_account_checks_with_no_mail_in_fixture(self):
        self.assertNotIn('tell application', PURE + READER)
        source = handler('styleSentMailboxes')
        self.assertIn('scopedRoleMailbox(sentRoot, accountID)', source)
        self.assertIn('strictEqual(resolvedSent, actualSent)', source)
        self.assertIn('strictEqual(actualSent, refreshedSent)', source)
        self.assertNotIn('indexAccountID(parentBox)', source)
        self.assertIn('indexMailbox(accountID, pathNames, false)', handler('stylePathResolve'))

    def run_fixture(self, mode, check):
        reader = READER.replace('"MODE"', '"' + mode + '"')
        result = subprocess.run([shutil.which('osascript'), '-'], input=PURE+'\n'+reader+'\n'+check,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'FICTIONAL_SENT_PATH_PASSED')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_account_root_sent_never_reads_unsupported_parent(self):
        self.run_fixture('direct', '''
set resultPath to my styleSentPath("sent-object", "fixture-personal", "unified-sent-root", fixtureReader)
if resultPath is not {"Sent"} or fixtureReader's lookups is not 1 or fixtureReader's parents is not 0 then error "EARLY_PROOF_FAILED"
return "FICTIONAL_SENT_PATH_PASSED"
''')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_nested_sent_does_not_accept_other_folder_with_same_leaf_name(self):
        for mode in ('nested', 'nested-missing'):
            with self.subTest(mode=mode):
                self.run_fixture(mode, '''
set resultPath to my styleSentPath("sent-object", "fixture-personal", "unified-sent-root", fixtureReader)
if resultPath is not {"Projects", "Sent"} or fixtureReader's lookups is not 2 or fixtureReader's parents is not 1 then error "NESTED_PROOF_FAILED"
return "FICTIONAL_SENT_PATH_PASSED"
''')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_permission_timeout_and_changed_account_do_not_become_path_misses(self):
        for mode, number in [('permission', -1743), ('timeout', -1712), ('stale', 9130)]:
            with self.subTest(mode=mode):
                self.run_fixture(mode, f'''
try
    my styleSentPath("sent-object", "fixture-personal", "unified-sent-root", fixtureReader)
    error "EXPECTED_FAILURE"
on error number actualNumber
    if actualNumber is not {number} then error "ORIGINAL_ERROR_LOST"
end try
if fixtureReader's lookups is not 1 or fixtureReader's parents is not 0 then error "FAILURE_CONTINUED"
return "FICTIONAL_SENT_PATH_PASSED"
''')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_unproved_root_parent_failure_and_depth_bound_fail_closed(self):
        for mode, number, calls in [('root', 9144, 1), ('missing', 9144, 1), ('account-gone', 9144, 1),
                                    ('parent-failed', -1728, 1), ('depth', 9140, 32)]:
            with self.subTest(mode=mode):
                self.run_fixture(mode, f'''
try
    my styleSentPath("sent-object", "fixture-personal", "unified-sent-root", fixtureReader)
    error "EXPECTED_FAILURE"
on error number actualNumber
    if actualNumber is not {number} then error "WRONG_FAILURE"
end try
if fixtureReader's lookups is not {calls} or fixtureReader's parents is not {calls} then error "UNBOUNDED_WORK"
return "FICTIONAL_SENT_PATH_PASSED"
''')
