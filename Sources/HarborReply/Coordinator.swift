import AppKit
import Combine
import HarborCore

@MainActor final class ReplyCoordinator: ObservableObject {
    @Published var session = ReplySession() { didSet {
        if session.phase != oldValue.phase { Diagnostics.record(.phaseChanged, request: session.requestID, phase: session.phase) }
    } }
    @Published var updateRestriction: String?
    @Published var diagnosticsEnabled: Bool
    @Published var settings: Settings
    @Published var intent = "" { didSet { if intent != oldValue && !populatingCapture {
        if session.phase == .listening { generation?.cancel(); session.invalidate(.listening); lastOutput = nil; readyRevision = nil }
        else { invalidate() }
    } } }
    @Published var language = "English" { didSet { if language != oldValue && !populatingCapture { invalidate() } } }
    @Published var tone = "丁寧・明確" { didSet { if tone != oldValue { invalidate() } } }
    @Published var replyAll = false { didSet { if replyAll != oldValue { invalidate() } } }
    @Published var caseID = "" { didSet { if caseID != oldValue && !populatingCapture { invalidate(); prefetch() } } }
    @Published var replyBody = ""
    @Published var message = "Apple Mailで対象メールを選択してください。"
    @Published var captureErrorCode = ""
    @Published var warnings: [String] = []
    @Published var errors: [String] = []
    @Published var evidence: [[String: Any]] = []
    @Published private(set) var excludedRelatedIDs: Set<String> = []
    func relatedIsSelected(_ id: String) -> Bool { !excludedRelatedIDs.contains(id) }
    func setRelatedSelected(_ id: String, _ selected: Bool) {
        guard !id.isEmpty else { return }
        if selected { excludedRelatedIDs.remove(id) } else { excludedRelatedIDs.insert(id) }
        invalidate(); prefetch()
    }
    @Published var candidates: [[String: Any]] = []
    @Published var cases: [[String: Any]] = []
    @Published var caseMessages: [[String: Any]] = []
    @Published var events: [[String: Any]] = []
    @Published var sources: [[String: Any]] = []
    @Published var searchResults: [[String: Any]] = []
    @Published var selectedMessage: [String: Any]?
    @Published var profiles: [String: Any] = [:]
    @Published var styleSummary: StyleSummary?
    @Published var styleExtracting = false
    @Published var styleProgress: StyleTextProgress?
    @Published var styleMessage = ""
    @Published var styleCanResume = false
    @Published var styleNeedsRestart = false
    @Published var relatedLoading = false
    @Published var relatedNotice = ""
    @Published var relatedErrorCode = ""
    @Published var mailIndexStatus: MailArchiveStatus?
    @Published var mailIndexRunning = false
    @Published var mailIndexNotice = ""
    @Published var styleAccounts: [MailAccountIdentity] = []
    @Published var choosingStyleAddress = false
    @Published var replyCopied = false
    @Published var actionNotice = ""
    @Published var settingsNotice = ""
    @Published var mailWriteNotice = ""
    @Published var coverage = "履歴は未取り込みです。ライブ同期ではありません。"
    @Published var busy = false
    @Published var importing = false
    @Published var metrics = "未計測"
    @Published var panelMilliseconds: Double = 0
    @Published var recipientsConfirmed = false
    @Published var currentInternal = false { didSet { if currentInternal != oldValue && !populatingCapture { invalidate() } } }
    @Published var tab = 0
    @Published var voiceNote = ""
    let voice = LocalVoice()
    let chatGPT: ChatGPTConnection
    let mail: any MailSelectionBridge
    // Production insertion stays closed until the acceptance matrix is verified on the actual app.
    let productionMailInsertionVerified = false
    private let styleProvider: (any LLMProvider)?
    let worker: LocalWorker
    private let persistStyleSelection: (Settings) throws -> Void
    private var generation: Task<Void, Never>?
    private var generationStartTask: Task<Void, Never>?
    private var indexPausingForReply = false
    private var prefetchTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var importOperationID = UUID()
    private var mailTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var indexOperationID = UUID()
    private var indexRefreshAt = Date.distantPast
    private var styleTask: Task<Void, Never>?
    private var styleCleanupTask: Task<Void, Never>?
    private var scopedStyleCaptureActive = false
    private var styleOperationID = UUID()
    private var archiveEpoch = 0
    private var copyTask: Task<Void, Never>?
    private var automaticCaptureTask: Task<Void, Never>?
    private var populatingCapture = false
    private var inspectionID = UUID()
    private var searchID = UUID()
    private var lastContext: [String: Any]?
    private var lastOutput: [String: Any]?
    private var readyRevision: Int?
    private var expiry: Task<Void, Never>?
    var replyNeedsRegeneration: Bool { !replyBody.isEmpty && readyRevision != session.revision }
    var canUseReply: Bool {
        !replyBody.isEmpty && readyRevision == session.revision && errors.isEmpty && !busy &&
        (session.phase == .ready || session.phase == .inserted)
    }
    init(mail: (any MailSelectionBridge)? = nil, database: URL? = nil,
         settings: Settings? = nil, diagnosticsEnabled: Bool? = nil, chatGPT: ChatGPTConnection? = nil,
         styleProvider: (any LLMProvider)? = nil,
         persistStyleSelection: @escaping (Settings) throws -> Void = { try $0.save() }) {
        self.styleProvider = styleProvider
        self.settings = settings ?? Settings.load()
        self.diagnosticsEnabled = diagnosticsEnabled ?? UserDefaults.standard.bool(forKey: Diagnostics.preferenceKey)
        self.chatGPT = chatGPT ?? ChatGPTConnection()
        self.mail = mail ?? AppleMailBridge()
        self.worker = LocalWorker(database: database ?? Settings.directory.appendingPathComponent("archive.sqlite"))
        self.persistStyleSelection = persistStyleSelection
    }

    func invalidate() {
        generationStartTask?.cancel(); generationStartTask = nil; indexPausingForReply = false
        generation?.cancel(); prefetchTask?.cancel(); mailTask?.cancel(); automaticCaptureTask?.cancel(); session.invalidate(); busy = false; relatedLoading = false
        lastOutput = nil; lastContext = nil; readyRevision = nil
        copyTask?.cancel(); replyCopied = false
        actionNotice = ""; captureErrorCode = ""
        errors = []; warnings = []; recipientsConfirmed = false
    }
    func cancel() {
        generationStartTask?.cancel(); generationStartTask = nil; indexPausingForReply = false
        cancelStyleExtraction()
        generation?.cancel(); prefetchTask?.cancel(); mailTask?.cancel(); automaticCaptureTask?.cancel(); voice.cancel(); session.cancel(); busy = false; relatedLoading = false
        message = "取り消しました。遅れて届く結果は適用しません。作成済みのMail下書きは削除しません。"
        actionNotice = ""; captureErrorCode = ""
    }
    func expireLater() {
        expiry?.cancel()
        expiry = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(1, min(settings.sessionMinutes, 120))) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            self.clearSession()
        }
    }
    func clearSession() {
        cancel(); session = ReplySession(); intent = ""; replyBody = ""; evidence = []; candidates = []; excludedRelatedIDs = []
        selectedMessage = nil; lastContext = nil; lastOutput = nil; mail.clearTracking(); message = "生成セッションを消去しました。"
        relatedNotice = ""; relatedErrorCode = ""
    }
    func captureMail() {
        cancel(); populatingCapture = true
        caseID = ""; replyBody = ""; evidence = []; candidates = []; excludedRelatedIDs = []
        errors = []; warnings = []; currentInternal = false; voiceNote = ""; relatedNotice = ""; relatedErrorCode = ""
        session = ReplySession(); session.transition(.retrieving); busy = true; message = "Mailの選択メールを取得中"
        populatingCapture = false
        let id = session.requestID; let rev = session.revision
        mailTask = Task {
            do {
                let target = try await mail.capture()
                guard !Task.isCancelled, session.isCurrent(id, rev) else { return }
                populatingCapture = true; session.capture(target); busy = false
                language = target.body.range(of: "[\\p{Hiragana}\\p{Katakana}\\p{Han}]", options: .regularExpression) == nil ? "English" : "日本語"
                intent = ""; populatingCapture = false
                session.transition(.editing); message = "選択メールを取得しました。関連メールを検索します。"
                expireLater(); await loadMailIndexStatus(); prefetch(); await loadReplyOverview()
            } catch { if !recordUncertainMailWrite(error), !Task.isCancelled, session.isCurrent(id, rev) { busy = false; fail(AppFailure.located(error, at: .mailCapture)) } }
        }
    }
    /// User opt-in and opening the panel are both required. Never polls Mail in the background.
    func captureMailIfEnabled() {
        guard automaticCaptureAllowed else { return }
        automaticCaptureTask?.cancel()
        let id = session.requestID; let rev = session.revision
        automaticCaptureTask = Task {
            guard await mail.canCaptureWithoutPrompt(), !Task.isCancelled,
                  session.requestID == id, session.revision == rev, automaticCaptureAllowed else { return }
            captureMail()
        }
    }
    private var automaticCaptureAllowed: Bool {
        settings.capturesMailAutomatically && !busy && !importing &&
        session.draft == nil && session.phase != .listening && intent.isEmpty && replyBody.isEmpty
    }
    func setAutoCaptureMail(_ enabled: Bool) {
        settings.autoCaptureMail = enabled
        do { try settings.save(); settingsNotice = ""; if enabled, !busy, intent.isEmpty, replyBody.isEmpty, session.draft == nil { captureMail() } }
        catch { fail(error); settingsNotice = "設定を保存できませんでした（\(message)）。" }
    }
    /// The extraction action reads Mail's Sent scope, not user-exported files.
    /// Ordinary reply preparation never starts style learning or infers authorship.
    func beginStyleExtraction() {
        guard !busy else { styleMessage = "処理が終わってから文体を抽出してください。"; return }
        beginMailStyleExtraction()
    }
    private func beginMailStyleExtraction() {
        guard !styleExtracting, !importing else { return }
        styleCanResume = false
        styleTask?.cancel(); styleOperationID = UUID()
        let operation = styleOperationID; let epoch = archiveEpoch
        styleExtracting = true; styleMessage = "Mailの差出人を確認しています…"
        styleProgress = nil
        styleTask = Task {
            do {
                let accounts = try await Diagnostics.measure(.styleAccounts, request: operation) { try await mail.styleAccounts() }
                try checkStyleOperation(operation, epoch: epoch)
                guard accounts.count <= MailIndexLimits.folders else { throw AppFailure("STYLE_ACCOUNTS_LIMIT") }
                let excluded = Set(sharedStyleAddresses.compactMap(SentStyleSelection.address))
                styleAccounts = accounts.map { account in
                    MailAccountIdentity(id: account.id, name: account.name,
                        addresses: Array(Set(account.addresses.compactMap(SentStyleSelection.address)).subtracting(excluded)).sorted())
                }.filter { !$0.addresses.isEmpty }
                guard !styleAccounts.isEmpty else { throw AppFailure("STYLE_PERSONAL_ADDRESS_REQUIRED") }
                styleExtracting = false; styleMessage = ""; choosingStyleAddress = true
            } catch { showStyleFailure(AppFailure.located(error, at: .styleAccounts), operation: operation, epoch: epoch) }
        }
    }
    private var sharedStyleAddresses: [String] {
        settings.sharedAddresses.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)
    }
    /// Choosing a sender is the owner's explicit designation of their own writing.
    func selectStyleAddress(accountID: String, address: String, restart: Bool = false) {
        guard !busy, !importing, !styleExtracting,
              let account = styleAccounts.first(where: { $0.id == accountID }),
              account.addresses.contains(address) else { return }
        do {
            var updated = settings
            updated.styleAccountID = accountID; updated.styleSenderAddress = address
            try persistStyleSelection(updated); settings = updated
        } catch { choosingStyleAddress = false; styleMessage = "差出人を保存できませんでした。再度選択してください。"; return }
        choosingStyleAddress = false
        styleCanResume = false
        styleTask?.cancel(); styleOperationID = UUID()
        let operation = styleOperationID; let epoch = archiveEpoch
        styleExtracting = true; styleMessage = "選んだ差出人の送信済みを取得しています…"
        styleProgress = nil
        scopedStyleCaptureActive = true
        styleTask = Task {
            defer { if styleIsCurrent(operation, epoch: epoch) { scopedStyleCaptureActive = false } }
            do { try await extractMailStyle(account: account, address: address, operation: operation, epoch: epoch, restart: restart) }
            catch { showStyleFailure((error as? AppFailure)?.location == nil ? AppFailure.located(error, at: .styleCapture) : error, operation: operation, epoch: epoch) }
        }
    }
    /// Resume the explicitly saved sender. Never infer a replacement identity
    /// from Mail's current selection or open the author chooser after a timeout.
    func resumeStyleExtraction(restart: Bool = false) {
        guard styleCanResume, !busy, !importing, !styleExtracting else { return }
        if let selected = configuredStyleSelection {
            selectStyleAddress(accountID: selected.account.id, address: selected.address, restart: restart)
            return
        }
        guard let accountID = settings.styleAccountID,
              let address = settings.styleSenderAddress.flatMap(SentStyleSelection.address),
              !sharedStyleAddresses.compactMap(SentStyleSelection.address).contains(address) else {
            styleCanResume = false
            styleMessage = Self.styleFailureMessage(for: AppFailure("STYLE_PERSONAL_ADDRESS_REQUIRED"))
            return
        }
        styleTask?.cancel(); styleOperationID = UUID()
        let operation = styleOperationID; let epoch = archiveEpoch
        styleCanResume = false; styleExtracting = true; styleProgress = nil
        styleMessage = "保存した差出人をMailで確認しています…"
        styleTask = Task {
            do {
                let accounts = try await Diagnostics.measure(.styleAccounts, request: operation) { try await mail.styleAccounts() }
                try checkStyleOperation(operation, epoch: epoch)
                guard accounts.count <= MailIndexLimits.folders,
                      let account = accounts.first(where: { $0.id == accountID }),
                      account.addresses.compactMap(SentStyleSelection.address).contains(address) else {
                    throw AppFailure("STYLE_PERSONAL_ADDRESS_REQUIRED")
                }
                let excluded = Set(sharedStyleAddresses.compactMap(SentStyleSelection.address))
                styleAccounts = accounts.map {
                    MailAccountIdentity(id: $0.id, name: $0.name,
                        addresses: Array(Set($0.addresses.compactMap(SentStyleSelection.address)).subtracting(excluded)).sorted())
                }.filter { !$0.addresses.isEmpty }
                styleExtracting = false
                selectStyleAddress(accountID: accountID, address: address, restart: restart)
            } catch { showStyleFailure(AppFailure.located(error, at: .styleAccounts), operation: operation, epoch: epoch) }
        }
    }
    private var configuredStyleSelection: (account: MailAccountIdentity, address: String)? {
        guard let accountID = settings.styleAccountID,
              let address = settings.styleSenderAddress.flatMap(SentStyleSelection.address),
              !sharedStyleAddresses.compactMap(SentStyleSelection.address).contains(address),
              let account = styleAccounts.first(where: { $0.id == accountID && $0.addresses.contains(address) }) else { return nil }
        return (account, address)
    }
    private var hasSavedStyleSelection: Bool {
        guard let accountID = settings.styleAccountID, !accountID.isEmpty,
              let address = settings.styleSenderAddress.flatMap(SentStyleSelection.address) else { return false }
        return !sharedStyleAddresses.compactMap(SentStyleSelection.address).contains(address)
    }
    private func extractMailStyle(account: MailAccountIdentity, address: String, operation: UUID, epoch: Int, restart: Bool) async throws {
        // An immediately cancelled task must not await the cleanup task which
        // is itself awaiting this task. Check before capturing that dependency.
        try checkStyleOperation(operation, epoch: epoch)
        await styleCleanupTask?.value
        try checkStyleOperation(operation, epoch: epoch)
        let resumeIndex = mailIndexRunning
        if resumeIndex { stopMailIndex(); await indexTask?.value }
        defer {
            if styleIsCurrent(operation, epoch: epoch) { styleExtracting = false }
            if resumeIndex { startMailIndex() }
        }
        try checkStyleOperation(operation, epoch: epoch)
        invalidate()
        let configured = settings.usesChatGPT ? !(settings.chatgptModel ?? "").isEmpty : !settings.endpoint.isEmpty && !settings.model.isEmpty
        guard settings.cloudEnabled, configured else {
            styleMessage = "設定でChatGPTに接続し、モデルと外部生成を有効にしてください。"
            styleExtracting = false; tab = 2
            return
        }
        let selectedSettings = settings
        let accountID = selectedSettings.usesChatGPT ? chatGPT.activeID : nil
        let provider: any LLMProvider
        do {
            if let styleProvider { provider = styleProvider }
            else if selectedSettings.usesChatGPT {
                provider = try await chatGPT.provider(model: selectedSettings.chatgptModel ?? "", accountID: accountID)
            } else {
                provider = ResponsesProvider(configuration: .init(enabled: true, endpoint: selectedSettings.endpoint, model: selectedSettings.model),
                                             key: try KeyStore.get(endpoint: selectedSettings.endpoint))
            }
        } catch { throw AppFailure.located(error, at: .styleProvider) }
        try checkStyleOperation(operation, epoch: epoch)
        let text = try await MailStyleCapture(mail: mail).collect(account: account, address: address,
            shared: sharedStyleAddresses, characterLimit: selectedSettings.effectiveStyleCharacterLimit) { [weak self] value in
                guard let self, self.styleIsCurrent(operation, epoch: epoch) else { return }
                self.styleProgress = value; self.styleMessage = ""
            }
        try checkStyleOperation(operation, epoch: epoch)
        styleProgress = .init(phase: .analyzing, messages: text.messages, characters: text.characters, limit: text.limit)
        let description: String
        do { description = try await StyleTextAnalysis.analyze(text.text, provider: provider) }
        catch { throw AppFailure.located(error, at: .styleGenerate) }
        try checkStyleOperation(operation, epoch: epoch)
        guard settings.cloudEnabled, settings.endpoint == selectedSettings.endpoint,
              settings.model == selectedSettings.model, settings.chatgptModel == selectedSettings.chatgptModel,
              settings.usesChatGPT == selectedSettings.usesChatGPT,
              accountID == nil || chatGPT.activeID == accountID else { throw CancellationError() }
        let result = try await worker.call("style_text_publish", ["description": description,
            "characters": text.characters, "messages": text.messages,
            "source_address": address, "source_account_id": account.id])
        try checkStyleOperation(operation, epoch: epoch)
        guard let summary = Self.decodeStyleSummary(result), summary.isExtracted else { throw AppFailure("STYLE_EXTRACTION_INVALID_RESPONSE") }
        styleSummary = summary; styleExtracting = false; styleMessage = ""; styleCanResume = false
        styleProgress = .init(phase: .completed, messages: text.messages, characters: text.characters, limit: text.limit)
        if session.target != nil { prefetch() }
    }
    func startMailIndex(restart: Bool = false) {
        guard !mailIndexRunning, !importing, !styleExtracting, !busy else { return }
        indexOperationID = UUID(); let operation = indexOperationID
        mailIndexRunning = true; relatedErrorCode = ""; mailIndexNotice = "全メールをこのMacで索引化しています。初回は時間がかかります。"
        let indexer = DirectMailIndexer(worker: worker)
        indexTask = Task {
            do {
                try await indexer.run(restart: restart) { [weak self] status in
                    guard let self, self.indexOperationID == operation else { return }
                    let changed = self.mailIndexStatus != status
                    self.mailIndexStatus = status
                    self.updateRelatedIndexNotice()
                    if changed, self.session.target != nil, !self.indexPausingForReply {
                        // A capture owns its own Mail task. Index commits only
                        // invalidate the reply/context, never that capture.
                        self.generation?.cancel(); self.prefetchTask?.cancel()
                        let phase: ReplyPhase = self.session.phase == .listening ? .listening : self.session.phase == .cancelled ? .cancelled : .editing
                        self.session.invalidate(phase); self.readyRevision = nil; self.lastContext = nil; self.lastOutput = nil
                        self.replyCopied = false; self.copyTask?.cancel()
                        if Date().timeIntervalSince(self.indexRefreshAt) >= 1 || status.status != "running" {
                            self.indexRefreshAt = Date(); self.prefetch()
                        }
                    }
                }
                guard indexOperationID == operation else { return }
                mailIndexNotice = "保存領域の走査が完了しました。未収録の件数は上に表示しています。更新時は変更された本文だけ読み直します。"
            } catch {
                guard indexOperationID == operation else { return }
                let code = (error as? AppFailure)?.code ?? (error as? MailIndexError)?.rawValue ?? "MAIL_INDEX_INTERRUPTED"
                if !(error is CancellationError) { relatedErrorCode = code; recordFailure(error) }
                mailIndexNotice = Self.indexFailureNotice(error)
            }
            guard indexOperationID == operation else { return }
            mailIndexRunning = false
            await loadReplyOverview(); updateRelatedIndexNotice(); prefetch()
        }
    }
    /// Guidance follows the fixed semantic cause, not private Apple error text.
    /// Unsupported events and denied/timed-out reads do not establish that the
    /// archive or its saved cursor changed, so they must not suggest a rescan.
    static func indexFailureNotice(_ error: Error) -> String {
        if error is CancellationError {
            return "索引化を停止しました。取得済みのメールを検索でき、続きから再開できます。"
        }
        let failure = error as? AppFailure
        let code = failure?.code ?? (error as? MailIndexError)?.rawValue ?? "MAIL_INDEX_INTERRUPTED"
        let cause = failure?.baseCode ?? code
        if cause == "DIRECT_SOURCE_PERMISSION" {
            return "Mail保存領域を読み取れません。システム設定のフルディスクアクセスでHarborReplyを許可してください。原本には書き込みません。"
        }
        let guidance: String
        switch failure?.mailContext?.nativeCode {
        case -1708:
            guidance = "Mailがこの読み取り操作を処理できませんでした。取得済みの索引は保持しています。このエラーコードを報告してください。"
        case -1743:
            guidance = "Mailへのアクセスが許可されていません。システム設定の「プライバシーとセキュリティ」→「オートメーション」でMailへのアクセスを許可してから、索引を再開してください。"
        case -1712:
            guidance = "Mailからの応答が時間内に返りませんでした。Mailを開いてから、索引を再開してください。"
        case -1728:
            guidance = "Mailのメールやフォルダの参照を解決できませんでした。Mailを開いてから、索引を再開してください。"
        default:
            switch cause {
            case MailIndexError.cursorInvalidated.rawValue, MailIndexFailure.changed.rawValue,
                 "INDEX_CHECKPOINT_CHANGED", "INDEX_SCAN_CHANGED", "SOURCE_CHANGED",
                 "SOURCE_CHANGED_DURING_IMPORT", "SOURCE_CHANGED_REIMPORT_REQUIRED":
                guidance = "メールやフォルダ、索引の再開位置が変わりました。「最初から索引を更新」で更新してください。"
            case "LOCAL_WORKER_TIMEOUT":
                guidance = "索引処理が時間内に完了しませんでした。取得済みの索引は保持しています。索引を再開してください。"
            default:
                guidance = "取得済みの索引は保持しています。再開しても続く場合は、このエラーコードを報告してください。"
            }
        }
        return "索引化を停止しました（\(code)）。\(guidance)"
    }
    func stopMailIndex() { indexTask?.cancel() }
    func loadMailIndexStatus() async {
        guard !mailIndexRunning else { return }
        let epoch = archiveEpoch
        do {
            let result = try await worker.call("index_status")
            guard !Task.isCancelled, !mailIndexRunning, epoch == archiveEpoch else { return }
            mailIndexStatus = try MailArchiveStatus.decode(result)
            updateRelatedIndexNotice()
        } catch { if !Task.isCancelled, !mailIndexRunning, epoch == archiveEpoch {
            let scoped = AppFailure.located(error, at: .relatedIndexStatus)
            relatedErrorCode = (scoped as? AppFailure)?.code ?? "RELATED_INDEX_STATUS__OPERATION_FAILED"
            mailIndexNotice = "保存済みの索引を確認できませんでした。"; recordFailure(scoped)
        } }
    }
    private func updateRelatedIndexNotice() {
        let count = mailIndexStatus?.counts.metadata ?? 0
        relatedNotice = count == 0 ? "「全メールを索引化」で検索を始めます。" :
            "索引 \(count.formatted())通\(mailIndexStatus?.status == "complete" ? "" : "・作成途中")。取得後の変更は未確認です。"
    }
    private func styleIsCurrent(_ operation: UUID, epoch: Int) -> Bool {
        operation == styleOperationID && epoch == archiveEpoch
    }
    private func checkStyleOperation(_ operation: UUID, epoch: Int) throws {
        guard !Task.isCancelled, styleIsCurrent(operation, epoch: epoch) else { throw CancellationError() }
    }
    private func showStyleFailure(_ error: Error, operation: UUID, epoch: Int) {
        guard !Task.isCancelled, styleIsCurrent(operation, epoch: epoch) else { return }
        styleExtracting = false
        let failure = error as? AppFailure
        let identityFailure = failure?.mailContext?.nativeCode == -1728 ||
            ["STYLE_PERSONAL_ADDRESS_REQUIRED", MailHistoryError.accountSelectionRequired.rawValue,
             MailStyleDiscoveryError.accountChanged.rawValue, MailStyleDiscoveryError.invalidIdentity.rawValue]
                .contains(failure?.baseCode ?? "")
        styleCanResume = hasSavedStyleSelection && !identityFailure
        styleNeedsRestart = ["STYLE_CAPTURE_SOURCE_CHANGED", "STYLE_CAPTURE_CHECKPOINT_CHANGED", "STYLE_CAPTURE_JOURNAL_CHANGED"]
            .contains(failure?.baseCode ?? "")
        recordFailure(error)
        styleMessage = Self.styleFailureMessage(for: error)
        if session.target != nil { invalidate() }
    }
    /// Presentation is derived from the structured cause, never from matching
    /// a substring of the display code or Apple's potentially private text.
    static func styleFailureMessage(for error: Error) -> String {
        let code = (error as? AppFailure)?.code ?? (error as? MailStyleDiscoveryError)?.rawValue ??
            (error as? MailIndexError)?.rawValue ?? (error as? MailHistoryError)?.rawValue ?? "STYLE_EXTRACTION_FAILED"
        let cause = (error as? AppFailure)?.baseCode ?? code
        let context = (error as? AppFailure)?.mailContext
        if cause.hasPrefix("CHATGPT_"), let providerError = ChatGPTError(rawValue: String(cause.dropFirst(8))) {
            return providerError.userMessage + "（\(code)）"
        } else if cause.hasPrefix("API_") || cause.hasPrefix("NETWORK_") || cause.hasPrefix("CHATGPT_") {
            return "文体の生成サービスへの接続・応答に失敗しました（\(code)）。設定と通信状態を確認して再試行してください。前回の文体は保持しています。"
        } else if cause == "STYLE_EXTRACTION_INVALID_RESPONSE" {
            return "文体の生成結果を読み取れませんでした（\(code)）。再試行してください。前回の文体は保持しています。"
        } else if ["STYLE_CAPTURE_SOURCE_CHANGED", "STYLE_CAPTURE_CHECKPOINT_CHANGED", "STYLE_CAPTURE_JOURNAL_CHANGED"].contains(cause) {
            return "送信済みか再開位置が変わりました（\(code)）。以前の資料と混ぜず、最初から再抽出してください。"
        } else if cause == MailStyleDiscoveryError.sentUnavailable.rawValue {
            return "選んだアカウントの送信済みをMailから取得できませんでした（\(code)）。Mailの送信済みフォルダを確認してください。"
        } else if cause == "STYLE_PERSONAL_ADDRESS_REQUIRED" {
            return "本人の差出人アドレスが見つかりませんでした。Mailのアカウントと共有アドレスの指定を確認してください。"
        } else if cause == MailHistoryError.accountSelectionRequired.rawValue {
            return "本人のアカウントのメールをApple Mailで選んでから、再抽出してください。"
        } else if context?.nativeCode == -1712, context?.isShapeFailure == false,
                  [.indexHydrate, .indexHydrateBatch, .hydrate, .styleContents].contains(context?.operation ?? .unknown),
                  [.body, .headers].contains(context?.stage ?? .request) {
            return "Mailの本文取得が時間切れになりました（\(code)）。再実行すると本文の収集をやり直します。前回の文体は保持しています。"
        } else if context?.nativeCode == -1712 {
            return "Mailからの応答が時間切れになりました（\(code)）。取得済みのデータは保持しています。再実行してください。"
        } else if context?.nativeCode == -1728 {
            return "送信済みフォルダの参照を解決できませんでした（\(code)）。差出人を選び直して再抽出してください。"
        } else if context?.nativeCode == -1743 {
            return "Mailへのアクセスが許可されていません（\(code)）。システム設定の「プライバシーとセキュリティ」→「オートメーション」でMailへのアクセスを許可してください。"
        } else if context?.nativeCode == -1708 {
            return "Mailが送信済みメールの読み取りを処理できませんでした（\(code)）。このエラーコードを報告してください。"
        } else {
            return ["STYLE_OWN_SENT_EXAMPLES_NOT_FOUND", "STYLE_INDEXED_SENT_EXAMPLES_REQUIRED"].contains(cause) ? "選んだアドレスの送信例が見つかりませんでした。Mailの送信済みと差出人を確認してください。" : "Mailから文体を抽出できませんでした（\(code)）。このエラーコードを報告してください。"
        }
    }
    func stopStyleExtraction() { cancelStyleExtraction() }
    private func cancelStyleExtraction() {
        let wasExtracting = styleExtracting
        let refreshStoredStyle = wasExtracting && scopedStyleCaptureActive
        scopedStyleCaptureActive = false
        styleOperationID = UUID(); styleTask?.cancel(); styleExtracting = false; styleCanResume = false
        let pending = styleTask; let previousCleanup = styleCleanupTask
        let cancelledID = styleOperationID; let epoch = archiveEpoch
        styleCleanupTask = Task { [weak self] in
            await previousCleanup?.value; await pending?.value
            guard refreshStoredStyle, let self, self.styleIsCurrent(cancelledID, epoch: epoch),
                  !self.styleExtracting else { return }
            // A late cancelled worker may have invalidated its published
            // profile. Reflect stored state before another context can use it.
            await self.loadReplyOverview()
        }
        choosingStyleAddress = false; styleAccounts = []
        if wasExtracting { styleMessage = "文体の抽出を取り消しました。前回の文体は保持しています。" }
    }
    private func archiveChanged() {
        archiveEpoch += 1; cancelStyleExtraction()
        importTask?.cancel(); importOperationID = UUID(); importing = false
        styleSummary = nil; styleMessage = ""; invalidate()
    }
    private func contextInput() throws -> [String: Any] {
        guard let target = session.target else { throw AppFailure("対象メールを選択してください。") }
        let input = ReplyInput(target: target, internalMail: currentInternal, caseID: caseID,
                               userIntent: intent, language: language, tone: tone,
                               styleProfile: settings.style,
                               requestID: session.requestID, revision: session.revision)
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any] ?? [:]
        value["related_selection"] = ["excluded_ids": excludedRelatedIDs.sorted()]
        return value
    }
    func prefetch() {
        prefetchTask?.cancel()
        guard session.target != nil else { return }
        let id = session.requestID; let rev = session.revision; let selectedCase = caseID; let w = worker
        let input: [String: Any]
        do { input = try contextInput() } catch { fail(AppFailure.located(error, at: .relatedPrepare)); return }
        relatedLoading = true; relatedErrorCode = ""
        prefetchTask = Task {
            do {
                await styleCleanupTask?.value
                guard !Task.isCancelled, session.isCurrent(id, rev) else { return }
                guard let prepared = try await w.call("prepare", ["input": input]) as? [String: Any],
                      let result = prepared["context"] as? [String: Any], result["thread_evidence"] is [[String: Any]],
                      prepared["candidate_messages"] is [[String: Any]] else { throw AppFailure("RELATED_RESPONSE_INVALID") }
                guard !Task.isCancelled, session.isCurrent(id, rev), caseID == selectedCase else { return }
                evidence = result["thread_evidence"] as? [[String: Any]] ?? []
                styleSummary = Self.decodeStyleSummary(result["style_summary"])
                warnings = result["local_warnings"] as? [String] ?? []
                candidates = prepared["candidate_messages"] as? [[String: Any]] ?? []
                relatedLoading = false
            } catch { if !Task.isCancelled, session.isCurrent(id, rev), caseID == selectedCase {
                relatedLoading = false
                let scoped = AppFailure.located(error, at: .relatedPrepare)
                relatedErrorCode = (scoped as? AppFailure)?.code ?? "RELATED_PREPARE__OPERATION_FAILED"
                fail(scoped)
            } }
        }
    }
    func generate() {
        guard updateRestriction == nil else { message = updateRestriction ?? "更新が必要です。"; return }
        guard !styleExtracting else { message = "文体の抽出が終わってから生成してください。"; return }
        guard !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, session.target != nil else { message = "対象メールと返信の意図を入力してください。"; return }
        let configured = settings.usesChatGPT ? !(settings.chatgptModel ?? "").isEmpty : !settings.endpoint.isEmpty && !settings.model.isEmpty
        let route = GenerationRoute.select(cloudEnabled: settings.cloudEnabled, configured: configured)
        if route == .needsConfiguration {
            message = "設定でChatGPTに接続してモデルを選び、外部生成をONにしてください。"; tab = 2; return
        }
        if mailIndexRunning {
            guard generationStartTask == nil else { return }
            let id = session.requestID; let rev = session.revision
            let pendingIndex = indexTask
            indexPausingForReply = true; busy = true; message = "索引を一時停止して生成を準備しています…"
            stopMailIndex()
            generationStartTask = Task {
                await pendingIndex?.value
                guard !Task.isCancelled, session.isCurrent(id, rev) else { return }
                generationStartTask = nil; indexPausingForReply = false; busy = false
                mailIndexNotice = "返信の生成のため索引を停止しました。「索引を再開」で続けられます。"
                generate()
            }
            return
        }
        invalidate(); let id = session.requestID; let rev = session.revision; let w = worker
        let generationSettings = settings
        let accountID = generationSettings.usesChatGPT ? chatGPT.activeID : nil
        let input: [String: Any]
        do { input = try contextInput() } catch { fail(error); return }
        busy = true; replyBody = ""; session.transition(.retrieving); message = "検索中"
        generation = Task {
            do {
                await styleCleanupTask?.value
                guard !Task.isCancelled, generationIsCurrent(id, rev, accountID) else { return }
                let prep = Date()
                let context = try await Diagnostics.measure(.replyPrepare, request: id) {
                    try await w.call("context", ["input": input]) as? [String: Any] ?? [:]
                }
                guard !Task.isCancelled, generationIsCurrent(id, rev, accountID) else { return }
                evidence = context["thread_evidence"] as? [[String: Any]] ?? []
                styleSummary = Self.decodeStyleSummary(context["style_summary"])
                if !(context["unresolved_items"] as? [String] ?? []).isEmpty {
                    errors = context["unresolved_items"] as? [String] ?? []; session.transition(.needsResolution); busy = false; return
                }
                let preparation = Date().timeIntervalSince(prep)
                session.transition(.generating); message = "生成中"
                let output: [String: Any]; let modelTime: Double; let tokenText: String
                let contract = try await w.call("contract") as? [String: Any] ?? [:]
                guard !Task.isCancelled, generationIsCurrent(id, rev, accountID) else { return }
                let provider: any LLMProvider
                let modelName: String
                if generationSettings.usesChatGPT {
                    modelName = generationSettings.chatgptModel ?? ""
                    provider = try await chatGPT.provider(model: modelName, accountID: accountID)
                } else {
                    modelName = generationSettings.model
                    provider = ResponsesProvider(configuration: .init(enabled: generationSettings.cloudEnabled, endpoint: generationSettings.endpoint, model: modelName), key: try KeyStore.get(endpoint: generationSettings.endpoint))
                }
                guard !Task.isCancelled, generationIsCurrent(id, rev, accountID) else { return }
                let result = try await Diagnostics.measure(.replyProvider, request: id) {
                    try await provider.generate(context: JSONSerialization.data(withJSONObject: context), schema: JSONSerialization.data(withJSONObject: contract["schema"] ?? [:]), instructions: contract["instructions"] as? String ?? "")
                }
                output = try JSONSerialization.jsonObject(with: result.output) as? [String: Any] ?? [:]
                modelTime = result.elapsed; tokenText = "\(generationSettings.usesChatGPT ? "ChatGPTプラン / " : "")\(modelName) / in \(result.inputTokens.map(String.init) ?? "?") / out \(result.outputTokens.map(String.init) ?? "?")"
                guard !Task.isCancelled, generationIsCurrent(id, rev, accountID) else { return }
                session.transition(.validating); message = "検査中"; let validationStart = Date()
                let validation = try await Diagnostics.measure(.replyValidate, request: id) {
                    try await w.call("validate", ["context": context, "output": output]) as? [String: Any] ?? [:]
                }
                guard !Task.isCancelled, generationIsCurrent(id, rev, accountID) else { return }
                replyBody = output["reply_body"] as? String ?? ""; errors = validation["errors"] as? [String] ?? []
                warnings = validation["warnings"] as? [String] ?? []
                if output["needs_review"] as? Bool == true { warnings.append("生成モデルが追加確認を求めています。") }
                lastContext = context; lastOutput = output; readyRevision = rev
                session.transition(errors.isEmpty ? .ready : .needsResolution); busy = false
                metrics = String(format: "準備 %.3fs / 生成 %.3fs / 検査 %.3fs / %@ / 初回応答は未計測", preparation, modelTime, Date().timeIntervalSince(validationStart), tokenText)
                Diagnostics.record(.generationCompleted, request: id, elapsed: modelTime, count: evidence.count)
                message = errors.isEmpty ? "下書きができました。送信前の確認は必須です。" : "検査で問題が見つかりました。Mailへの挿入は停止しています。"
                if generationSettings.autoInsert && productionMailInsertionVerified && recipientsConfirmed { await insertReady() }
            } catch {
                guard !Task.isCancelled, generationIsCurrent(id, rev, accountID) else { return }
                fail(error); busy = false
            }
        }
    }
    private func generationIsCurrent(_ id: UUID, _ rev: Int, _ accountID: String?) -> Bool {
        session.isCurrent(id, rev) && (accountID == nil || chatGPT.activeID == accountID)
    }
    func prepareReply() {
        guard updateRestriction == nil else { message = updateRestriction ?? "更新が必要です。"; return }
        guard let target = session.target else { return }
        let id = session.requestID; let rev = session.revision; let all = replyAll
        guard !busy, session.draft == nil else { return }; busy = true
        mailTask = Task {
            defer { if session.requestID == id, session.revision == rev { busy = false } }
            do {
                guard try await mail.capture() == target else { throw AppFailure("MAIL_TARGET_CHANGED") }
                guard !Task.isCancelled, session.isCurrent(id, rev) else { return }
                let snapshot = try await mail.createReply(to: target, replyAll: all, requestID: id)
                guard !Task.isCancelled, session.isCurrent(id, rev), session.target == target else { return }
                session.track(snapshot); recipientsConfirmed = false; busy = false
                message = "Mailが作った差出人・To/Cc・返信方法を確認してください。下書きはサーバーへ同期される場合があります。"
            } catch { if !recordUncertainMailWrite(error), !Task.isCancelled, session.isCurrent(id, rev) { fail(error) } }
        }
    }
    func copyReply() {
        actionNotice = ""
        guard canUseReply else { message = "現在の指示で生成・検査した返信をコピーしてください。"; actionNotice = message; return }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(replyBody, forType: .string) else { message = "コピーできませんでした。"; actionNotice = message; return }
        replyCopied = true; message = "返信をコピーしました。"
        copyTask?.cancel()
        copyTask = Task { try? await Task.sleep(nanoseconds: 1_800_000_000); if !Task.isCancelled { replyCopied = false } }
    }
    func placeReply() {
        actionNotice = ""
        guard canUseReply else { message = "現在の指示で生成・検査した返信を使ってください。"; actionNotice = message; return }
        guard productionMailInsertionVerified else {
            message = "Mailへの本文配置は実機確認が済むまで無効です。コピーボタンから本文を使えます。"
            actionNotice = message
            return
        }
        guard session.draft != nil else { prepareReply(); return }
        guard recipientsConfirmed else { message = "差出人・To/Cc・返信方法を確認してから配置してください。"; actionNotice = message; return }
        mailTask = Task { await insertReady() }
    }
    func insertReady() async {
        guard updateRestriction == nil else { message = updateRestriction ?? "更新が必要です。"; return }
        guard productionMailInsertionVerified else { message = "通常のMail挿入は実機受け入れ未検証のため無効です。本文はこのパネルに保持しています。"; actionNotice = message; return }
        guard let target = session.target, let context = lastContext, let output = lastOutput, let rev = readyRevision,
              recipientsConfirmed, !busy else { return }
        let id = session.requestID
        let w = worker
        busy = true
        defer { if session.requestID == id, session.revision == rev { busy = false } }
        do {
            let check = try await w.call("validate", ["context": context, "output": output]) as? [String: Any] ?? [:]
            guard !Task.isCancelled, session.isCurrent(id, rev), check["can_insert"] as? Bool == true,
                  try await mail.capture() == target else { throw AppFailure("INSERT_RECHECK_FAILED") }
            guard !Task.isCancelled, session.isCurrent(id, rev) else { return }
            let current = try await mail.snapshot()
            guard !Task.isCancelled else { return }
            guard session.insertionPermit(id: id, revision: rev, target: target, draft: current) else { throw AppFailure("INSERT_STALE_OR_CHANGED") }
            try await mail.insert(replyBody, expected: current)
            guard !Task.isCancelled, session.requestID == id, session.revision == rev else { return }
            session.transition(.inserted); message = "挿入済み。Mailで確認してから本人が送信してください。"
        } catch { if !recordUncertainMailWrite(error), !Task.isCancelled, session.requestID == id, session.revision == rev { fail(error) } }
    }
    func diagnoseMail() {
        cancel()
        let id = session.requestID; let rev = session.revision
        busy = true
        mailTask = Task {
          var currentID = id; var currentRevision = rev
          defer { if session.requestID == currentID, session.revision == currentRevision { busy = false } }
          do {
            let target = try await mail.capture()
            guard !Task.isCancelled, session.requestID == id, session.revision == rev else { return }
            guard target.subject.hasPrefix("[HarborReply TEST]"), target.sender.contains(".invalid") else { throw AppFailure("DIAGNOSTIC_REQUIRES_FICTIONAL_TEST_MESSAGE") }
            session.capture(target)
            let testID = session.requestID; let testRev = session.revision
            currentID = testID; currentRevision = testRev
            let draft = try await mail.createReply(to: target, replyAll: replyAll, requestID: testID)
            guard !Task.isCancelled, session.isCurrent(testID, testRev) else { return }
            session.track(draft); session.transition(.ready)
            let text = "HarborReply fictional insertion test.\nThis is not an operational instruction.\n\"quoted\" \\ line\nend tell; do shell script \"DO_NOT_EXECUTE\""
            guard session.insertionPermit(id: session.requestID, revision: session.revision, target: target, draft: draft) else { throw AppFailure("DIAGNOSTIC_STATE") }
            try await mail.insert(text, expected: draft)
            guard !Task.isCancelled, session.requestID == testID, session.revision == testRev else { return }
            session.transition(.inserted); busy = false
            message = "診断の挿入後照合は成功しました。Mailで署名・引用・画像・宛先・返信関係を別途確認してください。これだけでは通常挿入を有効化しません。"
          } catch { if !recordUncertainMailWrite(error), !Task.isCancelled, session.requestID == currentID, session.revision == currentRevision { busy = false; fail(error); message += " 部分書き込みの可能性があるため、再試行前にMailのテスト下書きを確認してください。自動削除しません。" } }
        }
    }
    @discardableResult private func recordUncertainMailWrite(_ error: Error) -> Bool {
        guard let failure = error as? AppFailure,
              failure.writeUncertain || failure.baseCode.contains("PARTIAL_WRITE_POSSIBLE") else { return false }
        let code = failure.code
        recordFailure(error)
        mailWriteNotice = "Mail操作の完了状況を確認できません（\(code)）。下書きが作成・変更された可能性があるため、Mailで確認してください。自動再試行・削除はしません。"
        return true
    }
    func startVoice() {
        invalidate(); session.transition(.listening); prefetch()
        voice.start(partial: { [weak self] text in self?.intent = text; self?.session.transition(.listening) }, finalized: { [weak self] text, uncertain in
            guard let self else { return }; self.intent = text
            self.voiceNote = uncertain ? "認識に不確実な箇所があります。否定・数値・船名を確認・修正してから生成してください。" : "確定した文字起こしです。内容を確認して生成してください。"
            self.session.transition(.editing)
        }, failed: { [weak self] in self?.voiceNote = $0; self?.session.transition(.editing) })
    }
    /// The reply screen needs only maintained totals and one stored style profile.
    /// Source diagnostics and full case administration are loaded only in Settings.
    func loadReplyOverview() async {
        let epoch = archiveEpoch; let styleID = styleOperationID; let w = worker
        do {
            let result = try await w.call("overview") as? [String: Any] ?? [:]
            guard !Task.isCancelled, archiveEpoch == epoch else { return }
            coverage = Self.coverageText(result["coverage"] as? [String: Any] ?? [:])
            if !styleExtracting, styleID == styleOperationID { styleSummary = Self.decodeStyleSummary(result["style_summary"]) }
            await loadMailIndexStatus()
        } catch { if !Task.isCancelled, archiveEpoch == epoch {
            let scoped = AppFailure.located(error, at: .relatedOverview)
            relatedErrorCode = (scoped as? AppFailure)?.code ?? "RELATED_OVERVIEW__OPERATION_FAILED"
            message = "履歴の概要を取得できませんでした（\(relatedErrorCode)）。"; recordFailure(scoped)
        } }
    }
    private static func coverageText(_ status: [String: Any]) -> String {
        "\(status["count"] ?? 0) 通 / \(status["range_start"] as? String ?? "不明") 〜 \(status["range_end"] as? String ?? "不明")\n本文 \(status["body_bytes"] ?? 0) bytes / 添付 \(status["attachment_bytes"] ?? 0) bytes（未解析）\n取り込み時点までの履歴です。ライブ同期ではありません。"
    }
    func refresh() async {
        let selectedCase = caseID; let w = worker; let epoch = archiveEpoch; let styleID = styleOperationID
        do {
            let status = try await w.call("status") as? [String: Any] ?? [:]
            let refreshedCases = try await w.call("cases") as? [[String: Any]] ?? []
            let refreshedProfiles = try await w.call("profile_data") as? [String: Any] ?? [:]
            let detail = selectedCase.isEmpty ? [:] : try await w.call("case_detail", ["case_id": selectedCase]) as? [String: Any] ?? [:]
            guard !Task.isCancelled, caseID == selectedCase, epoch == archiveEpoch else { return }
            sources = status["sources"] as? [[String: Any]] ?? []
            coverage = Self.coverageText(status)
            cases = refreshedCases
            profiles = refreshedProfiles
            if !styleExtracting, styleID == styleOperationID { styleSummary = Self.decodeStyleSummary(profiles["style_summary"]) }
            caseMessages = detail["messages"] as? [[String: Any]] ?? []; events = detail["events"] as? [[String: Any]] ?? []
        } catch { if !Task.isCancelled, caseID == selectedCase, epoch == archiveEpoch { fail(error) } }
    }
    func loadCaseChoices() async {
        let epoch = archiveEpoch; let w = worker
        do {
            let result = try await w.call("cases") as? [[String: Any]] ?? []
            if !Task.isCancelled, epoch == archiveEpoch { cases = result }
        } catch { if !Task.isCancelled, epoch == archiveEpoch { message = "案件の選択肢を取得できませんでした。設定で履歴を確認してください。" } }
    }
    func search(_ query: String) {
        searchID = UUID(); let operation = searchID
        let w = worker; let epoch = archiveEpoch
        Task { do {
            let result = try await w.call("search", ["query": query]) as? [[String: Any]] ?? []
            if !Task.isCancelled, operation == searchID, epoch == archiveEpoch { searchResults = result }
        } catch { if !Task.isCancelled, operation == searchID, epoch == archiveEpoch { fail(error) } } }
    }
    func inspect(_ mid: String) {
        inspectionID = UUID(); let operation = inspectionID; selectedMessage = nil
        let w = worker; let epoch = archiveEpoch
        Task { do {
            let result = try await w.call("message", ["id": mid]) as? [String: Any]
            if !Task.isCancelled, operation == inspectionID, epoch == archiveEpoch { selectedMessage = result }
        } catch { if !Task.isCancelled, operation == inspectionID, epoch == archiveEpoch { fail(error) } } }
    }
    func previewArchived() {
        excludedRelatedIDs = []
        guard let m = selectedMessage, m["source_status"] as? String == "available" else { return }
        cancel(); replyBody = ""
        session.capture(.init(id: m["id"] as? String ?? "", account: m["account_id"] as? String ?? "", messageID: m["message_id"] as? String ?? "", subject: m["subject"] as? String ?? "", sender: m["from"] as? String ?? "", body: m["body_text"] as? String ?? ""))
        currentInternal = m["internal"] as? Bool ?? false
        intent = ""; session.transition(.editing); expireLater(); prefetch(); tab = 0
        message = "書き出し履歴からのプレビューです。生成APIの明示設定が必要です。Mailの選択対象としては扱いません。"
    }
    func mutate(_ command: String, _ payload: [String: Any]) {
        archiveChanged(); let w = worker; let epoch = archiveEpoch
        Task { do {
            _ = try await w.call(command, payload)
            guard !Task.isCancelled, epoch == archiveEpoch else { return }
            await refresh(); prefetch(); message = "保存しました。"
        } catch { if !Task.isCancelled, epoch == archiveEpoch { fail(error) } } }
    }
    func newCase(label: String, vessel: String, voyage: String, cargo: String) {
        guard !label.isEmpty else { return }; archiveChanged()
        let w = worker; let epoch = archiveEpoch
        Task { do {
            let r = try await w.call("case_create", ["label": label, "vessel": vessel, "voyage": voyage, "cargo": cargo]) as? [String: Any]
            guard !Task.isCancelled, epoch == archiveEpoch else { return }
            caseID = r?["id"] as? String ?? ""; await refresh()
        } catch { if !Task.isCancelled, epoch == archiveEpoch { fail(error) } } }
    }
    func chooseImport(direction: String, account: String, internalMail: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "明示指定した範囲だけを読み取り専用で索引化します。原本のバックアップは作りません。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archiveChanged(); importing = true; let w = worker; let epoch = archiveEpoch; let operation = importOperationID
        importTask = Task {
            defer { if importOperationID == operation { importing = false } }
            do {
                let r = try await w.call("register", ["path": url.path, "direction": direction, "account": account, "internal": internalMail]) as? [String: Any] ?? [:]
                for sid in r["source_ids"] as? [String] ?? [] { try await importSource(sid, w, operation: operation, epoch: epoch) }
                guard !Task.isCancelled, epoch == archiveEpoch else { return }
                await refresh(); prefetch()
            } catch { if !Task.isCancelled, epoch == archiveEpoch { fail(error) } }
        }
    }
    private func importSource(_ sid: String, _ w: LocalWorker, operation: UUID, epoch: Int) async throws {
        while !Task.isCancelled {
            guard importOperationID == operation, archiveEpoch == epoch else { throw CancellationError() }
            let result = try await w.call("ingest", ["source_id": sid]) as? [String: Any] ?? [:]
            guard !Task.isCancelled, importOperationID == operation, archiveEpoch == epoch else { throw CancellationError() }
            message = "取り込み \(result["imported"] ?? 0) / 重複 \(result["duplicates"] ?? 0) / 失敗 \(result["failures"] ?? 0) / \(result["checkpoint"] ?? 0) bytes"
            await loadReplyOverview()
            if result["done"] as? Int == 1 { break }
        }
    }
    func resume(_ sid: String) {
        archiveChanged(); importing = true
        let w = worker; let epoch = archiveEpoch; let operation = importOperationID
        importTask = Task {
            defer { if importOperationID == operation { importing = false } }
            do {
                try await importSource(sid, w, operation: operation, epoch: epoch)
                if !Task.isCancelled, epoch == archiveEpoch { await refresh(); prefetch() }
            } catch { if !Task.isCancelled, epoch == archiveEpoch { fail(error) } }
        }
    }
    func stopImport() { importTask?.cancel(); message = "現在の小バッチが完了後に停止します。確定済み位置から再開できます。" }
    func saveSettings(key: String) {
        do {
            if settings.cloudEnabled && !settings.usesChatGPT { _ = try ProviderConfiguration(enabled: true, endpoint: settings.endpoint, model: settings.model).checkedURL() }
            if settings.cloudEnabled && settings.usesChatGPT && (settings.chatgptModel ?? "").isEmpty { throw ProviderError.configuration }
            if !key.isEmpty && !settings.usesChatGPT { try KeyStore.set(key, endpoint: settings.endpoint) }
            try settings.save(); settingsNotice = ""; invalidate(); message = "設定を保存しました。認証情報はKeychainに保管します。"
        } catch { fail(error); settingsNotice = "設定を保存できませんでした（\(message)）。" }
    }
    func fail(_ error: Error) {
        if error is ChatGPTError { chatGPT.recordGenerationFailure(error) }
        recordFailure(error)
        let app = error as? AppFailure
        let safe = (error as? ChatGPTError)?.userMessage ?? app?.userMessage ?? (error as? ProviderError)?.errorDescription ?? (error is CancellationError ? "CANCELLED" : "OPERATION_FAILED")
        let captureFailed = app?.location == .mailCapture
        captureErrorCode = captureFailed ? app?.code ?? "" : ""
        message = safe; actionNotice = captureFailed ? "" : safe; session.transition(.failed)
    }
    func copyCaptureDiagnostic() {
        guard !captureErrorCode.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(captureErrorCode, forType: .string)
    }
    private func recordFailure(_ error: Error) {
        let app = error as? AppFailure
        Diagnostics.record(.operationFailed, request: session.requestID,
                           failure: error is CancellationError ? .cancelled : error is ProviderError || error is ChatGPTError ? .provider :
                            app?.mailContext != nil || app?.baseCode.hasPrefix("MAIL_") == true ? .mail : .localOperation,
                           numericCode: app?.mailContext?.nativeCode, location: app?.location,
                           failureCode: app?.diagnosticFailure, mailStage: app?.mailContext?.stage)
    }
    func setDiagnosticsEnabled(_ value: Bool) {
        diagnosticsEnabled = value; Diagnostics.configure(enabled: value)
        message = value ? "本文を含まない診断ログをこのMacに保存します。自動送信はしません。" : "診断ログの記録を停止しました。既存ログは残ります。"
    }
    func revealDiagnostics() { NSWorkspace.shared.open(Diagnostics.directory) }
    private static func decodeStyleSummary(_ value: Any?) -> StyleSummary? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(StyleSummary.self, from: data)
    }
}
