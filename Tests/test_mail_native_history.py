"""Static safety regressions; never sends an Apple event or reads a mailbox."""
import pathlib
import re
import unittest


SCRIPT = (pathlib.Path(__file__).resolve().parents[1] / "Sources/HarborReply/Resources/MailBridge.applescript").read_text()


def handler(name):
    return re.search(rf"^on {name}\(.*?^end {name}$", SCRIPT, re.M | re.S).group(0)


class NativeHistorySafetyTests(unittest.TestCase):
    def test_metadata_properties_are_bounded_ranges_without_body_or_full_properties(self):
        source = handler("historySlice")
        self.assertNotRegex(source, r"\b(?:content|all headers|source|properties|every message|whose)\b")
        self.assertIn("messages firstIndex thru lastIndex of b", source)
        self.assertIn("rowCount > 256", source)
        self.assertNotIn("mail attachments of", source)

    def test_readonly_operations_do_not_mutate_mail_or_account_state(self):
        source = "\n".join(handler(name) for name in ["captureHistory", "historySlice", "appendHistoryMailbox", "scopedRoleMailbox", "historyMetadata", "hydrateHistory"])
        self.assertNotRegex(source, r"(?im)^\s*(send|delete|move|make|set (?:read status|deleted status|junk mail status|password|enabled) of)\b")
        self.assertNotIn("Library/Mail", source)
        self.assertNotIn("whose", source)
        self.assertNotIn("every message", source)

    def test_sent_role_is_from_actual_mail_object_and_hydration_rechecks(self):
        self.assertIn("set sentRoot to sent mailbox", handler("captureHistory"))
        self.assertIn('appendHistoryMailbox(sentBox, "sent"', handler("captureHistory"))
        self.assertIn("childCount > 32", handler("scopedRoleMailbox"))
        source = handler("hydrateHistory")
        self.assertIn("strictEqual(requestToken, my historyToken)", source)
        self.assertIn("(count of expectedRows) > 20", source)
        self.assertEqual(source.count("my historyMetadata(matchedMessage, directionValue)"), 2)
        self.assertIn("strictEqual(beforeMetadata, expectedRow)", source)
        self.assertIn("strictEqual(afterMetadata, expectedRow)", source)
        self.assertIn("2097152", source)

    def test_native_checkpoints_detect_case_only_edits_and_return_actual_metadata(self):
        equality = handler("strictEqual")
        self.assertIn("considering case", equality)
        self.assertIn("return leftValue is rightValue", equality)
        self.assertIn("strictEqual(currentData, items 1 thru 5 of expectedTarget)", handler("sameCapturedMetadata"))
        hydration = handler("hydrateHistory")
        self.assertIn("strictEqual(item 2 of cachedRow, expectedRow)", hydration)
        self.assertIn("set end of hydrated to {afterMetadata, plainBody, plainHeaders, attachmentCount}", hydration)
        self.assertNotIn("set end of hydrated to {expectedRow,", hydration)
        writes = handler("perform")
        self.assertIn("strictEqual(my captureSelected(), expectedTarget)", writes)
        self.assertIn("strictEqual(my draftSnapshot(), expectedSnapshot)", writes)
        self.assertIn("strictEqual(my captureSelected(), item 3 of payload)", writes)

    def test_full_catalog_is_bounded_dfs_and_paged_columns_without_body(self):
        discovery = handler("indexDiscover")
        self.assertIn("workCount < 64", discovery)
        self.assertIn("(count of resultBoxes) < limitValue", discovery)
        self.assertIn("(count of resultAccounts) < 32", discovery)
        self.assertIn("expectedChildren is not childCount", discovery)
        self.assertNotIn("every mailbox", discovery)
        page = handler("indexHeaderPage")
        self.assertIn("limitValue > 128", page)
        self.assertIn("indexColumnValues(b, firstIndex, lastIndex, 9171, me)", page)
        self.assertIn("messages firstIndex thru lastIndex of b", handler("indexRangeColumn"))
        self.assertIn("indexPageCheckpoint(beforeCount, afterCount, nativeIDs, afterIDs)", page)
        self.assertIn("strictEqual(nativeIDs, afterIDs)", handler("indexPageCheckpoint"))
        self.assertIn("afterCount is not beforeCount", handler("indexPageCheckpoint"))
        self.assertNotRegex(page, r"\b(?:content|all headers|every message|whose)\b")

    def test_indexed_body_reads_use_direct_id_fullpath_and_individual_failures(self):
        body = handler("indexHydrate")
        self.assertIn("«class mssg» id requestedID of b", body)
        self.assertNotIn("whose", body)
        self.assertNotIn("every message", body)
        self.assertIn("strictEqual(beforeMetadata, expectedRow)", body)
        self.assertIn("strictEqual(afterMetadata, expectedRow)", body)
        self.assertIn("MAIL_INDEX_MESSAGE_TOO_LARGE", body)
        self.assertIn("on error errorText number errorNumber", body)
        self.assertIn("{expectedRow, \"\", \"\", 0, failureValue, item 2 of failureEnvelope, item 3 of failureEnvelope}", body)
        self.assertIn("strictEqual(actualBox, expectedBox)", handler("indexMetadata"))
        self.assertIn("strictEqual(name of b as text, item 1 of pathNames)", handler("indexMailbox"))
        self.assertIn("strictEqual(name of b as text, item pathIndex of pathNames)", handler("indexMailbox"))
        for name in ["indexDiscover", "indexHeaderPage", "indexHydrate", "indexMailbox"]:
            self.assertNotRegex(handler(name), r"(?im)^\s*(send|delete|move|make|set (?:read status|password|enabled) of)\b")


if __name__ == "__main__":
    unittest.main()
