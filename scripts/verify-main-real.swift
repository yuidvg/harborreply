import AppKit
import AVFoundation
import Darwin
import Foundation
import HarborCore
import Speech
import SwiftUI

// Opt-in external verification, excluded from the product. Private values stay
// in memory / a 0700 temporary DB. Only the following typed aggregates leave it.
private enum Check: String, Codable {
    case preflight, selection, coordinatorCapture, archivePause, archiveResume
    case styleSmallBudget, styleDefaultBudget, relatedPrepare, coordinatorPrefetch
    case nativeLayout, generation, copy, placement, cancellation, speechCapability
    case directBenchmark
}
private enum Outcome: String, Codable { case passed, failed, blocked, partial }
private struct Failure: Codable {
    let category: DiagnosticFailureCode
    let operation: MailEventOperation?
    let stage: MailEventStage?
    let nativeCode: Int?
    init(_ error: Error) {
        let value = error as? AppFailure
        category = value?.diagnosticFailure ?? .unknown
        operation = value?.mailContext?.operation
        stage = value?.mailContext?.stage
        nativeCode = value?.mailContext?.nativeCode
    }
}
private struct Measurement: Codable {
    let check: Check
    let outcome: Outcome
    let milliseconds: Double
    let counts: [String: Int]
    let flags: [String: Bool]
    let failure: Failure?
}
private struct Distribution: Codable {
    let samples: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    init(_ values: [Double]) {
        let sorted = values.sorted()
        samples = sorted.count
        p50Milliseconds = sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * 0.5)) - 1)]
        p95Milliseconds = sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        maximumMilliseconds = sorted.last ?? 0
    }
}
private struct Span: Codable {
    let stage: DiagnosticTimingStage
    let samples: Int
    let totalMilliseconds: Int
    let maximumMilliseconds: Int
}
private struct Report: Codable {
    let version = 1
    let realMailConsent: Bool
    let cloudConsent: Bool
    var privateStateRemoved = false
    let mailWritesExecuted = false
    let fullArchiveTested = false
    let microphoneRecorded = false
    let interactiveGUIAccepted = false
    let personalAuthorshipVerified = false
    var modelCalled = false
    var processPeakRSSBytes = 0
    var measurements: [Measurement] = []
    var repeated: [String: Distribution] = [:]
    var spans: [Span] = []
    var directBenchmark: PrivateBenchmark?
}
// The Python helper's schema is decoded below; arbitrary stdout is never emitted.
private struct PrivateBenchmark: Codable {
    let succeeded: Bool
    let operations: [BenchmarkMetric]
    let index_counts: [String: Int]?
    let database_bytes: Int?
    let database_open_milliseconds: Double?
    let process_peak_rss_bytes_before: Int?
    let process_peak_rss_bytes_after: Int?
    let query_plans: [String: Bool]?
    let fts_internal_work_in_vm_steps: Bool?
}
private struct BenchmarkMetric: Codable {
    enum Operation: String, Codable { case related, prepare, overview, search_ids }
    let operation: Operation
    let samples: Int
    let succeeded: Bool
    let first_milliseconds: Double?
    let p50_milliseconds: Double?
    let p95_milliseconds: Double?
    let maximum_milliseconds: Double?
    let sqlite_vm_steps: Int?
    let sqlite_vm_granularity: Int?
    let sql_statement_count: Int?
    let metadata_point_lookups: Int?
    let result_count: Int?
    let candidate_count: Int?
    let evidence_count: Int?
    let style_example_count: Int?
    let unresolved_count: Int?
}
private struct Clock {
    let start = DispatchTime.now().uptimeNanoseconds
    var milliseconds: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
}

/// Measures actual shipping reads without altering their values. Write methods
/// fail closed even if a future coordinator change accidentally calls them.
@MainActor private final class ReadOnlyMeasuredMail: MailSelectionBridge {
    let live = AppleMailBridge()
    var metadataReads = 0
    var bodyAttempts = 0
    var bodySuccesses = 0
    var bodyBytes = 0
    var writesAttempted = 0
    var targets: [MailTarget] = []
    func clearTracking() { live.clearTracking() }
    func canCaptureWithoutPrompt() async -> Bool { await live.canCaptureWithoutPrompt() }
    func capture() async throws -> MailTarget { try await live.capture() }
    func createReply(to: MailTarget, replyAll: Bool, requestID: UUID) async throws -> DraftSnapshot { writesAttempted += 1; throw AppFailure("LIVE_MAIL_WRITES_FORBIDDEN") }
    func snapshot() async throws -> DraftSnapshot { throw AppFailure("LIVE_MAIL_WRITES_FORBIDDEN") }
    func insert(_ text: String, expected: DraftSnapshot) async throws { writesAttempted += 1; throw AppFailure("LIVE_MAIL_WRITES_FORBIDDEN") }
    func history(for target: MailTarget?, limit: Int) async throws -> MailHistoryWindow { try await live.history(for: target, limit: limit) }
    func hydrate(records: [MailHistoryItem]) async throws -> [MailHistoryMessage] { try await live.hydrate(records: records) }
    func indexMailboxes(after cursor: MailMailboxCursor?, limit: Int) async throws -> MailMailboxPage { try await live.indexMailboxes(after: cursor, limit: limit) }
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage {
        let page = try await live.indexPage(cursor: cursor, limit: limit)
        metadataReads += page.records.count
        return page
    }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] {
        bodyAttempts += locators.count
        let results = try await live.hydrateIndexed(locators: locators)
        for result in results {
            if let target = result.message?.target {
                bodySuccesses += 1; bodyBytes += target.body.utf8.count + target.headers.utf8.count
                if targets.count < 8, target.body.count <= 12_000 { targets.append(target) }
            }
        }
        return results
    }
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult] {
        bodyAttempts += batch.locators.count
        let results = try await live.hydrateIndexedBatch(batch)
        for result in results {
            if let target = result.message?.target {
                bodySuccesses += 1; bodyBytes += target.body.utf8.count + target.headers.utf8.count
                if targets.count < 8, target.body.count <= 12_000 { targets.append(target) }
            }
        }
        return results
    }
    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int]) async throws -> [Bool] {
        try await live.validateCachedIndexed(locators: locators, attachmentCounts: attachmentCounts)
    }
    func styleCandidates(cursor: MailIndexCursor, limit: Int) async throws -> StyleCandidatePage {
        let result = try await live.styleCandidates(cursor: cursor, limit: limit)
        metadataReads += result.records.count
        return result
    }
    func styleContents(batch: StyleContentBatch) async throws -> [StyleContentRead] {
        bodyAttempts += batch.candidates.count
        return try await live.styleContents(batch: batch)
    }
    func styleAccounts() async throws -> [MailAccountIdentity] { try await live.styleAccounts() }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] { try await live.styleMailboxes(accountID: accountID) }
}

@MainActor private final class MainVerification {
    let mail = ReadOnlyMeasuredMail()
    let directory: URL
    let database: URL
    let worker: LocalWorker
    let ownerSettings: Settings
    var report: Report
    var selected: MailTarget?
    var coordinator: ReplyCoordinator?
    private var capturedSpans: [DiagnosticRecord] = []

    init(directory: URL, allowCloud: Bool) {
        self.directory = directory; database = directory.appendingPathComponent("isolated.sqlite")
        worker = LocalWorker(database: database); ownerSettings = Settings.load()
        report = Report(realMailConsent: true, cloudConsent: allowCloud)
    }
    func append(_ check: Check, _ outcome: Outcome, _ clock: Clock,
                counts: [String: Int] = [:], flags: [String: Bool] = [:], error: Error? = nil) {
        report.measurements.append(.init(check: check, outcome: outcome, milliseconds: clock.milliseconds,
                                        counts: counts, flags: flags, failure: error.map(Failure.init)))
    }
    private func object(_ command: String, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        guard let result = try await worker.call(command, values) as? [String: Any] else { throw AppFailure("LIVE_RESPONSE_INVALID") }
        return result
    }
    private func input(_ target: MailTarget) throws -> [String: Any] {
        let value = ReplyInput(target: target, internalMail: false, caseID: "", userIntent: "内容を受領したことだけを簡潔に伝える。新しい事実・数値・承認・期限は追加しない。",
                               language: "日本語", tone: "丁寧・明確", styleProfile: ownerSettings.style,
                               requestID: UUID(), revision: 0)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }
    private func wait(_ predicate: () -> Bool, milliseconds: Int = 30_000) async throws {
        let timer = Clock()
        while !predicate() {
            guard timer.milliseconds < Double(milliseconds) else { throw AppFailure("LIVE_WAIT_TIMEOUT") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func preflight() async {
        let timer = Clock()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
        append(.speechCapability, .partial, timer, flags: [
            "microphoneAuthorized": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "speechAuthorized": SFSpeechRecognizer.authorizationStatus() == .authorized,
            "japaneseRecognizerAvailable": recognizer?.isAvailable == true,
            "onDeviceSupported": recognizer?.supportsOnDeviceRecognition == true,
            "recordingStarted": false
        ])
        append(.preflight, .passed, timer, counts: ["styleTokenBudget": ownerSettings.effectiveStyleTokenBudget],
               flags: ["savedCloudEnabled": ownerSettings.cloudEnabled,
                       "savedModelConfigured": !(ownerSettings.chatgptModel ?? "").isEmpty,
                       "savedStyleSenderConfigured": ownerSettings.styleSenderAddress != nil,
                       "productionPlacementEnabled": false])
        let capture = Clock()
        do { selected = try await mail.capture(); append(.selection, .passed, capture, counts: ["bodyBytes": selected?.body.utf8.count ?? 0]) }
        catch { append(.selection, .blocked, capture, error: error) }
    }
    func captureCoordinator() async {
        let model = ReplyCoordinator(mail: mail, database: database, settings: Settings(), diagnosticsEnabled: false,
                                     chatGPT: ChatGPTConnection(activeID: ""))
        coordinator = model
        let timer = Clock()
        model.captureMail()
        do {
            try await wait { !model.busy }
            if let target = model.session.target {
                let matchesDirect = selected == target
                selected = target
                try await wait { !model.relatedLoading }
                append(.coordinatorCapture, .passed, timer, counts: ["candidates": model.candidates.count, "evidence": model.evidence.count],
                       flags: ["captureMatchesDirect": matchesDirect, "noMailWrites": mail.writesAttempted == 0])
            } else { append(.coordinatorCapture, .blocked, timer, flags: ["actionableSelectionGuidance": !model.captureErrorCode.isEmpty]) }
        } catch { append(.coordinatorCapture, .failed, timer, error: error) }
    }
    func index(to count: Int, restart: Bool, check: Check) async {
        let timer = Clock(); let initialReads = mail.metadataReads; let initialBodies = mail.bodyAttempts
        var current: MailArchiveStatus?
        var task: Task<Void, Error>?
        let initialState = try? await object("index_status")
        let initialID = initialState?["scan_id"] as? String
        let initialEpoch = initialState?["epoch"] as? Int
        let indexer = MailArchiveIndexer(mail: mail, worker: worker, requestID: UUID())
        task = Task {
            try await indexer.run(restart: restart) { state in
                current = state
                capturedSpans += Diagnostics.log.recentTimings()
                if state.counts.metadata >= count { task?.cancel() }
            }
        }
        let deadline = Task { try? await Task.sleep(for: .seconds(180)); guard !Task.isCancelled else { return }; task?.cancel() }
        var failure: Error?
        do { try await task?.value }
        catch { if !(error is CancellationError) && (error as? AppFailure)?.baseCode != "OPERATION_CANCELLED" { failure = error } }
        deadline.cancel()
        let state = (try? await worker.call("index_status")).flatMap { try? MailArchiveStatus.decode($0) } ?? current
        let numeric: [String: Int] = ["metadataReads": mail.metadataReads - initialReads, "bodyAttempts": mail.bodyAttempts - initialBodies,
            "indexed": state?.counts.metadata ?? 0, "captured": state?.counts.captured ?? 0,
            "unreadable": state?.counts.unreadable ?? 0, "tooLarge": state?.counts.tooLarge ?? 0,
            "bodyBytes": state?.counts.bodyBytes ?? 0, "folders": state?.counts.mailboxes ?? 0, "pages": state?.counts.pages ?? 0]
        append(check, failure == nil && (state?.counts.metadata ?? 0) >= count ? .passed : .partial, timer, counts: numeric,
               flags: ["paused": state?.status == "paused", "sameScanOnResume": restart || state?.scanID == initialID,
                       "sameEpochOnResume": restart || state?.epoch == initialEpoch, "noMailWrites": mail.writesAttempted == 0], error: failure)
        // Gather at each major phase; the shipping RAM ring is bounded to128.
        capturedSpans += Diagnostics.log.recentTimings()
    }
    func style(budget: Int, check: Check) async {
        let timer = Clock(); let initialReads = mail.metadataReads; let initialBodies = mail.bodyAttempts
        do {
            let accounts = try await mail.styleAccounts()
            guard let account = accounts.first(where: { $0.id == ownerSettings.styleAccountID }) ?? accounts.first,
                  let address = account.addresses.first(where: { SentStyleSelection.address($0) == SentStyleSelection.address(ownerSettings.styleSenderAddress ?? "") }) ?? account.addresses.first else {
                throw AppFailure("LIVE_STYLE_SENDER_UNAVAILABLE")
            }
            let run = Task {
                try await MailStyleCapture(mail: mail).collect(account: account, address: address,
                    shared: ownerSettings.sharedAddresses.components(separatedBy: ","), characterLimit: budget,
                    progress: { _ in capturedSpans += Diagnostics.log.recentTimings() })
            }
            let deadline = Task { try? await Task.sleep(for: .seconds(180)); guard !Task.isCancelled else { return }; run.cancel() }
            defer { deadline.cancel() }
            let text = try await run.value
            append(check, .partial, timer,
                counts: ["messages": text.messages, "characters": text.characters, "characterLimit": text.limit],
                flags: ["collectionPassed": true, "modelExtractionTested": false])

        } catch {
            let state = try? await object("style_capture_status")
            let counts = state?["counts"] as? [String: Any] ?? [:]
            append(check, error is CancellationError ? .partial : .failed, timer,
                   counts: ["metadataReads": mail.metadataReads - initialReads, "bodyAttempts": mail.bodyAttempts - initialBodies,
                            "samples": counts["captured"] as? Int ?? 0, "tokenEstimate": counts["token_estimate"] as? Int ?? 0,
                            "tokenBudget": budget], flags: ["deadlineReached": error is CancellationError], error: error)
        }
        capturedSpans += Diagnostics.log.recentTimings()
    }
    func related() async {
        let timer = Clock()
        guard let target = selected ?? mail.targets.first else { append(.relatedPrepare, .blocked, timer); return }
        do {
            let payload = try input(target)
            var durations: [Double] = []; var candidateCount = 0; var evidenceCount = 0; var unresolved = 0
            for _ in 0..<9 {
                let sample = Clock(); let result = try await object("prepare", ["input": payload]); durations.append(sample.milliseconds)
                let context = result["context"] as? [String: Any] ?? [:]
                candidateCount = (result["candidate_messages"] as? [Any])?.count ?? 0
                evidenceCount = (context["thread_evidence"] as? [Any])?.count ?? 0
                unresolved = (context["unresolved_items"] as? [Any])?.count ?? 0
            }
            report.repeated["workerPrepare"] = .init(durations)
            append(.relatedPrepare, .passed, timer, counts: ["repetitions": 9, "candidatePreviews": candidateCount, "evidence": evidenceCount, "unresolvedItems": unresolved],
                   flags: ["selectedTargetUsed": selected != nil, "sampledTargetFallback": selected == nil, "previewCapRespected": candidateCount <= 20])
            if let model = coordinator, model.session.target != nil {
                let prefetch = Clock(); model.prefetch(); try await wait { !model.relatedLoading }
                append(.coordinatorPrefetch, model.relatedErrorCode.isEmpty ? .passed : .failed, prefetch,
                       counts: ["candidatePreviews": model.candidates.count, "evidence": model.evidence.count])
            } else { append(.coordinatorPrefetch, .blocked, Clock(), flags: ["selectedMailRequired": true]) }
            try await directBenchmark(target: payload["current"] as? [String: Any] ?? [:])
        } catch { append(.relatedPrepare, .failed, timer, error: error) }
    }
    private func directBenchmark(target: [String: Any]) async throws {
        let timer = Clock()
        let data = try JSONSerialization.data(withJSONObject: ["db": database.path, "current": target, "samples": 9])
        let python = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/python-arm64/bin/python3")
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/benchmark-private-mail.py")
        // Match the private path validator to this harness's actual macOS temp
        // root; a sanitized environment otherwise makes Python fall back to /tmp.
        let temporaryRoot = directory.deletingLastPathComponent().path
        let output: Data = try await Task.detached {
            let process = Process(); process.executableURL = python; process.arguments = ["-s", "-B", helper.path, "--allow-real-mail"]
            process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": temporaryRoot, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"]
            let input = Pipe(); let output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); DispatchQueue.global().async { try? input.fileHandleForWriting.write(contentsOf: data); try? input.fileHandleForWriting.close() }
            let response = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0, response.count < 64_000 else { throw AppFailure("LIVE_BENCHMARK_FAILED") }
            return response
        }.value
        report.directBenchmark = try JSONDecoder().decode(PrivateBenchmark.self, from: output)
        append(.directBenchmark, report.directBenchmark?.succeeded == true ? .passed : .failed, timer)
    }
    func layout() async {
        let timer = Clock(); guard let model = coordinator else { append(.nativeLayout, .blocked, timer); return }
        await model.loadReplyOverview()
        let view = NSHostingView(rootView: ReplyView(model: model)); view.frame = NSRect(x: 0, y: 0, width: 900, height: 1100)
        var durations: [Double] = []
        for _ in 0..<9 {
            let sample = Clock(); view.needsLayout = true; view.layoutSubtreeIfNeeded(); durations.append(sample.milliseconds)
            await Task.yield()
        }
        report.repeated["nativeLayout"] = .init(durations)
        append(.nativeLayout, .partial, timer, flags: ["shippingReplyViewUsed": true, "screenshotsTaken": false, "interactiveWindowTested": false,
               "actualTargetDisplayed": model.session.target != nil, "actualStyleLoaded": model.styleSummary?.isExtracted == true])
    }
    func generationAndActions() async {
        let timer = Clock()
        guard let model = coordinator, model.session.target != nil else {
            append(.generation, .blocked, timer, flags: ["selectedMailRequired": true])
            append(.copy, .blocked, Clock(), flags: ["validatedReplyRequired": true, "generalClipboardUnchanged": true])
            append(.placement, .blocked, Clock(), flags: ["productionPlacementDisabled": true, "noMailWrites": mail.writesAttempted == 0])
            return
        }
        model.intent = "内容を受領したことだけを簡潔に伝える。新しい事実・数値・承認・期限は追加しない。"
        // Without separate cloud permission, exercise the real closed route.
        guard report.cloudConsent, ownerSettings.cloudEnabled, !(ownerSettings.chatgptModel ?? "").isEmpty else {
            model.generate(); append(.generation, .blocked, timer, flags: ["cloudRouteClosed": !model.busy && model.replyBody.isEmpty, "savedCloudEnabled": ownerSettings.cloudEnabled,
                "savedModelConfigured": !(ownerSettings.chatgptModel ?? "").isEmpty])
            let copy = Clock(); model.copyReply(); append(.copy, .blocked, copy, flags: ["invalidReplyRefused": !model.replyCopied])
            let placement = Clock(); model.placeReply(); append(.placement, .blocked, placement, flags: ["productionPlacementDisabled": !model.productionMailInsertionVerified, "noMailWrites": mail.writesAttempted == 0])
            return
        }
        model.settings = ownerSettings
        await model.chatGPT.restore()
        model.generate()
        do {
            try await wait({ !model.busy }, milliseconds: 180_000)
            report.modelCalled = Diagnostics.log.recentTimings().contains { $0.timingStage == .replyProvider }
            append(.generation, model.canUseReply ? .passed : .blocked, timer,
                   counts: ["replyBytes": model.replyBody.utf8.count, "validationErrors": model.errors.count, "warnings": model.warnings.count],
                   flags: ["modelCalled": report.modelCalled, "validatedReady": model.canUseReply, "semanticQualityReviewed": false])
        } catch { model.cancel(); append(.generation, .failed, timer, error: error) }
        let placement = Clock(); model.placeReply(); append(.placement, .blocked, placement, flags: ["productionPlacementDisabled": !model.productionMailInsertionVerified, "noMailWrites": mail.writesAttempted == 0])
        // Never replace the user's general clipboard in a read-only verification.
        append(.copy, .blocked, Clock(), flags: ["readyToCopy": model.canUseReply, "generalClipboardUnchanged": true])
    }
    func cancellation() async {
        let timer = Clock(); guard let model = coordinator else { append(.cancellation, .blocked, timer); return }
        let realRetrievalStarted = model.session.target != nil
        model.prefetch(); let old = model.session.revision; model.cancel()
        try? await Task.sleep(for: .milliseconds(500))
        let correct = model.session.revision > old && model.session.phase == .cancelled && !model.busy && !model.relatedLoading && mail.writesAttempted == 0
        append(.cancellation, correct ? (realRetrievalStarted ? .passed : .partial) : .failed, timer, flags: ["revisionChanged": model.session.revision > old,
            "cancelledPhasePreserved": model.session.phase == .cancelled, "notBusy": !model.busy && !model.relatedLoading, "noMailWrites": mail.writesAttempted == 0])
        model.clearSession()
    }
    func run(preflightOnly: Bool) async {
        await preflight(); if preflightOnly { return }
        await captureCoordinator()
        await index(to: 20, restart: true, check: .archivePause)
        await index(to: 128, restart: false, check: .archiveResume)
        await style(budget: 4_096, check: .styleSmallBudget)
        await style(budget: ownerSettings.effectiveStyleTokenBudget, check: .styleDefaultBudget)
        await related(); await layout(); await generationAndActions(); await cancellation()
        capturedSpans += Diagnostics.log.recentTimings()
        let unique = Dictionary(grouping: capturedSpans, by: { $0.timestamp }).compactMap { $0.value.first }
        report.spans = DiagnosticTimingStage.allCases.compactMap { stage in
            let values = unique.filter { $0.timingStage == stage }.map { $0.elapsedMilliseconds ?? 0 }
            return values.isEmpty ? nil : .init(stage: stage, samples: values.count, totalMilliseconds: values.reduce(0, +), maximumMilliseconds: values.max() ?? 0)
        }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { report.processPeakRSSBytes = Int(usage.ru_maxrss) }
    }
}

@main private struct MainReal {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--allow-real-mail", Set(args).count == args.count,
              args.allSatisfy({ ["--allow-real-mail", "--allow-cloud-generation", "--preflight"].contains($0) }) else { exit(64) }
        _ = NSApplication.shared
        Diagnostics.configure(enabled: false, persist: false)
        let parent = ProcessInfo.processInfo.environment["HARBOR_MAIN_VERIFY_STATE_PARENT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = parent.appendingPathComponent("harborreply-live-state-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { exit(1) }
        let verification = MainVerification(directory: directory, allowCloud: args.contains("--allow-cloud-generation"))
        await verification.run(preflightOnly: args.contains("--preflight"))
        try? FileManager.default.removeItem(at: directory)
        verification.report.privateStateRemoved = !FileManager.default.fileExists(atPath: directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if var result = try? encoder.encode(verification.report) { result.append(10); FileHandle.standardOutput.write(result) }
        exit(verification.report.privateStateRemoved ? 0 : 1)
    }
}
