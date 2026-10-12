"""Shipping compatibility dispatch with fictional script readers, never Mail."""
import pathlib
import re
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'Sources/HarborReply/Resources/MailBridge.applescript').read_text()


def handler(name):
    return re.search(rf'^on {name}\(.*?^end {name}$', SCRIPT, re.M | re.S).group(0)


PURE = '\n'.join(handler(name) for name in ('strictEqual', 'indexColumnValues', 'indexPageCheckpoint'))
READER = '''
script fixtureReader
    property modeValue : "MODE"
    property errorValue : -1708
    property rangeCalls : 0
    property scalarCalls : 0
    property disabledColumns : {}
    on indexUsesRange(stageNumber)
        if stageNumber is 9171 then error "NATIVE_ID_MUST_NOT_PROBE_RANGE_CAPABILITY" number 9999
        return stageNumber is not in disabledColumns
    end indexUsesRange
    on indexDisableRange(stageNumber)
        set end of disabledColumns to stageNumber
    end indexDisableRange
    on fixtureValue(positionValue, stageNumber)
        return "fixture-" & stageNumber & "-" & positionValue
    end fixtureValue
    on indexRangeColumn(b, firstIndex, lastIndex, stageNumber)
        set rangeCalls to rangeCalls + 1
        if modeValue is "unsupported" or modeValue is "scalar-failed" then error "PRIVATE_FIXTURE_ONLY" number -1708
        if modeValue is "id-only" and stageNumber is 9171 then error "PRIVATE_FIXTURE_ONLY" number -1708
        if modeValue is "error" then error "PRIVATE_FIXTURE_ONLY" number errorValue
        if modeValue is "scalar-shape" then return "not a column list"
        if modeValue is "short-shape" then return {}
        set columnValues to {}
        repeat with positionValue from firstIndex to lastIndex
            set end of columnValues to my fixtureValue(positionValue as integer, stageNumber)
        end repeat
        return columnValues
    end indexRangeColumn
    on indexScalarColumn(b, positionValue, stageNumber)
        set scalarCalls to scalarCalls + 1
        if modeValue is "scalar-failed" then error "PRIVATE_FIXTURE_ONLY" number errorValue
        return my fixtureValue(positionValue, stageNumber)
    end indexScalarColumn
end script
'''


class IndexColumnContractTests(unittest.TestCase):
    def test_fixed_readers_and_page_checkpoint_do_not_fetch_body_or_scan_all_mail(self):
        self.assertNotIn('tell application', PURE + READER)
        readers = handler('indexRangeColumn') + handler('indexScalarColumn')
        self.assertNotRegex(readers, r'\b(?:content|source|all headers|properties|whose|every message|mail attachments)\b')
        self.assertNotRegex(readers, r'(?im)^\s*(send|delete|move|make|set (?:read status|enabled|password) of)\b')
        self.assertIn('set my readFailureStage to stageNumber + 130', handler('indexScalarColumn'))
        self.assertIn('a reference to «class mssg» messagePosition of b', handler('indexScalarColumn'))
        self.assertIn('a reference to «class mssg» id requestedID of b', handler('indexHydrate'))
        self.assertIn('indexPageCheckpoint(beforeCount, afterCount, nativeIDs, afterIDs)', handler('indexHeaderPage'))

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_page_shape_loop_retains_mail_dictionary_without_addressing_mail(self):
        # The public dictionary is compile-time terminology only. This fixture
        # contains no application tell, native object, source data or Mail call.
        # Keep the shipping dictionary context, while also checking the same
        # compound-reference failure in a script with no Mail terminology.
        loop = re.search(r'        repeat with columnValues in \{nativeIDs,.*?        end repeat',
                         handler('indexHeaderPage'), re.S).group(0)
        setup = '''
set pageCount to 2
set nativeIDs to {1, 2}
set messageIDs to {"first@fixture.invalid", "second@fixture.invalid"}
set subjects to {"Fictional first", "Fictional second"}
set senders to {"sender@fixture.invalid", "sender@fixture.invalid"}
set sentDates to {missing value, missing value}
set receivedDates to {missing value, missing value}
set sizes to {42, 43}
set afterIDs to {1, 2}
'''
        def execute(loop_source, mail_terms=True, malformed=False):
            fixture = setup.replace('set subjects to {"Fictional first", "Fictional second"}',
                                    'set subjects to {"Fictional first"}') if malformed else setup
            fixture += '\ntry\n'+loop_source+'\nreturn "FICTIONAL_PAGE_SHAPE_PASSED"\n'\
                       'on error number errorNumber\nreturn "FICTIONAL_PAGE_SHAPE_FAILED_" & errorNumber\nend try\n'
            if mail_terms:
                fixture = 'using terms from application "Mail"\n'+fixture+'\nend using terms from\n'
            self.assertNotIn('tell application', fixture)
            self.assertNotIn('tell current application', fixture)
            result = subprocess.run([shutil.which('osascript'), '-'], input=fixture,
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()
        self.assertEqual(execute(loop), 'FICTIONAL_PAGE_SHAPE_PASSED')
        self.assertEqual(execute(loop, malformed=True), 'FICTIONAL_PAGE_SHAPE_FAILED_9134')
        old_loop = loop.replace('count of columnValues', 'count of contents of columnValues')
        self.assertNotEqual(old_loop, loop)
        self.assertEqual(execute(old_loop, mail_terms=False), 'FICTIONAL_PAGE_SHAPE_FAILED_-1708')
        self.assertEqual(execute(old_loop), 'FICTIONAL_PAGE_SHAPE_FAILED_-1708')
        # The repeat-item reference/contents itself is valid; it is the compound
        # count command that fails. This prevents blaming a Mail property GET.
        self.assertEqual(execute(old_loop.replace('count of contents of columnValues',
                                                 'length of contents of columnValues')),
                         'FICTIONAL_PAGE_SHAPE_PASSED')

    def test_page_shape_validation_sets_its_own_stage_before_the_loop(self):
        page = handler('indexHeaderPage')
        loop_start = page.index('repeat with columnValues in {nativeIDs,')
        preceding_getter = page.index('set afterIDs to my indexColumnValues(')
        self.assertIn('set my readFailureStage to 9193', page[preceding_getter:loop_start])
        self.assertIn('count of columnValues', page[loop_start:])
        self.assertNotIn('count of contents of columnValues', page)

    def run_fixture(self, mode, check):
        source = PURE + '\n' + READER.replace('"MODE"', '"'+mode+'"') + '\n' + check
        result = subprocess.run([shutil.which('osascript'), '-'], input=source,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'FICTIONAL_INDEX_COLUMNS_PASSED')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_fast_path_and_single_column_fallback_preserve_order_and_cache(self):
        # Native ID is read twice per page (metadata + checkpoint), always as
        # bounded scalar GETs even when a reader claims to support every range.
        for mode, expected_range, expected_scalar in [('supported', 6, 256), ('id-only', 6, 256)]:
            with self.subTest(mode=mode):
                self.run_fixture(mode, f'''
repeat with stageNumber in {{9171,9172,9173,9174,9175,9176,9177,9171}}
    set values to my indexColumnValues("fixture-mailbox", 129, 256, stageNumber as integer, fixtureReader)
    if (count of values) is not 128 then error "ROW_COUNT"
    repeat with rowPosition from 1 to 128
        if item rowPosition of values is not fixtureReader's fixtureValue(rowPosition + 128, stageNumber as integer) then error "ROW_ORDER"
    end repeat
end repeat
if fixtureReader's rangeCalls is not {expected_range} or fixtureReader's scalarCalls is not {expected_scalar} then error "WORK_COUNT"
return "FICTIONAL_INDEX_COLUMNS_PASSED"
''')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_all_columns_fallback_is_bounded_at_one_and_128_rows_and_next_page(self):
        for count in (1, 128):
            with self.subTest(count=count):
                self.run_fixture('unsupported', f'''
repeat with stageNumber in {{9171,9172,9173,9174,9175,9176,9177,9171}}
    my indexColumnValues("fixture-mailbox", 1, {count}, stageNumber as integer, fixtureReader)
end repeat
if fixtureReader's rangeCalls is not 6 or fixtureReader's scalarCalls is not {8*count} then error "FIRST_PAGE_WORK"
repeat with stageNumber in {{9171,9172,9173,9174,9175,9176,9177,9171}}
    my indexColumnValues("fixture-mailbox", {count+1}, {count*2}, stageNumber as integer, fixtureReader)
end repeat
if fixtureReader's rangeCalls is not 6 or fixtureReader's scalarCalls is not {16*count} then error "CAPABILITY_CACHE"
return "FICTIONAL_INDEX_COLUMNS_PASSED"
''')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_only_unhandled_range_event_enables_fallback(self):
        for number in (-1743, -1728, -1700, -1712, 9130):
            with self.subTest(number=number):
                self.run_fixture('error', f'''
set fixtureReader's errorValue to {number}
try
    my indexColumnValues("fixture-mailbox", 1, 128, 9172, fixtureReader)
    error "EXPECTED_FAILURE"
on error number actualNumber
    if actualNumber is not {number} then error "ORIGINAL_ERROR_LOST"
end try
if fixtureReader's scalarCalls is not 0 or fixtureReader's disabledColumns is not {{}} then error "UNSAFE_FALLBACK"
return "FICTIONAL_INDEX_COLUMNS_PASSED"
''')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_scalar_failure_and_range_shape_fail_without_retry(self):
        for mode, number, stage, range_count, scalar_count in [('scalar-failed', -1728, 9171, 0, 1), ('scalar-shape', 9134, 9172, 1, 0), ('short-shape', 9134, 9172, 1, 0)]:
            with self.subTest(mode=mode):
                self.run_fixture(mode, f'''
try
    set fixtureReader's errorValue to {number}
    my indexColumnValues("fixture-mailbox", 1, 128, {stage}, fixtureReader)
    error "EXPECTED_FAILURE"
on error number actualNumber
    if actualNumber is not {number} then error "WRONG_FAILURE"
end try
if fixtureReader's rangeCalls is not {range_count} or fixtureReader's scalarCalls is not {scalar_count} then error "FAILURE_RETRIED"
return "FICTIONAL_INDEX_COLUMNS_PASSED"
''')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_native_id_scalar_error_never_tries_range_or_changes_capability(self):
        for number in (-1743, -1728, -1708, -1700, -1712):
            with self.subTest(number=number):
                self.run_fixture('scalar-failed', f'''
set fixtureReader's errorValue to {number}
try
    my indexColumnValues("fixture-mailbox", 1, 128, 9171, fixtureReader)
    error "EXPECTED_FAILURE"
on error number actualNumber
    if actualNumber is not {number} then error "ORIGINAL_SCALAR_ERROR_LOST"
end try
if fixtureReader's rangeCalls is not 0 or fixtureReader's scalarCalls is not 1 then error "SCALAR_FAILURE_RETRIED"
if fixtureReader's disabledColumns is not {{}} then error "SCALAR_CHANGED_CAPABILITY"
return "FICTIONAL_INDEX_COLUMNS_PASSED"
''')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_invalid_bound_or_property_never_calls_reader(self):
        for first, last, stage in [(1, 0, 9171), (1, 129, 9171), (0, 1, 9171), (1, 1, 9170), (1, 1, 9178)]:
            with self.subTest(bound=(first, last, stage)):
                self.run_fixture('unsupported', f'''
try
    my indexColumnValues("fixture-mailbox", {first}, {last}, {stage}, fixtureReader)
    error "EXPECTED_FAILURE"
on error number actualNumber
    if actualNumber is not 9131 then error "WRONG_BOUND_FAILURE"
end try
if fixtureReader's rangeCalls is not 0 or fixtureReader's scalarCalls is not 0 then error "BOUND_READ"
return "FICTIONAL_INDEX_COLUMNS_PASSED"
''')

    @unittest.skipUnless(shutil.which('osascript'), 'macOS pure AppleScript interpreter unavailable')
    def test_count_id_reorder_and_case_only_edits_stop_page_before_publication(self):
        self.run_fixture('supported', '''
my indexPageCheckpoint(0, 0, {}, {})
my indexPageCheckpoint(128, 128, {1,2}, {1,2})
repeat with changedValues in {{128,129,{1,2},{1,2}}, {128,128,{1,2},{2,1}}, {128,128,{1,2},{1}}, {1,1,{"A"},{"a"}}}
    set c to contents of changedValues
    try
        my indexPageCheckpoint(item 1 of c, item 2 of c, item 3 of c, item 4 of c)
        error "EXPECTED_FAILURE"
    on error number actualNumber
        if actualNumber is not 9130 then error "CURSOR_CHANGE_LOST"
    end try
end repeat
return "FICTIONAL_INDEX_COLUMNS_PASSED"
''')
