import AppKit
import Sparkle
import HarborCore

/// Owns Sparkle's lifecycle; all update traffic contains public version metadata only.
@MainActor final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var refreshTask: Task<Void, Never>?
    private var policy: UpdatePolicy?
    private let model: ReplyCoordinator
    private let policyURL: URL?
    private let publicKey: Data?
    private let build: Int
    private let cacheURL: URL

    init(model: ReplyCoordinator, bundle: Bundle = .main) {
        self.model = model
        let info = bundle.infoDictionary ?? [:]
        policyURL = (info["HarborUpdatePolicyURL"] as? String).flatMap(URL.init(string:))
        publicKey = (info["SUPublicEDKey"] as? String).flatMap { Data(base64Encoded: $0) }
        build = (info["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
        cacheURL = Settings.directory.appendingPathComponent("update-policy.json")
        super.init()
        guard let feed = info["SUFeedURL"] as? String, URL(string: feed)?.scheme == "https",
              policyURL?.scheme == "https", let publicKey, publicKey.count == 32 else { return }
        if let data = try? Data(contentsOf: cacheURL) { policy = try? UpdatePolicy.verify(data, publicKey: publicKey) }
        applyRestriction()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPolicy()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private var nextFetch = Date.distantPast
    private func refreshPolicy() async {
        applyRestriction()
        guard Date() >= nextFetch, let policyURL, let publicKey else { return }
        nextFetch = Date().addingTimeInterval(3600)
        do {
            var request = URLRequest(url: policyURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https" else { return }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 32_768 else { return }
                data.append(byte)
            }
            let verified = try UpdatePolicy.verify(data, publicKey: publicKey, previousSequence: policy?.sequence ?? 0)
            guard verified.issuedAt <= Date().addingTimeInterval(300), verified.expiresAt > Date() else { return }
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: cacheURL, options: .atomic)
            policy = verified
            applyRestriction()
        } catch { /* Retain last verified policy, including its original expiry. */ }
    }
    private func applyRestriction() {
        model.updateRestriction = policy?.restriction(currentBuild: build, now: Date())
            ?? (policy == nil ? "更新情報を確認中です。接続できない場合は、インターネット接続後に「アップデートを確認…」を選んでください。" : nil)
    }
    func checkForUpdates() {
        guard let controller else {
            model.message = "この開発用ビルドには更新先が設定されていません。"; return
        }
        guard !model.busy, !model.importing, !model.mailIndexRunning, !model.styleExtracting,
              model.session.phase != .listening else {
            model.message = "実行中の処理を停止してから更新してください。"; return
        }
        if !model.intent.isEmpty || !model.replyBody.isEmpty {
            let alert = NSAlert()
            alert.messageText = "更新前に文章をコピーしてください"
            alert.informativeText = "更新でアプリを再起動します。必要な文章をコピーしてから、返信をクリアして進んでください。"
            alert.addButton(withTitle: "戻る")
            alert.addButton(withTitle: "返信をクリアして進む")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            model.clearSession()
        }
        nextFetch = .distantPast
        Task { await refreshPolicy() }
        controller.checkForUpdates(nil)
    }

    // Never automatically terminate a process with active work or text to preserve.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        let safe = !model.busy && !model.importing && !model.mailIndexRunning && !model.styleExtracting
            && model.session.phase != .listening && model.intent.isEmpty && model.replyBody.isEmpty
        if !safe { model.message = "更新の準備ができました。処理を止め、文章をコピーして返信をクリアしてから更新してください。" }
        return safe
    }
}
