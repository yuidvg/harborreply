import Foundation

public enum StyleCapturePhase: String, Equatable, Sendable {
    case discovering, collecting, analyzing, completed
}

public enum StyleCaptureActivity: String, Equatable, Sendable {
    case starting, discoveringMailboxes, readingHeaders, readingBodies
    case checkingCache, savingSamples, finishingAcquisition, analyzing, idle
}

public enum StyleCaptureStopReason: String, Equatable, Sendable {
    case sourceExhausted, tokenBudget, sampleLimit, headerLimit, readLimit
}

/// An observation of acknowledged work, never an estimate of overall completion.
/// An in-flight native read cannot honestly be counted as completed until its
/// response and locator identity validate. Retention is separately acknowledged.
/// These counters contain no account, mailbox, message identifier or text.
public struct StyleCaptureProgress: Equatable, Sendable {
    public let phase: StyleCapturePhase
    public let activity: StyleCaptureActivity
    public let startedAt: Date
    public let knownFolderCount: Int?
    public let knownSentMessageCount: Int?
    /// Sender/size rows inspected are bounded separately from the Mail total.
    public let headerTarget: Int?
    public let foldersProcessed: Int
    /// One-based index of the active Sent folder, absent outside acquisition.
    public let activeFolderIndex: Int?
    public let headersChecked: Int
    public let metadataExcluded: Int
    /// Logical collection targets in saved intervals and the current invocation.
    /// Scalar compatibility retries are charged separately by the durable quota;
    /// this is not a count of Apple Events or a lifetime native request total.
    public let bodyAttempts: Int
    /// Validated results returned by Mail, including unavailable body results.
    public let bodyReadsCompleted: Int
    /// Results with an actual body, before authored-text/dedup/budget filtering.
    public let bodyCaptured: Int
    public let cachedBodies: Int
    /// Samples acknowledged as retained by the local worker.
    public let adoptedSamples: Int
    /// Body results rejected by the worker; excludes metadata-only filtering.
    public let skippedSamples: Int
    /// Conservative UTF-8 bytes plus framing units, not a tokenizer result.
    public let tokenUnits: Int
    public let tokenBudget: Int
    /// Current small material batch, including validated cached snapshots.
    public let batchRequested: Int
    public let batchCompleted: Int
    public let stopReason: StyleCaptureStopReason?

    public init(phase: StyleCapturePhase, activity: StyleCaptureActivity, startedAt: Date,
                knownFolderCount: Int? = nil, knownSentMessageCount: Int? = nil, headerTarget: Int? = nil,
                foldersProcessed: Int = 0, activeFolderIndex: Int? = nil, headersChecked: Int = 0,
                metadataExcluded: Int = 0, bodyAttempts: Int = 0, bodyReadsCompleted: Int = 0,
                bodyCaptured: Int = 0, cachedBodies: Int = 0, adoptedSamples: Int = 0, skippedSamples: Int = 0,
                tokenUnits: Int = 0, tokenBudget: Int, batchRequested: Int = 0, batchCompleted: Int = 0,
                stopReason: StyleCaptureStopReason? = nil) {
        self.phase = phase; self.activity = activity; self.startedAt = startedAt
        self.knownFolderCount = knownFolderCount; self.knownSentMessageCount = knownSentMessageCount
        self.headerTarget = headerTarget; self.foldersProcessed = foldersProcessed; self.activeFolderIndex = activeFolderIndex
        self.headersChecked = headersChecked; self.metadataExcluded = metadataExcluded
        self.bodyAttempts = bodyAttempts; self.bodyReadsCompleted = bodyReadsCompleted; self.bodyCaptured = bodyCaptured
        self.cachedBodies = cachedBodies
        self.adoptedSamples = adoptedSamples; self.skippedSamples = skippedSamples
        self.tokenUnits = tokenUnits; self.tokenBudget = tokenBudget
        self.batchRequested = batchRequested; self.batchCompleted = batchCompleted; self.stopReason = stopReason
    }
}
