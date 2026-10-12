use framework "Foundation"
use scripting additions

-- Static code. All variable data is passed through Apple event descriptors.
property trackedMessage : missing value
property trackedDraft : missing value
property trackedRequest : ""
property attemptedRequests : {}
property capturedHistoryMessage : missing value
property historyToken : ""
property historyRecords : {}
property readFailureStage : 0
property indexUnsupportedColumns : {}
property bodyMetricPhaseValue : 0
property bodyMetricStarted : 0.0
property bodyMetricTimes : {0, 0, 0, 0}
property bodyMetricGets : {0, 0, 0, 0}
property bodyUnsupportedRanges : {}
property styleContentsScopeKey : missing value
property styleContentsScopeValue : missing value


-- Monotonic, numeric-only native phases. Request-site counters include failed
-- GET/count attempts and exclude local references/descriptor validation.
on bodyMetricNow()
    return (current application's NSProcessInfo's processInfo()'s systemUptime()) as real
end bodyMetricNow

on bodyMetricBegin()
    set my bodyMetricPhaseValue to 0
    set my bodyMetricTimes to {0, 0, 0, 0}
    set my bodyMetricGets to {0, 0, 0, 0}
end bodyMetricBegin

on bodyMetricPhase(phaseNumber)
    set nowValue to my bodyMetricNow()
    set previousPhase to my bodyMetricPhaseValue
    if previousPhase > 0 then
        set elapsedValue to ((nowValue - my bodyMetricStarted) * 1000) as integer
        if elapsedValue < 0 then set elapsedValue to 0
        set item previousPhase of my bodyMetricTimes to (item previousPhase of my bodyMetricTimes) + elapsedValue
    end if
    set my bodyMetricPhaseValue to phaseNumber
    set my bodyMetricStarted to nowValue
end bodyMetricPhase

on bodyMetricGet()
    set phaseNumber to my bodyMetricPhaseValue
    if phaseNumber > 0 then set item phaseNumber of my bodyMetricGets to (item phaseNumber of my bodyMetricGets) + 1
end bodyMetricGet

on bodyMetricResult(modeValue, rowCount)
    my bodyMetricPhase(0)
    return {modeValue, rowCount, my bodyMetricTimes, my bodyMetricGets}
end bodyMetricResult

-- AppleScript normally ignores case even inside list comparisons. Native
-- identity/content checkpoints must also detect case-only edits.
on strictEqual(leftValue, rightValue)
    considering case
        return leftValue is rightValue
    end considering
end strictEqual

-- Never silently flatten a list or spell missing value into metadata. These
-- helpers can be tested with fictional values without addressing Mail.
on mailText(rawValue, requiredValue, stageNumber)
    if rawValue is missing value then
        if requiredValue then error "MAIL_REQUIRED_TEXT" number stageNumber
        return ""
    end if
    set valueClass to class of rawValue
    if valueClass is not text and valueClass is not integer then error "MAIL_TEXT_SHAPE" number stageNumber
    set resultValue to rawValue as text
    if requiredValue and resultValue is "" then error "MAIL_REQUIRED_TEXT" number stageNumber
    return resultValue
end mailText

on mailAddressList(rawValue)
    if rawValue is missing value then return {}
    if class of rawValue is text then set rawValue to {rawValue}
    if class of rawValue is not list then error "MAIL_ADDRESS_SHAPE" number 9166
    if (count of rawValue) > 32 then error "STYLE_DISCOVERY_BOUND" number 9140
    set resultValue to {}
    repeat with valueRef in rawValue
        set addressValue to contents of valueRef
        if class of addressValue is not text then error "MAIL_ADDRESS_SHAPE" number 9166
        set end of resultValue to addressValue
    end repeat
    return resultValue
end mailAddressList

on mailDate(rawValue, stageNumber)
    if rawValue is missing value then return missing value
    if class of rawValue is not date then error "MAIL_DATE_SHAPE" number stageNumber
    return rawValue
end mailDate

on metadataValues(rawID, rawHeaderID, rawSubject, rawSender, rawSentDate, rawReceivedDate, rawSize)
    return {my mailText(rawID, true, 9171), my mailText(rawHeaderID, false, 9172), my mailText(rawSubject, false, 9173), my mailText(rawSender, false, 9174), my mailDate(rawSentDate, 9175), my mailDate(rawReceivedDate, 9176), my mailText(rawSize, true, 9177)}
end metadataValues

-- Individual getters retain their exact operation stage. These bounded reads
-- never request every property (which would also acquire content/source).
on messageMetadataValues(m)
    tell application "Mail"
        set my readFailureStage to 9171
        my bodyMetricGet()
        set rawID to get id of m
        set my readFailureStage to 9172
        my bodyMetricGet()
        set rawHeaderID to get message id of m
        set my readFailureStage to 9173
        my bodyMetricGet()
        set rawSubject to get subject of m
        set my readFailureStage to 9174
        my bodyMetricGet()
        set rawSender to get sender of m
        set my readFailureStage to 9175
        my bodyMetricGet()
        set rawSentDate to get date sent of m
        set my readFailureStage to 9176
        my bodyMetricGet()
        set rawReceivedDate to get date received of m
        set my readFailureStage to 9177
        my bodyMetricGet()
        set rawSize to get message size of m
    end tell
    return my metadataValues(rawID, rawHeaderID, rawSubject, rawSender, rawSentDate, rawReceivedDate, rawSize)
end messageMetadataValues

-- Shape validation and native coercion retain different numbers. Scalar
-- metadata stages 9301..9307 distinguish fallback from ranged reads.
on mailFailureEnvelope(errorNumber, stageNumber)
    set reportedNumber to errorNumber
    if errorNumber is -1700 and stageNumber >= 9160 and stageNumber <= 9195 then set reportedNumber to stageNumber + 100
    if errorNumber is -1700 and stageNumber >= 9301 and stageNumber <= 9307 then set reportedNumber to stageNumber + 100
    return {"HARBOR_MAIL_FAILURE_V1", reportedNumber, stageNumber}
end mailFailureEnvelope

on captureSelected()
    set my readFailureStage to 9160
    tell application "Mail"
        set chosen to get selection
    end tell
    if class of chosen is not list then error "MAIL_SELECTION_SHAPE" number 9160
    if (count of chosen) is not 1 then error "SELECTION_COUNT" number 9101
    set m to contents of item 1 of chosen
    set my readFailureStage to 9177
    tell application "Mail" to set sizeValue to get message size of m
    if class of sizeValue is not integer then error "MAIL_SIZE_SHAPE" number 9161
    if sizeValue > 2097152 then error "SELECTED_MESSAGE_LIMIT" number 9102
    if sizeValue < 0 then error "MAIL_SIZE_SHAPE" number 9161
    set my readFailureStage to 9162
    tell application "Mail"
        set my readFailureStage to 9168
        set selectedMailbox to get mailbox of m
        set my readFailureStage to 9162
        set selectedAccount to get account of selectedMailbox
        set my readFailureStage to 9183
        set rawAccountID to get id of selectedAccount
        set my readFailureStage to 9187
        set rawMailboxName to get name of selectedMailbox
    end tell
    set acct to my mailText(rawAccountID, true, 9183)
    set boxName to my mailText(rawMailboxName, true, 9187)
    set my readFailureStage to 9163
    tell application "Mail"
        set my readFailureStage to 9171
        set rawID to get id of m
        set my readFailureStage to 9172
        set rawHeaderID to get message id of m
        set my readFailureStage to 9173
        set rawSubject to get subject of m
        set my readFailureStage to 9174
        set rawSender to get sender of m
    end tell
    set nativeID to my mailText(rawID, true, 9171)
    set headerID to my mailText(rawHeaderID, false, 9172)
    set subjectValue to my mailText(rawSubject, false, 9173)
    set senderValue to my mailText(rawSender, false, 9174)
    set my readFailureStage to 9164
    tell application "Mail" to set rawBody to get content of m
    if rawBody is missing value or class of rawBody is list then error "MAIL_BODY_SHAPE" number 9164
    tell application "Mail" to set plainBody to rawBody as text
    set my readFailureStage to 9165
    tell application "Mail" to set rawHeaders to get all headers of m
    set plainHeaders to my mailText(rawHeaders, false, 9165)
    set resultData to {nativeID, acct & ":" & boxName, headerID, subjectValue, senderValue, plainBody, plainHeaders}
    set my capturedHistoryMessage to m
    return resultData
end captureSelected

-- Read-only account/address choices, independent of selection or message data.
on styleAccountIdentities()
    set my readFailureStage to 9181
    tell application "Mail" to set accountCount to count of accounts
    if accountCount > 32 then error "STYLE_DISCOVERY_BOUND" number 9140
    set resultValue to {}
    set accountIDs to {}
    repeat with accountIndex from 1 to accountCount
        tell application "Mail"
            set a to account accountIndex
            set my readFailureStage to 9183
            set rawID to get id of a
            set my readFailureStage to 9184
            set rawEnabled to get enabled of a
        end tell
        set accountID to my mailText(rawID, true, 9166)
        set end of accountIDs to accountID
        if class of rawEnabled is not boolean then error "MAIL_ACCOUNT_ENABLED_SHAPE" number 9166
        if rawEnabled then
            tell application "Mail"
                set my readFailureStage to 9185
                set rawName to get name of a
                set my readFailureStage to 9186
                set rawAddresses to get email addresses of a
            end tell
            set end of resultValue to {accountID, my mailText(rawName, false, 9166), my mailAddressList(rawAddresses)}
        end if
    end repeat
    set my readFailureStage to 9181
    tell application "Mail" to set afterCount to count of accounts
    if afterCount is not accountCount then error "STYLE_ACCOUNT_CHANGED" number 9141
    repeat with accountIndex from 1 to accountCount
        set my readFailureStage to 9183
        tell application "Mail" to set rawID to get id of account accountIndex
        if not my strictEqual(my mailText(rawID, true, 9166), item accountIndex of accountIDs) then error "STYLE_ACCOUNT_CHANGED" number 9141
    end repeat
    return resultValue
end styleAccountIdentities

-- The genuine Sent object supplies provenance. Its public container chain is
-- bounded; no mailbox scan, messages, bodies or From inference is involved.
on styleSentMailboxes(accountID)
    set my readFailureStage to 9167
    tell application "Mail"
        set a to account id accountID
        set my readFailureStage to 9183
        set rawID to get id of a
        set my readFailureStage to 9184
        set enabledValue to get enabled of a
        set my readFailureStage to 9178
        set sentRoot to sent mailbox
    end tell
    if not my strictEqual(my mailText(rawID, true, 9167), accountID) then error "STYLE_ACCOUNT_CHANGED" number 9141
    if class of enabledValue is not boolean then error "MAIL_ACCOUNT_ENABLED_SHAPE" number 9167
    if not enabledValue then error "STYLE_ACCOUNT_CHANGED" number 9141
    set actualSent to my scopedRoleMailbox(sentRoot, accountID)
    if actualSent is missing value then error "STYLE_SENT_UNAVAILABLE" number 9143
    set pathNames to my styleSentPath(actualSent, accountID, sentRoot, me)
    set resolvedSent to my indexMailbox(accountID, pathNames, false)
    if not my strictEqual(resolvedSent, actualSent) then error "STYLE_SENT_PATH_CHANGED" number 9144
    set my readFailureStage to 9180
    tell application "Mail" to set messageCount to count of messages of actualSent
    set refreshedSent to my scopedRoleMailbox(sentRoot, accountID)
    if refreshedSent is missing value or not my strictEqual(actualSent, refreshedSent) then error "STYLE_SENT_PATH_CHANGED" number 9144
    return {{accountID, pathNames, item -1 of pathNames, messageCount as text, "sent", false}}
end styleSentMailboxes

-- Resolve the account-relative path before asking for another parent. A
-- genuine account-level Sent is already resolved at depth 1; its virtual
-- parent may not support an account/container getter at all (-1728).
-- Reader injection lets this exact traversal run with fictional objects.
on styleSentPath(actualSent, accountID, sentRoot, reader)
    set currentBox to actualSent
    set pathNames to {}
    repeat with depthIndex from 1 to 32
        set pathNames to {my mailText(reader's stylePathName(currentBox), true, 9187)} & pathNames
        set resolvedSent to missing value
        try
            set resolvedSent to reader's stylePathResolve(accountID, pathNames)
        on error number errorNumber
            -- A nested leaf need not exist at account root. Other failures,
            -- including stale identities and permission denial, stay fatal.
            if errorNumber is not -1728 then error "STYLE_PATH_LOOKUP_FAILED" number errorNumber
        end try
        if resolvedSent is not missing value and my strictEqual(resolvedSent, actualSent) then return pathNames
        set parentBox to reader's stylePathParent(currentBox)
        if parentBox is missing value or my strictEqual(parentBox, sentRoot) then error "STYLE_SENT_PATH_CHANGED" number 9144
        set currentBox to parentBox
    end repeat
    error "STYLE_DISCOVERY_BOUND" number 9140
end styleSentPath

on stylePathName(b)
    set my readFailureStage to 9187
    tell application "Mail" to return get name of b
end stylePathName

on stylePathResolve(accountID, pathNames)
    return my indexMailbox(accountID, pathNames, false)
end stylePathResolve

on stylePathParent(b)
    set my readFailureStage to 9189
    tell application "Mail" to return get container of b
end stylePathParent

on draftSnapshot()
    set my readFailureStage to 9190
    if trackedDraft is missing value then error "NO_TRACKED_DRAFT" number 9103
    tell application "Mail"
        set d to trackedDraft
        set sig to ""
        if message signature of d is not missing value then set sig to name of message signature of d as text
        set tos to address of every to recipient of d
        set ccs to address of every cc recipient of d
        set bccs to address of every bcc recipient of d
        return {id of d as text, sender of d as text, subject of d as text, content of d as text, sig, tos, ccs, bccs}
    end tell
end draftSnapshot

-- Public Mail object metadata only. From, folder names, and headers do not
-- establish sent direction; only the application's actual sent mailbox does.
on historyMetadata(m, directionValue)
    set my readFailureStage to 9168
    tell application "Mail" to set b to get mailbox of m
    set accountID to my indexAccountID(b)
    set my readFailureStage to 9187
    tell application "Mail" to set rawName to get name of b
    set boxName to my mailText(rawName, true, 9187)
    set fields to my messageMetadataValues(m)
    return {item 1 of fields, accountID, boxName, item 2 of fields, item 3 of fields, item 4 of fields, directionValue, item 5 of fields, item 6 of fields, item 7 of fields, 0}
end historyMetadata

on sameCapturedMetadata(m, expectedTarget)
    set my readFailureStage to 9168
    tell application "Mail" to set b to get mailbox of m
    set acct to my indexAccountID(b)
    tell application "Mail"
        set my readFailureStage to 9187
        set rawName to get name of b
        set my readFailureStage to 9171
        set rawID to get id of m
        set my readFailureStage to 9172
        set rawHeaderID to get message id of m
        set my readFailureStage to 9173
        set rawSubject to get subject of m
        set my readFailureStage to 9174
        set rawSender to get sender of m
    end tell
    set boxName to my mailText(rawName, true, 9187)
    set currentData to {my mailText(rawID, true, 9171), acct & ":" & boxName, my mailText(rawHeaderID, false, 9172), my mailText(rawSubject, false, 9173), my mailText(rawSender, false, 9174)}
    return my strictEqual(currentData, items 1 thru 5 of expectedTarget)
end sameCapturedMetadata

-- Unified Inbox/Sent may expose account mailboxes as immediate children. Never
-- recursively walk the folder hierarchy or guess roles from localized names.
on scopedRoleMailbox(rootBox, accountID)
    set my readFailureStage to 9178
    try
        set rootAccountID to my indexAccountID(rootBox)
        if my strictEqual(rootAccountID, accountID) then return rootBox
    end try
    tell application "Mail"
        set my readFailureStage to 9182
        my bodyMetricGet()
        set childCount to count of mailboxes of rootBox
        if childCount > 32 then error "ROLE_MAILBOX_BOUND" number 9112
        if childCount is 0 then return missing value
        my bodyMetricGet()
        set children to mailboxes 1 thru childCount of rootBox
    end tell
    set matched to missing value
    repeat with childRef in children
        set b to contents of childRef
        set isMatch to false
        try
            set childAccountID to my indexAccountID(b)
            set isMatch to my strictEqual(childAccountID, accountID)
        end try
        if isMatch then
            if matched is not missing value then error "ROLE_MAILBOX_AMBIGUOUS" number 9113
            set matched to b
        end if
    end repeat
    return matched
end scopedRoleMailbox

-- Mail does not document date ordering or an indexed search. Sample both ends
-- of this public collection, at most limitValue objects in total. This is a
-- partial window, not a complete recent-history scan.
on appendHistoryMailbox(b, directionValue, accountID, limitValue)
    tell application "Mail"
        if (id of account of b as text) is not accountID then error "HISTORY_ACCOUNT_CHANGED" number 9114
        set my readFailureStage to 9187
        set boxName to name of b as text
        set my readFailureStage to 9180
        set totalCount to count of messages of b
    end tell
    if totalCount is 0 then return {boxName, {}}
    if totalCount <= limitValue then
        set rows to my historySlice(b, directionValue, accountID, boxName, 1, totalCount)
    else
        set frontCount to (limitValue + 1) div 2
        set backCount to limitValue - frontCount
        set rows to my historySlice(b, directionValue, accountID, boxName, 1, frontCount)
        if backCount > 0 then set rows to rows & my historySlice(b, directionValue, accountID, boxName, totalCount - backCount + 1, totalCount)
    end if
    return {boxName, rows}
end appendHistoryMailbox

-- Get each public property for the bounded range as a column. Never request
-- every message or every property (the latter would also fetch body/source).
-- Rows can race collection changes; hydrate revalidates the retained object
-- against its entire metadata row before and after reading content.
on historySlice(b, directionValue, accountID, boxName, firstIndex, lastIndex)
    set my readFailureStage to 9169
    tell application "Mail"
        set boundedMessages to messages firstIndex thru lastIndex of b
        set my readFailureStage to 9171
        set nativeIDs to id of messages firstIndex thru lastIndex of b
        set my readFailureStage to 9172
        set messageIDs to message id of messages firstIndex thru lastIndex of b
        set my readFailureStage to 9173
        set subjects to subject of messages firstIndex thru lastIndex of b
        set my readFailureStage to 9174
        set senders to sender of messages firstIndex thru lastIndex of b
        set my readFailureStage to 9175
        set sentDates to date sent of messages firstIndex thru lastIndex of b
        set my readFailureStage to 9176
        set receivedDates to date received of messages firstIndex thru lastIndex of b
        set my readFailureStage to 9177
        set sizes to message size of messages firstIndex thru lastIndex of b
    end tell
    set rowCount to lastIndex - firstIndex + 1
    if rowCount < 1 or rowCount > 256 then error "HISTORY_METADATA_BOUND" number 9115
    repeat with columnValues in {boundedMessages, nativeIDs, messageIDs, subjects, senders, sentDates, receivedDates, sizes}
        if (count of contents of columnValues) is not rowCount then error "HISTORY_TARGET_SHAPE" number 9119
    end repeat
    set rows to {}
    repeat with rowIndex from 1 to rowCount
        -- Attachment count is not fetched for metadata. Hydration obtains the
        -- real count for only the chosen messages, without reading attachments.
        set fields to my metadataValues(item rowIndex of nativeIDs, item rowIndex of messageIDs, item rowIndex of subjects, item rowIndex of senders, item rowIndex of sentDates, item rowIndex of receivedDates, item rowIndex of sizes)
        set rowData to {item 1 of fields, accountID, boxName, item 2 of fields, item 3 of fields, item 4 of fields, directionValue, item 5 of fields, item 6 of fields, item 7 of fields, 0}
        set end of rows to rowData
        set end of my historyRecords to {item rowIndex of boundedMessages, rowData}
        if (count of my historyRecords) > 768 then error "HISTORY_METADATA_BOUND" number 9115
    end repeat
    return rows
end historySlice

on captureHistory(requestToken, expectedTarget, limitValue)
    set my readFailureStage to 9166
    set my historyToken to ""
    set my historyRecords to {}
    if limitValue < 1 or limitValue > 256 then error "HISTORY_METADATA_BOUND" number 9115
    set selectedBox to missing value
    if (count of expectedTarget) is 7 then
        if my capturedHistoryMessage is missing value then error "HISTORY_TARGET_MISSING" number 9116
        if not my sameCapturedMetadata(my capturedHistoryMessage, expectedTarget) then error "HISTORY_TARGET_CHANGED" number 9117
        tell application "Mail"
            set my readFailureStage to 9168
            set selectedBox to mailbox of my capturedHistoryMessage
            set my readFailureStage to 9162
            set chosenAccount to account of selectedBox
            if not enabled of chosenAccount then error "HISTORY_ACCOUNT_DISABLED" number 9118
        end tell
    else if (count of expectedTarget) is 0 then
        tell application "Mail"
            set my readFailureStage to 9181
            set accountCount to count of accounts
            if accountCount > 32 then error "HISTORY_SELECT_ACCOUNT" number 9111
            if accountCount is 0 then error "HISTORY_SELECT_ACCOUNT" number 9111
            set boundedAccounts to accounts 1 thru accountCount
        end tell
        set chosenAccount to missing value
        repeat with accountRef in boundedAccounts
            set candidateAccount to contents of accountRef
            set my readFailureStage to 9184
            tell application "Mail" to set enabledAccount to enabled of candidateAccount
            if enabledAccount then
                if chosenAccount is not missing value then error "HISTORY_SELECT_ACCOUNT" number 9111
                set chosenAccount to candidateAccount
            end if
        end repeat
        if chosenAccount is missing value then error "HISTORY_SELECT_ACCOUNT" number 9111
    else
        error "HISTORY_TARGET_SHAPE" number 9119
    end if
    tell application "Mail"
        set my readFailureStage to 9183
        set rawAccountID to get id of chosenAccount
        set my readFailureStage to 9185
        set rawAccountName to get name of chosenAccount
        set my readFailureStage to 9186
        set rawAccountAddresses to get email addresses of chosenAccount
        set my readFailureStage to 9178
        set inboxRoot to inbox
        set my readFailureStage to 9178
        set sentRoot to sent mailbox
    end tell
    set accountID to my mailText(rawAccountID, true, 9183)
    set identityData to {accountID, my mailText(rawAccountName, false, 9185), my mailAddressList(rawAccountAddresses)}
    set inboxBox to my scopedRoleMailbox(inboxRoot, accountID)
    set sentBox to my scopedRoleMailbox(sentRoot, accountID)
    set boxes to {}
    set rows to {}
    if selectedBox is not missing value then
        set resultData to my appendHistoryMailbox(selectedBox, "unknown", accountID, limitValue)
        set end of boxes to item 1 of resultData
        set rows to rows & item 2 of resultData
    end if
    if inboxBox is not missing value then
        set resultData to my appendHistoryMailbox(inboxBox, "received", accountID, limitValue)
        set end of boxes to item 1 of resultData
        set rows to rows & item 2 of resultData
    end if
    if sentBox is not missing value then
        set resultData to my appendHistoryMailbox(sentBox, "sent", accountID, limitValue)
        set end of boxes to item 1 of resultData
        set rows to rows & item 2 of resultData
    end if
    set my historyToken to requestToken
    return {identityData, rows, boxes, requestToken}
end captureHistory

on hydrateHistory(requestToken, expectedRows)
    set my readFailureStage to 9169
    if requestToken is "" or not my strictEqual(requestToken, my historyToken) then error "HISTORY_WINDOW_STALE" number 9120
    if (count of expectedRows) > 20 then error "HISTORY_CONTENT_BOUND" number 9121
    set hydrated to {}
    repeat with rowRef in expectedRows
        set expectedRow to contents of rowRef
        set matchedMessage to missing value
        repeat with cachedRef in my historyRecords
            set cachedRow to contents of cachedRef
            if my strictEqual(item 2 of cachedRow, expectedRow) then
                set matchedMessage to item 1 of cachedRow
                exit repeat
            end if
        end repeat
        if matchedMessage is missing value then error "HISTORY_WINDOW_STALE" number 9120
        set directionValue to item 7 of expectedRow
        set beforeMetadata to my historyMetadata(matchedMessage, directionValue)
        if not my strictEqual(beforeMetadata, expectedRow) then error "HISTORY_MESSAGE_CHANGED" number 9122
        if (item 10 of expectedRow as integer) > 2097152 then error "HISTORY_MESSAGE_LIMIT" number 9123
        tell application "Mail"
            set my readFailureStage to 9179
            set attachmentCount to count of mail attachments of matchedMessage
            set my readFailureStage to 9164
            set rawBody to get content of matchedMessage
            if rawBody is missing value or class of rawBody is list then error "MAIL_BODY_SHAPE" number 9164
            set plainBody to rawBody as text
            set my readFailureStage to 9165
            set rawHeaders to get all headers of matchedMessage
            set plainHeaders to my mailText(rawHeaders, false, 9165)
            set my readFailureStage to 9179
            if (count of mail attachments of matchedMessage) is not attachmentCount then error "HISTORY_MESSAGE_CHANGED" number 9122
        end tell
        if (count of characters of plainBody) + (count of characters of plainHeaders) > 2097152 then error "HISTORY_MESSAGE_LIMIT" number 9123
        set afterMetadata to my historyMetadata(matchedMessage, directionValue)
        if not my strictEqual(afterMetadata, expectedRow) then error "HISTORY_MESSAGE_CHANGED" number 9122
        -- Return the real final metadata, not the expected row, so the Swift
        -- decoder independently verifies the native checkpoint as well.
        set end of hydrated to {afterMetadata, plainBody, plainHeaders, attachmentCount}
    end repeat
    return hydrated
end hydrateHistory

-- Full catalog discovery uses only bounded folder work and persistent DFS
-- positions. Mail folder names are not filesystem paths.
on indexAccountID(b)
    set my readFailureStage to 9162
    my bodyMetricGet()
    tell application "Mail" to set a to get account of b
    if a is missing value then return "__harborreply_local__"
    set my readFailureStage to 9183
    my bodyMetricGet()
    tell application "Mail" to set rawID to get id of a
    return my mailText(rawID, true, 9183)
end indexAccountID

-- Some Mail providers enumerate a mailbox but reject its name specifier.
-- Resolve only within the exact parent; never use a global same-name fallback.
on indexChildMailbox(parentBox, wantedName)
    set my readFailureStage to 9168
    try
        tell application "Mail" to return mailbox wantedName of parentBox
    on error number n
        if n is not -1728 then error "INDEX_MAILBOX_LOOKUP" number n
    end try
    tell application "Mail"
        my bodyMetricGet()
        set childCount to count of mailboxes of parentBox
        set matchBox to missing value
        repeat with childIndex from 1 to childCount
            my bodyMetricGet()
            set candidateBox to mailbox childIndex of parentBox
            my bodyMetricGet()
            if my strictEqual(name of candidateBox as text, wantedName) then
                if matchBox is not missing value then error "INDEX_MAILBOX_AMBIGUOUS" number 9130
                set matchBox to candidateBox
            end if
        end repeat
    end tell
    if matchBox is missing value then error "INDEX_MAILBOX_MISSING" number -1728
    return matchBox
end indexChildMailbox

on indexMailbox(accountID, pathNames, localValue)
    set my readFailureStage to 9168
    if (count of pathNames) < 1 or (count of pathNames) > 32 then error "INDEX_LOCATOR_SHAPE" number 9133
    tell application "Mail"
        if localValue then
            if not my strictEqual(accountID, "__harborreply_local__") then error "INDEX_LOCATOR_SHAPE" number 9133
            set my readFailureStage to 9168
            my bodyMetricGet()
            set b to my indexChildMailbox(application "Mail", item 1 of pathNames)
        else
            my bodyMetricGet()
            set a to account id accountID
            set my readFailureStage to 9183
            my bodyMetricGet()
            if not my strictEqual(id of a as text, accountID) then error "INDEX_ACCOUNT_CHANGED" number 9130
            set my readFailureStage to 9168
            my bodyMetricGet()
            set b to my indexChildMailbox(a, item 1 of pathNames)
        end if
        set my readFailureStage to 9187
        my bodyMetricGet()
        if not my strictEqual(name of b as text, item 1 of pathNames) then error "INDEX_MAILBOX_CHANGED" number 9130
        if (count of pathNames) > 1 then
            repeat with pathIndex from 2 to count of pathNames
                set my readFailureStage to 9168
                my bodyMetricGet()
                set b to my indexChildMailbox(b, item pathIndex of pathNames)
                set my readFailureStage to 9187
                my bodyMetricGet()
                if not my strictEqual(name of b as text, item pathIndex of pathNames) then error "INDEX_MAILBOX_CHANGED" number 9130
            end repeat
        end if
    end tell
    if not my strictEqual(my indexAccountID(b), accountID) then error "INDEX_ACCOUNT_CHANGED" number 9130
    return b
end indexMailbox

on indexParent(accountID, pathNames, localValue)
    set my readFailureStage to 9168
    if (count of pathNames) > 0 then return my indexMailbox(accountID, pathNames, localValue)
    tell application "Mail"
        if localValue then return application "Mail"
        set a to account id accountID
        set my readFailureStage to 9183
        if not my strictEqual(id of a as text, accountID) then error "INDEX_ACCOUNT_CHANGED" number 9130
        return a
    end tell
end indexParent

on indexVirtualRoot(b)
    set my readFailureStage to 9178
    tell application "Mail"
        repeat with roleBox in {inbox, sent mailbox, drafts mailbox, junk mailbox, trash mailbox, outbox}
            if my strictEqual(b, contents of roleBox) then return true
        end repeat
    end tell
    return false
end indexVirtualRoot

on indexRole(b, accountID, localValue)
    set my readFailureStage to 9178
    if localValue then return "unknown"
    tell application "Mail"
        set my readFailureStage to 9178
        my bodyMetricGet()
        set sentRoot to sent mailbox
        set my readFailureStage to 9178
        my bodyMetricGet()
        set inboxRoot to inbox
    end tell
    -- Role access can be unavailable/ambiguous even when a regular folder is
    -- readable. Such folders remain unknown, never guessed to be Sent.
    try
        set actualSent to my scopedRoleMailbox(sentRoot, accountID)
        if actualSent is not missing value and my strictEqual(b, actualSent) then return "sent"
    end try
    try
        set actualInbox to my scopedRoleMailbox(inboxRoot, accountID)
        if actualInbox is not missing value and my strictEqual(b, actualInbox) then return "received"
    end try
    return "unknown"
end indexRole

-- Cursor: {scanID, accountOffset, expectedAccountCount, localPhase, DFS frames}.
-- Frame: {accountID, parentPath, nextChild, expectedChildCount, isLocal}.
on indexDiscover(cursorData, limitValue)
    set my readFailureStage to 9168
    if limitValue < 1 or limitValue > 32 or (count of cursorData) is not 5 then error "INDEX_BOUND" number 9131
    set scanToken to item 1 of cursorData
    set accountPosition to item 2 of cursorData
    set expectedAccounts to item 3 of cursorData
    set localPhase to item 4 of cursorData
    set frontier to item 5 of cursorData
    if accountPosition < 0 or (count of frontier) > 32 then error "INDEX_LOCATOR_SHAPE" number 9133
    set my readFailureStage to 9181
    tell application "Mail" to set accountCount to count of accounts
    if expectedAccounts >= 0 and expectedAccounts is not accountCount then error "INDEX_CURSOR_CHANGED" number 9130
    if accountPosition > accountCount then error "INDEX_CURSOR_CHANGED" number 9130
    set resultBoxes to {}
    set resultAccounts to {}
    set workCount to 0
    set finished to false
    repeat while (count of resultBoxes) < limitValue and (count of resultAccounts) < 32 and workCount < 64
        set workCount to workCount + 1
        if (count of frontier) is 0 then
            if not localPhase then
                if accountPosition < accountCount then
                    tell application "Mail"
                        set a to account (accountPosition + 1)
                        set my readFailureStage to 9183
                        set rawAccountID to get id of a
                        set my readFailureStage to 9185
                        set rawAccountName to get name of a
                        set my readFailureStage to 9186
                        set rawAccountAddresses to get email addresses of a
                    end tell
                    set accountID to my mailText(rawAccountID, true, 9183)
                    set end of resultAccounts to {accountID, my mailText(rawAccountName, false, 9185), my mailAddressList(rawAccountAddresses)}
                    set accountPosition to accountPosition + 1
                    set frontier to {{accountID, {}, 0, -1, false}}
                else
                    set localPhase to true
                    set frontier to {{"__harborreply_local__", {}, 0, -1, true}}
                    set end of resultAccounts to {"__harborreply_local__", "On My Mac", {}}
                end if
            else
                set finished to true
                exit repeat
            end if
        end if
        set frameIndex to count of frontier
        set frameData to item frameIndex of frontier
        set accountID to item 1 of frameData
        set parentPath to item 2 of frameData
        set childPosition to item 3 of frameData
        set expectedChildren to item 4 of frameData
        set localValue to item 5 of frameData
        set parentBox to my indexParent(accountID, parentPath, localValue)
        set my readFailureStage to 9182
        tell application "Mail" to set childCount to count of mailboxes of parentBox
        if expectedChildren >= 0 and expectedChildren is not childCount then error "INDEX_CURSOR_CHANGED" number 9130
        if childPosition > childCount then error "INDEX_CURSOR_CHANGED" number 9130
        if childPosition is childCount then
            if frameIndex is 1 then
                set frontier to {}
            else
                set frontier to items 1 thru (frameIndex - 1) of frontier
            end if
        else
            tell application "Mail"
                set my readFailureStage to 9168
                set b to mailbox (childPosition + 1) of parentBox
                set my readFailureStage to 9187
                set boxName to name of b as text
            end tell
            set item frameIndex of frontier to {accountID, parentPath, childPosition + 1, childCount, localValue}
            set includeBox to my strictEqual(my indexAccountID(b), accountID)
            if localValue and my indexVirtualRoot(b) then set includeBox to false
            if includeBox then
                set fullPath to parentPath & {boxName}
                if (count of fullPath) > 32 then error "INDEX_BOUND" number 9131
                tell application "Mail"
                    set my readFailureStage to 9180
                    set messageCount to count of messages of b
                    set my readFailureStage to 9182
                    set descendantCount to count of mailboxes of b
                end tell
                set roleValue to my indexRole(b, accountID, localValue)
                set end of resultBoxes to {accountID, fullPath, boxName, messageCount as text, roleValue, localValue}
                if descendantCount > 0 then set end of frontier to {accountID, fullPath, 0, descendantCount, localValue}
            end if
            set my readFailureStage to 9182
            tell application "Mail" to set afterChildren to count of mailboxes of parentBox
            if afterChildren is not childCount then error "INDEX_CURSOR_CHANGED" number 9130
        end if
    end repeat
    set my readFailureStage to 9181
    tell application "Mail" to set afterAccounts to count of accounts
    if afterAccounts is not accountCount then error "INDEX_CURSOR_CHANGED" number 9130
    set nextData to {}
    if not finished then set nextData to {scanToken, accountPosition, accountCount, localPhase, frontier}
    return {scanToken, resultBoxes, resultAccounts, nextData}
end indexDiscover

-- Locator: {accountID, path, nativeID, Message-ID, subject, sender, dates,
-- message size, genuine role, isLocal, scanID}. Bodies are not fetched here.
on indexMetadata(m, accountID, pathNames, localValue, scanToken)
    set my readFailureStage to 9168
    my bodyMetricGet()
    tell application "Mail" to set actualBox to get mailbox of m
    set fields to my messageMetadataValues(m)
    set expectedBox to my indexMailbox(accountID, pathNames, localValue)
    if not my strictEqual(actualBox, expectedBox) then error "INDEX_MESSAGE_CHANGED" number 9132
    set roleValue to my indexRole(actualBox, accountID, localValue)
    return {accountID, pathNames, item 1 of fields, item 2 of fields, item 3 of fields, item 4 of fields, item 5 of fields, item 6 of fields, item 7 of fields, roleValue, localValue, scanToken}
end indexMetadata

-- Native IDs use direct property reads from the outset. The range-ID path
-- has repeatedly failed in Mail without reaching the compatibility fallback.
-- Other properties retain their range fast path and fixed capability cache.
on indexColumnValues(b, firstIndex, lastIndex, stageNumber, reader)
    set rowCount to lastIndex - firstIndex + 1
    if firstIndex < 1 or rowCount < 1 or rowCount > 128 or stageNumber < 9171 or stageNumber > 9177 then error "INDEX_BOUND" number 9131
    if stageNumber is not 9171 and reader's indexUsesRange(stageNumber) then
        set rangeHandled to false
        try
            set columnValues to reader's indexRangeColumn(b, firstIndex, lastIndex, stageNumber)
            set rangeHandled to true
        on error number errorNumber
            if errorNumber is not -1708 then error "INDEX_COLUMN_READ_FAILED" number errorNumber
            reader's indexDisableRange(stageNumber)
        end try
        if rangeHandled then
            if class of columnValues is not list then error "INDEX_PAGE_SHAPE" number 9134
            if (count of columnValues) is not rowCount then error "INDEX_PAGE_SHAPE" number 9134
            return columnValues
        end if
    end if
    set columnValues to {}
    repeat with messagePosition from firstIndex to lastIndex
        set end of columnValues to reader's indexScalarColumn(b, messagePosition as integer, stageNumber)
    end repeat
    return columnValues
end indexColumnValues

on indexUsesRange(stageNumber)
    set my readFailureStage to 9194
    return stageNumber is not in my indexUnsupportedColumns
end indexUsesRange

on indexDisableRange(stageNumber)
    set my readFailureStage to 9195
    if stageNumber is not in my indexUnsupportedColumns then set end of my indexUnsupportedColumns to stageNumber
end indexDisableRange

on indexRangeColumn(b, firstIndex, lastIndex, stageNumber)
    set my readFailureStage to stageNumber
    my bodyMetricGet()
    tell application "Mail"
        if stageNumber is 9171 then return get id of (messages firstIndex thru lastIndex of b)
        if stageNumber is 9172 then return get message id of (messages firstIndex thru lastIndex of b)
        if stageNumber is 9173 then return get subject of (messages firstIndex thru lastIndex of b)
        if stageNumber is 9174 then return get sender of (messages firstIndex thru lastIndex of b)
        if stageNumber is 9175 then return get date sent of (messages firstIndex thru lastIndex of b)
        if stageNumber is 9176 then return get date received of (messages firstIndex thru lastIndex of b)
        if stageNumber is 9177 then return get message size of (messages firstIndex thru lastIndex of b)
    end tell
    error "INDEX_LOCATOR_SHAPE" number 9133
end indexRangeColumn

on indexScalarColumn(b, messagePosition, stageNumber)
    set my readFailureStage to stageNumber + 130
    my bodyMetricGet()
    tell application "Mail"
        -- Keep the specifier without a redundant bare-message GET. Mail need
        -- only handle the following property GET, not object acquisition.
        set m to a reference to «class mssg» messagePosition of b
        if stageNumber is 9171 then return get id of m
        if stageNumber is 9172 then return get message id of m
        if stageNumber is 9173 then return get subject of m
        if stageNumber is 9174 then return get sender of m
        if stageNumber is 9175 then return get date sent of m
        if stageNumber is 9176 then return get date received of m
        if stageNumber is 9177 then return get message size of m
    end tell
    error "INDEX_LOCATOR_SHAPE" number 9133
end indexScalarColumn

on indexPageCheckpoint(beforeCount, afterCount, nativeIDs, afterIDs)
    if afterCount is not beforeCount then error "INDEX_CURSOR_CHANGED" number 9130
    if not my strictEqual(nativeIDs, afterIDs) then error "INDEX_CURSOR_CHANGED" number 9130
end indexPageCheckpoint

on indexHeaderPage(cursorData, limitValue)
    set my readFailureStage to 9168
    if limitValue < 1 or limitValue > 128 or (count of cursorData) is not 7 then error "INDEX_BOUND" number 9131
    set accountID to item 1 of cursorData
    set pathNames to item 2 of cursorData
    set startOffset to item 3 of cursorData
    set expectedTotal to item 4 of cursorData
    set scanToken to item 5 of cursorData
    set localValue to item 6 of cursorData
    set b to my indexMailbox(accountID, pathNames, localValue)
    set my readFailureStage to 9180
    tell application "Mail" to set beforeCount to count of messages of b
    if startOffset < 0 or startOffset > beforeCount then error "INDEX_CURSOR_CHANGED" number 9130
    if expectedTotal >= 0 and expectedTotal is not beforeCount then error "INDEX_CURSOR_CHANGED" number 9130
    set pageCount to beforeCount - startOffset
    if pageCount > limitValue then set pageCount to limitValue
    set roleValue to my indexRole(b, accountID, localValue)
    set my readFailureStage to 9169
    set rows to {}
    set nativeIDs to {}
    set afterIDs to {}
    if pageCount > 0 then
        set firstIndex to startOffset + 1
        set lastIndex to startOffset + pageCount
        set nativeIDs to my indexColumnValues(b, firstIndex, lastIndex, 9171, me)
        set messageIDs to my indexColumnValues(b, firstIndex, lastIndex, 9172, me)
        set subjects to my indexColumnValues(b, firstIndex, lastIndex, 9173, me)
        set senders to my indexColumnValues(b, firstIndex, lastIndex, 9174, me)
        set sentDates to my indexColumnValues(b, firstIndex, lastIndex, 9175, me)
        set receivedDates to my indexColumnValues(b, firstIndex, lastIndex, 9176, me)
        set sizes to my indexColumnValues(b, firstIndex, lastIndex, 9177, me)
        set afterIDs to my indexColumnValues(b, firstIndex, lastIndex, 9171, me)
        -- Count the repeat-item reference directly. The compound expression
        -- "count of contents of" fails with -1708 even for local lists.
        set my readFailureStage to 9193
        repeat with columnValues in {nativeIDs, messageIDs, subjects, senders, sentDates, receivedDates, sizes, afterIDs}
            if (count of columnValues) is not pageCount then error "INDEX_PAGE_SHAPE" number 9134
        end repeat
        repeat with rowIndex from 1 to pageCount
            -- A failure while dereferencing/validating returned fields must
            -- not inherit the preceding ordered-ID getter's stage.
            set my readFailureStage to 9193
            set fields to my metadataValues(item rowIndex of nativeIDs, item rowIndex of messageIDs, item rowIndex of subjects, item rowIndex of senders, item rowIndex of sentDates, item rowIndex of receivedDates, item rowIndex of sizes)
            set end of rows to {accountID, pathNames, item 1 of fields, item 2 of fields, item 3 of fields, item 4 of fields, item 5 of fields, item 6 of fields, item 7 of fields, roleValue, localValue, scanToken}
        end repeat
    end if
    set my readFailureStage to 9180
    tell application "Mail" to set afterCount to count of messages of b
    my indexPageCheckpoint(beforeCount, afterCount, nativeIDs, afterIDs)
    set nextData to {}
    if startOffset + pageCount < beforeCount then set nextData to {accountID, pathNames, startOffset + pageCount, beforeCount, scanToken, localValue, roleValue}
    return {{accountID, pathNames, item -1 of pathNames, beforeCount as text, roleValue, localValue}, rows, nextData, scanToken}
end indexHeaderPage

-- Direct native IDs only: no whose query or full-mailbox search. Individual
-- failures stay visible so one missing/large message does not abort the archive.
on indexHydrate(expectedRows)
    set my readFailureStage to 9169
    if (count of expectedRows) > 20 then error "INDEX_BOUND" number 9131
    set results to {}
    repeat with rowRef in expectedRows
        set expectedRow to contents of rowRef
        try
            if (count of expectedRow) is not 12 then error "INDEX_LOCATOR_SHAPE" number 9133
            if (item 9 of expectedRow as integer) > 2097152 then error "INDEX_MESSAGE_LIMIT" number 9135
            set accountID to item 1 of expectedRow
            set pathNames to item 2 of expectedRow
            set localValue to item 11 of expectedRow
            set scanToken to item 12 of expectedRow
            my bodyMetricPhase(1)
            set b to my indexMailbox(accountID, pathNames, localValue)
            set my readFailureStage to 9171
            set requestedID to item 3 of expectedRow as integer
            -- The literal class code disambiguates native unique-ID lookup
            -- from Mail's separate two-word "message id" header property.
            set my readFailureStage to 9188
            tell application "Mail" to set m to a reference to «class mssg» id requestedID of b
            set beforeMetadata to my indexMetadata(m, accountID, pathNames, localValue, scanToken)
            if not my strictEqual(beforeMetadata, expectedRow) then error "INDEX_MESSAGE_CHANGED" number 9132
            set my readFailureStage to 9170
            tell application "Mail"
                set my readFailureStage to 9179
                my bodyMetricGet()
                set attachmentCount to count of mail attachments of m
                set my readFailureStage to 9164
                my bodyMetricPhase(2)
                my bodyMetricGet()
                set rawBody to get content of m
                if rawBody is missing value or class of rawBody is list then error "MAIL_BODY_SHAPE" number 9164
                set plainBody to rawBody as text
                set my readFailureStage to 9165
                my bodyMetricPhase(3)
                my bodyMetricGet()
                set rawHeaders to get all headers of m
                set plainHeaders to my mailText(rawHeaders, false, 9165)
                set my readFailureStage to 9179
                my bodyMetricPhase(4)
                my bodyMetricGet()
                if (count of mail attachments of m) is not attachmentCount then error "INDEX_MESSAGE_CHANGED" number 9132
            end tell
            if (count of characters of plainBody) + (count of characters of plainHeaders) > 2097152 then error "INDEX_MESSAGE_LIMIT" number 9135
            set afterMetadata to my indexMetadata(m, accountID, pathNames, localValue, scanToken)
            if not my strictEqual(afterMetadata, expectedRow) then error "INDEX_MESSAGE_CHANGED" number 9132
            set end of results to {afterMetadata, plainBody, plainHeaders, attachmentCount, "", 0, 0}
        on error errorText number errorNumber
            -- Never return Mail's error text; it may contain private data.
            set failureValue to "MAIL_INDEX_READ_UNAVAILABLE"
            if errorNumber is -1728 then set failureValue to "MAIL_INDEX_MESSAGE_NOT_FOUND"
            if errorNumber is 9130 or errorNumber is 9132 then set failureValue to "MAIL_INDEX_MESSAGE_CHANGED"
            if errorNumber is 9133 then set failureValue to "MAIL_INDEX_INVALID_LOCATOR"
            if errorNumber is 9135 then set failureValue to "MAIL_INDEX_MESSAGE_TOO_LARGE"
            if errorNumber is -1700 then set failureValue to "MAIL_INDEX_BODY_COERCION"
            if errorNumber is -1700 and my readFailureStage is 9168 then set failureValue to "MAIL_INDEX_MAILBOX_COERCION"
            if errorNumber is -1700 and (my readFailureStage is 9169 or (my readFailureStage >= 9171 and my readFailureStage <= 9177)) then set failureValue to "MAIL_INDEX_METADATA_COERCION"
            if errorNumber >= 9171 and errorNumber <= 9177 then set failureValue to "MAIL_INDEX_METADATA_COERCION"
            if errorNumber is 9164 or errorNumber is 9165 then set failureValue to "MAIL_INDEX_BODY_COERCION"
            set failureEnvelope to my mailFailureEnvelope(errorNumber, my readFailureStage)
            set end of results to {expectedRow, "", "", 0, failureValue, item 2 of failureEnvelope, item 3 of failureEnvelope}
        end try
    end repeat
    return results
end indexHydrate


-- One scope resolution/role check for a bounded batch, checked again afterward.
on bodyScope(expectedRows)
    set firstRow to item 1 of expectedRows
    set accountID to item 1 of firstRow
    set pathNames to item 2 of firstRow
    set localValue to item 11 of firstRow
    set b to my indexMailbox(accountID, pathNames, localValue)
    set actualRole to my indexRole(b, accountID, localValue)
    if not my strictEqual(actualRole, item 10 of firstRow) then error "INDEX_MESSAGE_CHANGED" number 9132
    return b
end bodyScope

on bodyMessageCount(b)
    set my readFailureStage to 9180
    my bodyMetricGet()
    tell application "Mail" to return count of messages of b
end bodyMessageCount

on bodyMessageBox(b, messagePosition)
    set my readFailureStage to 9168
    my bodyMetricGet()
    tell application "Mail" to return get mailbox of («class mssg» messagePosition of b)
end bodyMessageBox

on bodyAttachmentCount(b, messagePosition)
    set my readFailureStage to 9179
    my bodyMetricGet()
    tell application "Mail" to return count of mail attachments of («class mssg» messagePosition of b)
end bodyAttachmentCount

on bodyRangeColumn(b, firstIndex, lastIndex, stageNumber)
    set my readFailureStage to stageNumber
    my bodyMetricGet()
    tell application "Mail"
        if stageNumber is 9164 then return get content of (messages firstIndex thru lastIndex of b)
        if stageNumber is 9165 then return get all headers of (messages firstIndex thru lastIndex of b)
    end tell
    error "INDEX_LOCATOR_SHAPE" number 9133
end bodyRangeColumn

-- No object GET or full-collection query. Native IDs remain scalar witnesses;
-- other bounded metadata columns use the established narrow -1708 fallback.
on bodyCheckpoint(b, expectedRows, firstIndex, expectedCount, reader)
    set rowCount to count of expectedRows
    set lastIndex to firstIndex + rowCount - 1
    if reader's bodyMessageCount(b) is not expectedCount then error "INDEX_CURSOR_CHANGED" number 9130
    set columns to {}
    repeat with stageRef in {9171, 9172, 9173, 9174, 9175, 9176, 9177}
        set stageNumber to stageRef as integer
        set values to reader's indexColumnValues(b, firstIndex, lastIndex, stageNumber, reader)
        if class of values is not list then error "INDEX_PAGE_SHAPE" number 9134
        if (count of values) is not rowCount then error "INDEX_PAGE_SHAPE" number 9134
        set end of columns to values
    end repeat
    set rows to {}
    set attachments to {}
    repeat with rowIndex from 1 to rowCount
        set my readFailureStage to 9193
        set expectedRow to item rowIndex of expectedRows
        set messagePosition to firstIndex + rowIndex - 1
        set actualBox to reader's bodyMessageBox(b, messagePosition)
        if not my strictEqual(actualBox, b) then error "INDEX_MESSAGE_CHANGED" number 9132
        set fields to my metadataValues(item rowIndex of item 1 of columns, item rowIndex of item 2 of columns, item rowIndex of item 3 of columns, item rowIndex of item 4 of columns, item rowIndex of item 5 of columns, item rowIndex of item 6 of columns, item rowIndex of item 7 of columns)
        set actualRow to {item 1 of expectedRow, item 2 of expectedRow, item 1 of fields, item 2 of fields, item 3 of fields, item 4 of fields, item 5 of fields, item 6 of fields, item 7 of fields, item 10 of expectedRow, item 11 of expectedRow, item 12 of expectedRow}
        if not my strictEqual(actualRow, expectedRow) then error "INDEX_MESSAGE_CHANGED" number 9132
        set attachmentCount to reader's bodyAttachmentCount(b, messagePosition)
        if class of attachmentCount is not integer or attachmentCount < 0 then error "INDEX_PAGE_SHAPE" number 9134
        set end of attachments to attachmentCount
        set end of rows to actualRow
    end repeat
    return {rows, attachments}
end bodyCheckpoint

on bodyColumnTexts(rawValues, rowCount, stageNumber)
    set my readFailureStage to stageNumber
    if class of rawValues is not list then error "MAIL_BODY_SHAPE" number stageNumber
    if (count of rawValues) is not rowCount then error "MAIL_BODY_SHAPE" number stageNumber
    set values to {}
    repeat with valueRef in rawValues
        set rawValue to contents of valueRef
        if stageNumber is 9164 and rawValue is missing value then error "MAIL_BODY_SHAPE" number stageNumber
        if class of rawValue is list then error "MAIL_BODY_SHAPE" number stageNumber
        set end of values to my mailText(rawValue, false, stageNumber)
    end repeat
    return values
end bodyColumnTexts

on bodyValidateRows(expectedRows, firstIndex, expectedCount)
    set rowCount to count of expectedRows
    if rowCount < 1 or rowCount > 4 then error "INDEX_BOUND" number 9131
    set firstRow to item 1 of expectedRows
    set sizeTotal to 0
    set ids to {}
    repeat with rowRef in expectedRows
        set rowValue to contents of rowRef
        if (count of rowValue) is not 12 then error "INDEX_LOCATOR_SHAPE" number 9133
        repeat with positionRef in {1, 2, 10, 11, 12}
            set positionValue to positionRef as integer
            if not my strictEqual(item positionValue of rowValue, item positionValue of firstRow) then error "INDEX_LOCATOR_SHAPE" number 9133
        end repeat
        set sizeValue to item 9 of rowValue as integer
        if sizeValue < 0 or sizeValue > 2097152 then error "INDEX_MESSAGE_LIMIT" number 9135
        set sizeTotal to sizeTotal + sizeValue
        set idValue to item 3 of rowValue
        if idValue is in ids then error "INDEX_LOCATOR_SHAPE" number 9133
        set end of ids to idValue
    end repeat
    if sizeTotal > 2097152 then error "INDEX_MESSAGE_LIMIT" number 9135
    if firstIndex < 1 or expectedCount < firstIndex + rowCount - 1 then error "INDEX_LOCATOR_SHAPE" number 9133
end bodyValidateRows

-- Testable shipping orchestration: two true property-column GETs between exact
-- ordered metadata/attachment/count checkpoints. No per-body GET on this path.
on indexHydrateBatch(expectedRows, firstIndex, expectedCount, reader)
    my bodyValidateRows(expectedRows, firstIndex, expectedCount)
    set rowCount to count of expectedRows
    set lastIndex to firstIndex + rowCount - 1
    my bodyMetricPhase(1)
    set b to reader's bodyScope(expectedRows)
    set beforeCheckpoint to my bodyCheckpoint(b, expectedRows, firstIndex, expectedCount, reader)
    my bodyMetricPhase(2)
    set rawBodies to reader's bodyRangeColumn(b, firstIndex, lastIndex, 9164)
    set bodies to my bodyColumnTexts(rawBodies, rowCount, 9164)
    my bodyMetricPhase(3)
    set rawHeaders to reader's bodyRangeColumn(b, firstIndex, lastIndex, 9165)
    set headers to my bodyColumnTexts(rawHeaders, rowCount, 9165)
    set sizeTotal to 0
    repeat with rowIndex from 1 to rowCount
        set sizeTotal to sizeTotal + (count of characters of item rowIndex of bodies) + (count of characters of item rowIndex of headers)
    end repeat
    if sizeTotal > 2097152 then error "INDEX_MESSAGE_LIMIT" number 9135
    my bodyMetricPhase(4)
    set afterBox to reader's bodyScope(expectedRows)
    if not my strictEqual(afterBox, b) then error "INDEX_MESSAGE_CHANGED" number 9132
    set afterCheckpoint to my bodyCheckpoint(afterBox, expectedRows, firstIndex, expectedCount, reader)
    if not my strictEqual(beforeCheckpoint, afterCheckpoint) then error "INDEX_MESSAGE_CHANGED" number 9132
    set results to {}
    repeat with rowIndex from 1 to rowCount
        set end of results to {item rowIndex of item 1 of afterCheckpoint, item rowIndex of bodies, item rowIndex of headers, item rowIndex of item 2 of afterCheckpoint, "", 0, 0}
    end repeat
    return results
end indexHydrateBatch

-- Only a native unsupported body/header range permits a scalar retry. Metadata,
-- shape, identity, count, permissions, timeout and coercion failures never do.
on bodyRangeEnabled()
    return my bodyUnsupportedRanges is {}
end bodyRangeEnabled

on bodyDisableRange(stageNumber)
    if stageNumber is not in my bodyUnsupportedRanges then set end of my bodyUnsupportedRanges to stageNumber
end bodyDisableRange

on bodyScalarHydrate(expectedRows)
    return my indexHydrate(expectedRows)
end bodyScalarHydrate

on bodyHydrateDispatch(expectedRows, firstIndex, expectedCount, reader)
    my bodyValidateRows(expectedRows, firstIndex, expectedCount)
    my bodyMetricBegin()
    if not reader's bodyRangeEnabled() then
        set rows to reader's bodyScalarHydrate(expectedRows)
        return {"HARBOR_MAIL_BODY_V1", rows, {my bodyMetricResult("scalar_fallback", count of expectedRows)}}
    end if
    try
        set rows to my indexHydrateBatch(expectedRows, firstIndex, expectedCount, reader)
        return {"HARBOR_MAIL_BODY_V1", rows, {my bodyMetricResult("bulk", count of expectedRows)}}
    on error number errorNumber
        set failedStage to my readFailureStage
        set failedMetrics to my bodyMetricResult("bulk", count of expectedRows)
        if errorNumber is not -1708 or (failedStage is not 9164 and failedStage is not 9165) then error "INDEX_BATCH_FAILED" number errorNumber
        reader's bodyDisableRange(failedStage)
        my bodyMetricBegin()
        set rows to reader's bodyScalarHydrate(expectedRows)
        return {"HARBOR_MAIL_BODY_V1", rows, {failedMetrics, my bodyMetricResult("scalar_fallback", count of expectedRows)}}
    end try
end bodyHydrateDispatch

on measuredHydrateBatch(expectedRows, firstIndex, expectedCount)
    return my bodyHydrateDispatch(expectedRows, firstIndex, expectedCount, me)
end measuredHydrateBatch


on bodyDirectMetadata(m, b, expectedRow)
    set my readFailureStage to 9168
    my bodyMetricGet()
    tell application "Mail" to set actualBox to get mailbox of m
    if not my strictEqual(actualBox, b) then error "INDEX_MESSAGE_CHANGED" number 9132
    set fields to my messageMetadataValues(m)
    return {item 1 of expectedRow, item 2 of expectedRow, item 1 of fields, item 2 of fields, item 3 of fields, item 4 of fields, item 5 of fields, item 6 of fields, item 7 of fields, item 10 of expectedRow, item 11 of expectedRow, item 12 of expectedRow}
end bodyDirectMetadata

-- Cached bodies remain immutable capture snapshots. These checks establish live
-- metadata/attachment identity, not current body-byte freshness without a GET.
on validateCachedRows(expectedRows, expectedAttachments)
    my bodyMetricBegin()
    set rowCount to count of expectedRows
    if rowCount < 1 or rowCount > 4 or (count of expectedAttachments) is not rowCount then error "INDEX_BOUND" number 9131
    set flags to {}
    my bodyMetricPhase(1)
    set b to my bodyScope(expectedRows)
    set firstCount to my bodyMessageCount(b)
    repeat with rowIndex from 1 to rowCount
        set expectedRow to item rowIndex of expectedRows
        set flagValue to false
        try
            set requestedID to item 3 of expectedRow as integer
            set my readFailureStage to 9188
            tell application "Mail" to set m to a reference to «class mssg» id requestedID of b
            set firstMetadata to my bodyDirectMetadata(m, b, expectedRow)
            my bodyMetricGet()
            set my readFailureStage to 9179
            tell application "Mail" to set firstAttachments to count of mail attachments of m
            my bodyMetricPhase(4)
            set secondMetadata to my bodyDirectMetadata(m, b, expectedRow)
            my bodyMetricGet()
            set my readFailureStage to 9179
            tell application "Mail" to set secondAttachments to count of mail attachments of m
            set expectedAttachmentCount to item rowIndex of expectedAttachments
            set flagValue to my strictEqual(firstMetadata, expectedRow) and my strictEqual(secondMetadata, expectedRow) and firstAttachments is expectedAttachmentCount and secondAttachments is expectedAttachmentCount
        on error number errorNumber
            if errorNumber is not -1728 and errorNumber is not 9130 and errorNumber is not 9132 then error "CACHE_VALIDATION_FAILED" number errorNumber
        end try
        set end of flags to flagValue
        my bodyMetricPhase(1)
    end repeat
    my bodyMetricPhase(4)
    set afterBox to my bodyScope(expectedRows)
    if not my strictEqual(b, afterBox) or my bodyMessageCount(afterBox) is not firstCount then set flags to {}
    if flags is {} then repeat rowCount times
        set end of flags to false
    end repeat
    return {"HARBOR_MAIL_CACHE_V1", flags, {my bodyMetricResult("cache_validation", rowCount)}}
end validateCachedRows

-- Style sampling deliberately collects only sender/size columns and content.
-- Positional samples are not evidence locators and never authorize insertion.
on styleContentsScope(cursorData)
    if class of cursorData is not list or (count of cursorData) is not 7 then error "STYLE_INPUT_SHAPE" number 9133
    if item 6 of cursorData is not false or item 7 of cursorData is not "sent" then error "STYLE_INPUT_SHAPE" number 9133
    -- This local key is capture scope, not a per-message identity witness.
    set keyValue to {item 5 of cursorData, item 1 of cursorData, item 2 of cursorData}
    if my styleContentsScopeValue is not missing value and my strictEqual(my styleContentsScopeKey, keyValue) then return my styleContentsScopeValue
    set my styleContentsScopeKey to missing value
    set my styleContentsScopeValue to missing value
    set b to my indexMailbox(item 1 of cursorData, item 2 of cursorData, false)
    set my styleContentsScopeValue to b
    set my styleContentsScopeKey to keyValue
    return b
end styleContentsScope

on styleMessageCount(b)
    set my readFailureStage to 9180
    my bodyMetricGet()
    tell application "Mail" to return count of messages of b
end styleMessageCount

on styleSenderColumn(b, firstIndex, lastIndex)
    set my readFailureStage to 9174
    my bodyMetricGet()
    tell application "Mail" to return get sender of (messages firstIndex thru lastIndex of b)
end styleSenderColumn

on styleSizeColumn(b, firstIndex, lastIndex)
    set my readFailureStage to 9177
    my bodyMetricGet()
    tell application "Mail" to return get message size of (messages firstIndex thru lastIndex of b)
end styleSizeColumn

on styleCandidatePage(cursorData, limitValue, reader)
    if class of limitValue is not integer or limitValue < 1 or limitValue > 128 then error "STYLE_INPUT_BOUND" number 9131
    my bodyMetricBegin()
    my bodyMetricPhase(1)
    set b to reader's styleContentsScope(cursorData)
    set total to reader's styleMessageCount(b)
    set firstIndex to (item 3 of cursorData) + 1
    if class of total is not integer or total < 0 or total > 2147483647 or firstIndex < 1 or firstIndex > total + 1 then error "STYLE_PAGE_SHAPE" number 9134
    set rowCount to limitValue
    if rowCount > total - firstIndex + 1 then set rowCount to total - firstIndex + 1
    set rows to {}
    if rowCount > 0 then
        set lastIndex to firstIndex + rowCount - 1
        set senders to reader's styleSenderColumn(b, firstIndex, lastIndex)
        set sizes to reader's styleSizeColumn(b, firstIndex, lastIndex)
        if class of senders is not list or class of sizes is not list then error "STYLE_PAGE_SHAPE" number 9134
        if (count of senders) is not rowCount or (count of sizes) is not rowCount then error "STYLE_PAGE_SHAPE" number 9134
        repeat with rowIndex from 1 to rowCount
            set my readFailureStage to 9193
            set senderValue to my mailText(item rowIndex of senders, false, 9174)
            if (count of senderValue) > 16384 then error "STYLE_PAGE_SHAPE" number 9134
            set sizeValue to item rowIndex of sizes
            if class of sizeValue is not integer or sizeValue < 0 or sizeValue > 2147483647 then error "STYLE_PAGE_SHAPE" number 9134
            set end of rows to {firstIndex + rowIndex - 1, senderValue, sizeValue}
        end repeat
    end if
    return {"HARBOR_STYLE_CANDIDATES_V1", total, rows, my bodyMetricResult("style_candidates", rowCount)}
end styleCandidatePage

on styleContentRange(b, firstIndex, lastIndex)
    set my readFailureStage to 9164
    my bodyMetricGet()
    tell application "Mail" to return get content of (messages firstIndex thru lastIndex of b)
end styleContentRange

on styleContentScalar(b, messagePosition)
    set my readFailureStage to 9164
    my bodyMetricGet()
    tell application "Mail" to return get content of («class mssg» messagePosition of b)
end styleContentScalar

on styleValidateCandidates(candidates)
    if class of candidates is not list then error "STYLE_INPUT_SHAPE" number 9133
    set rowCount to count of candidates
    if rowCount < 1 or rowCount > 4 then error "STYLE_INPUT_BOUND" number 9131
    set previousPosition to 0
    set totalSize to 0
    repeat with rowRef in candidates
        set rowValue to contents of rowRef
        if class of rowValue is not list or (count of rowValue) is not 3 then error "STYLE_INPUT_SHAPE" number 9133
        set positionValue to item 1 of rowValue
        set sizeValue to item 3 of rowValue
        if class of positionValue is not integer or positionValue <= previousPosition or positionValue > 2147483647 then error "STYLE_INPUT_SHAPE" number 9133
        if class of sizeValue is not integer or sizeValue < 0 or sizeValue > 2097152 then error "STYLE_INPUT_BOUND" number 9135
        set previousPosition to positionValue
        set totalSize to totalSize + sizeValue
    end repeat
    if totalSize > 2097152 then error "STYLE_INPUT_BOUND" number 9135
end styleValidateCandidates

on styleContentText(rawValue)
    set my readFailureStage to 9164
    if class of rawValue is not text then error "STYLE_CONTENT_SHAPE" number 9164
    set valueText to my mailText(rawValue, false, 9164)
    if (count of valueText) > 250000 then error "STYLE_CONTENT_BOUND" number 9135
    return valueText
end styleContentText

-- Only local list grouping occurs between GETs; no identity/header/attachment
-- request or after-check exists on this style-only path.
on styleContentGroups(b, candidates, reader, scalarMode)
    set rows to {}
    set rowCount to count of candidates
    set rowIndex to 1
    repeat while rowIndex <= rowCount
        set firstRow to item rowIndex of candidates
        set firstIndex to item 1 of firstRow
        if scalarMode then
            try
                set rawBody to reader's styleContentScalar(b, firstIndex)
                set end of rows to {firstIndex, my styleContentText(rawBody), 0}
            on error number errorNumber
                if errorNumber is not -1708 and errorNumber is not -1712 then error "STYLE_CONTENT_READ_FAILED" number errorNumber
                set end of rows to {firstIndex, "", errorNumber}
            end try
            set rowIndex to rowIndex + 1
        else
            set lastRowIndex to rowIndex
            set lastIndex to firstIndex
            repeat while lastRowIndex < rowCount
                set nextPosition to item 1 of item (lastRowIndex + 1) of candidates
                if nextPosition is not lastIndex + 1 then exit repeat
                set lastRowIndex to lastRowIndex + 1
                set lastIndex to nextPosition
            end repeat
            set values to reader's styleContentRange(b, firstIndex, lastIndex)
            set runCount to lastRowIndex - rowIndex + 1
            if class of values is not list then error "STYLE_CONTENT_SHAPE" number 9164
            if (count of values) is not runCount then error "STYLE_CONTENT_SHAPE" number 9164
            repeat with runIndex from 1 to runCount
                set end of rows to {firstIndex + runIndex - 1, my styleContentText(item runIndex of values), 0}
            end repeat
            set rowIndex to lastRowIndex + 1
        end if
    end repeat
    return rows
end styleContentGroups

on styleReadContents(cursorData, candidates, reader, scalarMode)
    my styleValidateCandidates(candidates)
    my bodyMetricBegin()
    my bodyMetricPhase(1)
    set b to reader's styleContentsScope(cursorData)
    my bodyMetricPhase(2)
    set rows to my styleContentGroups(b, candidates, reader, scalarMode)
    set modeValue to "style_contents"
    if scalarMode then set modeValue to "style_contents_fallback"
    return {"HARBOR_STYLE_CONTENTS_V1", rows, my bodyMetricResult(modeValue, count of candidates)}
end styleReadContents

on perform(operationName, payload)
    my bodyMetricPhase(0)
    if operationName is "style_contents" then my bodyMetricBegin()
    set my readFailureStage to 0
    try
    with timeout of 15 seconds
        if operationName starts with "index_" or operationName starts with "style_" then
            if application "Mail" is not running then error "INDEX_MAIL_NOT_RUNNING" number 9136
        end if
        if operationName is "capture" then return my captureSelected()
        if operationName is "snapshot" then return my draftSnapshot()
        if operationName is "history" then return my captureHistory(item 1 of payload, item 2 of payload, item 3 of payload)
        if operationName is "hydrate" then return my hydrateHistory(item 1 of payload, item 2 of payload)
        if operationName is "index_mailboxes" then return my indexDiscover(item 1 of payload, item 2 of payload)
        if operationName is "index_page" then return my indexHeaderPage(item 1 of payload, item 2 of payload)
        if operationName is "index_hydrate" then return my indexHydrate(item 1 of payload)
        if operationName is "index_hydrate_measured" then
            my bodyMetricBegin()
            set rows to my indexHydrate(item 1 of payload)
            return {"HARBOR_MAIL_BODY_V1", rows, {my bodyMetricResult("scalar", count of item 1 of payload)}}
        end if
        if operationName is "index_hydrate_batch" then return my measuredHydrateBatch(item 1 of payload, item 2 of payload, item 3 of payload)
        if operationName is "index_cache_validate" then return my validateCachedRows(item 1 of payload, item 2 of payload)
        if operationName is "style_candidates" then return my styleCandidatePage(item 1 of payload, item 2 of payload, me)
        if operationName is "style_contents" then return my styleReadContents(item 1 of payload, item 2 of payload, me, false)
        if operationName is "style_content_scalar" then return my styleReadContents(item 1 of payload, item 2 of payload, me, true)
        if operationName is "style_accounts" then return my styleAccountIdentities()
        if operationName is "style_mailboxes" then return my styleSentMailboxes(item 1 of payload)
        if operationName is "create" then
            set requestToken to item 1 of payload
            if requestToken is in attemptedRequests then
                if my strictEqual(trackedRequest, requestToken) and trackedDraft is not missing value then return my draftSnapshot()
                error "CREATE_ALREADY_ATTEMPTED" number 9104
            end if
            set expectedTarget to item 2 of payload
            if not my strictEqual(my captureSelected(), expectedTarget) then error "TARGET_CHANGED" number 9105
            set end of attemptedRequests to requestToken
            set trackedRequest to requestToken
            set trackedDraft to missing value
            set my readFailureStage to 9191
            tell application "Mail"
                set trackedMessage to item 1 of selection
                set trackedDraft to reply trackedMessage opening window yes reply to all (item 3 of payload)
            end tell
            return my draftSnapshot()
        end if
        if operationName is "insert" then
            set expectedSnapshot to item 1 of payload
            if not my strictEqual(my draftSnapshot(), expectedSnapshot) then error "DRAFT_CHANGED" number 9106
            if not my strictEqual(my captureSelected(), item 3 of payload) then error "TARGET_CHANGED" number 9105
            set my readFailureStage to 9192
            tell application "Mail"
                -- Range insertion only. Never set the whole content or use the clipboard.
                make new paragraph at beginning of content of trackedDraft with data ((item 2 of payload) & return & return)
            end tell
            return my draftSnapshot()
        end if
        error "UNKNOWN_OPERATION" number 9107
    end timeout
    on error ignoredText number errorNumber
        -- Fixed identifiers/numbers only: never Apple's error text.
        if operationName is "style_contents" then
            set failureValue to my mailFailureEnvelope(errorNumber, my readFailureStage)
            return {"HARBOR_STYLE_CONTENT_FAILURE_V1", failureValue, my bodyMetricResult("style_contents_failure", count of item 2 of payload)}
        end if
        return my mailFailureEnvelope(errorNumber, my readFailureStage)
    end try
end perform
