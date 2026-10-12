import AppKit
import HarborCore

@main struct SimpleStyleVerification {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args == ["--allow-real-mail"] || args == ["--allow-real-mail", "--allow-cloud-generation"] || args == ["--allow-real-mail", "--index-only"] else { exit(64) }
        _ = NSApplication.shared
        Diagnostics.configure(enabled: false, persist: false)
        let settings = Settings.load(), mail = AppleMailBridge()
        let start = Date()
        var report: [String: Any] = ["mailWrites": false, "modelCalled": false, "outcome": "failed"]
        do {
            if args.contains("--index-only") {
                var cursor: MailMailboxCursor? = nil
                var folders = 0, pages = 0, staleCountsRejected = 0
                repeat {
                    let discovery = try await mail.indexMailboxes(after: cursor, limit: MailIndexLimits.folders)
                    for box in discovery.mailboxes {
                        let request = MailIndexCursor(accountID: box.accountID, mailboxPath: box.path,
                            expectedCount: box.messageCount, scanID: discovery.scanID, isLocal: box.isLocal, role: box.role)
                        let stale = MailIndexCursor(accountID: box.accountID, mailboxPath: box.path,
                            expectedCount: box.messageCount + 1, scanID: discovery.scanID, isLocal: box.isLocal, role: box.role)
                        do {
                            _ = try await mail.indexPage(cursor: stale, limit: 1)
                            throw AppFailure("TEST_STALE_COUNT_ACCEPTED")
                        } catch {
                            guard let context = (error as? AppFailure)?.mailContext,
                                  context.operation == .indexPage, context.stage == .messageCount,
                                  context.nativeCode == 9130 else { throw error }
                            staleCountsRejected += 1
                        }
                        let refreshed = MailIndexCursor(accountID: request.accountID, mailboxPath: request.mailboxPath,
                            scanID: request.scanID, isLocal: request.isLocal, role: request.role)
                        _ = try await mail.indexPage(cursor: refreshed, limit: 1)
                        folders += 1; pages += 1
                    }
                    cursor = discovery.nextCursor
                } while cursor != nil
                let data = try JSONSerialization.data(withJSONObject: ["outcome": "passed", "folders": folders,
                    "pages": pages, "staleCountsRejected": staleCountsRejected, "seconds": Date().timeIntervalSince(start), "mailWrites": false])
                FileHandle.standardOutput.write(data); exit(0)
            }
            let accounts = try await mail.styleAccounts()
            guard let account = accounts.first(where: { $0.id == settings.styleAccountID }),
                  let sender = settings.styleSenderAddress else { throw AppFailure("STYLE_PERSONAL_ADDRESS_REQUIRED") }
            let text = try await MailStyleCapture(mail: mail).collect(account: account, address: sender,
                shared: settings.sharedAddresses.components(separatedBy: ","), characterLimit: settings.effectiveStyleCharacterLimit,
                progress: { _ in })
            report["characters"] = text.characters; report["messages"] = text.messages
            report["limit"] = text.limit; report["collectionSeconds"] = Date().timeIntervalSince(start)
            report["outcome"] = "collected"
            let configured = settings.usesChatGPT ? !(settings.chatgptModel ?? "").isEmpty : !settings.endpoint.isEmpty && !settings.model.isEmpty
            report["providerConfigured"] = configured; report["cloudEnabled"] = settings.cloudEnabled
            if configured && settings.cloudEnabled && args.contains("--allow-cloud-generation") {
                let provider: any LLMProvider
                if settings.usesChatGPT {
                    let selectedAccount = UserDefaults.standard.persistentDomain(forName: "local.harborreply.app")?["chatgptActiveClient"] as? String
                    let connection = ChatGPTConnection(activeID: selectedAccount ?? "")
                    await connection.restore()
                    provider = try await connection.provider(model: settings.chatgptModel ?? "", accountID: connection.activeID)
                } else {
                    provider = ResponsesProvider(configuration: .init(enabled: true, endpoint: settings.endpoint, model: settings.model),
                        key: try KeyStore.get(endpoint: settings.endpoint))
                }
                let modelStart = Date(); report["modelCalled"] = true
                let description = try await StyleTextAnalysis.analyze(text.text, provider: provider)
                report["modelSeconds"] = Date().timeIntervalSince(modelStart)
                report["descriptionCharacters"] = description.count
                report["outcome"] = "analyzed"
            }
        } catch {
            if let failure = error as? AppFailure, let context = failure.mailContext {
                report["nativeCode"] = context.nativeCode
            }
            let safe = AppFailure.located(error, at: .styleCapture) as? AppFailure
            report["failureCode"] = safe?.code
            report["outcome"] = "failed"
        }
        report["totalSeconds"] = Date().timeIntervalSince(start)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
        exit(report["outcome"] as? String == "failed" ? 1 : 0)
    }
}
