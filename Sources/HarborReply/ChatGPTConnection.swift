import AppKit
import Combine
import HarborCore

struct ChatGPTAccount: Codable, Identifiable, Sendable {
    var id: String { clientID }
    let clientID: String, subject: String, email: String, label: String
    var credential: ChatGPTCredential?
}

enum ChatGPTConnectionState: Sendable {
    case signedOut, connecting, connected, expired, permissionNeeded, failed
}

/// One credential record per issued registration. No access to Codex/ChatGPT app credentials.
actor ChatGPTAccounts {
    private var records: [ChatGPTAccount] = []
    private var loaded = false
    private var refreshes: [String: Task<ChatGPTCredential, Error>] = [:]
    private var revision = 0
    private let key = "harborreply-chatgpt-registrations-v1"
    private func load() throws {
        guard !loaded else { return }
        if let data = try KeyStore.getOptional(endpoint: key)?.data(using: .utf8) { records = try JSONDecoder().decode([ChatGPTAccount].self, from: data) }
        loaded = true
    }
    private func save() throws {
        guard let text = String(data: try JSONEncoder().encode(records), encoding: .utf8) else { throw ChatGPTError.storage }
        try KeyStore.set(text, endpoint: key)
    }
    func accounts() throws -> [ChatGPTAccount] { try load(); return records.map { var copy = $0; copy.credential = nil; return copy } }
    func record(_ id: String?) throws -> ChatGPTAccount? { try load(); return records.first { $0.id == id } }
    func connectionState(_ id: String, now: Date = Date()) throws -> ChatGPTConnectionState {
        try load()
        guard let credential = records.first(where: { $0.id == id })?.credential else { return .signedOut }
        guard credential.expires.timeIntervalSince(now) > 60 else { return .expired }
        return credential.permitsPlan ? .connected : .permissionNeeded
    }
    func install(client: String, identity: ChatGPTIdentity, credential: ChatGPTCredential) throws {
        try load()
        if let index = records.firstIndex(where: { $0.clientID == client }) {
            guard records[index].subject == identity.subject else { throw ChatGPTError.identity }
            records[index].credential = credential
        } else {
            records.append(.init(clientID: client, subject: identity.subject, email: identity.email, label: "接続 \(records.count + 1)", credential: credential))
        }
        revision += 1; try save()
    }
    func accessToken(_ id: String) async throws -> String {
        try load()
        guard let index = records.firstIndex(where: { $0.id == id }), let existing = records[index].credential else { throw ChatGPTError.signInRequired }
        guard existing.permitsPlan else { throw ChatGPTError.permission }
        if existing.expires.timeIntervalSinceNow > 60 { return existing.accessToken }
        if let refresh = refreshes[id] {
            let epoch = revision; let credential = try await refresh.value
            guard revision == epoch else { throw ChatGPTError.signInRequired }
            guard credential.permitsPlan else { throw ChatGPTError.permission }
            return credential.accessToken
        }
        guard let refresh = existing.refreshToken else { throw ChatGPTError.signInRequired }
        let expectedSubject = records[index].subject
        let epoch = revision
        let task = Task<ChatGPTCredential, Error> {
            let data = try await ChatGPTHTTP.request(ChatGPTOAuth.issuer + "/api/accounts/oauth/token", fields: ["grant_type": "refresh_token", "client_id": id, "refresh_token": refresh, "resource": ChatGPTOAuth.resource])
            let updated = try ChatGPTCredential.parse(data, previous: existing)
            if updated.idToken != existing.idToken {
                let keys = try await ChatGPTHTTP.request(ChatGPTOAuth.issuer + "/.well-known/jwks.json")
                _ = try ChatGPTIdentityVerifier.verify(updated.idToken, jwks: keys, clientID: id, nonce: nil, expectedSubject: expectedSubject)
            }
            return updated
        }
        refreshes[id] = task
        defer { refreshes[id] = nil }
        do {
            let credential = try await task.value
            guard revision == epoch else { throw ChatGPTError.signInRequired }
            records[index].credential = credential; try save()
            guard credential.permitsPlan else { throw ChatGPTError.permission }
            return credential.accessToken
        } catch {
            if (error as? ChatGPTError) == .signInRequired, revision == epoch { records[index].credential = nil; try save() }
            throw error
        }
    }
    func signOut(_ id: String) async throws -> Bool {
        try load(); revision += 1; refreshes[id]?.cancel(); refreshes[id] = nil
        guard let index = records.firstIndex(where: { $0.id == id }) else { return true }
        let token = records[index].credential?.refreshToken
        // Clear local tokens even when revocation is unavailable; never silently reuse them.
        records[index].credential = nil; try save()
        guard let token else { return true }
        do {
            let discovery = try await ChatGPTHTTP.request(ChatGPTOAuth.issuer + "/.well-known/openid-configuration")
            guard let root = try JSONSerialization.jsonObject(with: discovery) as? [String: Any], root["issuer"] as? String == ChatGPTOAuth.issuer,
                  let endpoint = root["revocation_endpoint"] as? String, endpoint == ChatGPTOAuth.issuer + "/api/accounts/oauth/revoke" else { return false }
            for attempt in 0...1 {
                do { _ = try await ChatGPTHTTP.request(endpoint, fields: ["token": token, "token_type_hint": "refresh_token", "client_id": id]); return true }
                catch { if attempt == 0 { try await Task.sleep(nanoseconds: 1_000_000_000) } }
            }
        } catch { }
        return false
    }
}

@MainActor final class ChatGPTConnection: ObservableObject {
    @Published var accounts: [ChatGPTAccount] = []
    @Published var activeID: String
    @Published var models: [ChatGPTModel] = []
    @Published var status = "ChatGPTに接続していません。"
    @Published var connecting = false
    @Published var showWelcome = false
    @Published var connectionState: ChatGPTConnectionState = .signedOut
    var accountName: String { accounts.first { $0.id == activeID }?.email ?? "ChatGPT" }
    var isSignedIn: Bool { connectionState == .connected || connectionState == .permissionNeeded }
    let store: ChatGPTAccounts
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var pendingClientID: String?
    private var authenticatedState: ChatGPTConnectionState = .signedOut
    private var selectionID = UUID()
    init(store: ChatGPTAccounts = ChatGPTAccounts(), activeID: String? = nil) {
        self.store = store
        self.activeID = activeID ?? UserDefaults.standard.string(forKey: "chatgptActiveClient") ?? ""
    }
    func restore() async {
        let selected = activeID; let selection = selectionID; let operation = operationID
        do {
            let restoredAccounts = try await store.accounts()
            let state = try await store.connectionState(selected)
            guard selected == activeID, selection == selectionID, operation == operationID, !connecting else { return }
            accounts = restoredAccounts; authenticatedState = state; connectionState = state
            switch state {
            case .connected: status = "ChatGPTにサインイン済みです。"
            case .expired: status = "接続の期限が切れています。設定からもう一度サインインしてください。"
            case .permissionNeeded: status = ChatGPTError.permission.userMessage
            default: status = "ChatGPTに接続していません。"
            }
        } catch { if selected == activeID, selection == selectionID, operation == operationID { status = ChatGPTError.storage.userMessage; connectionState = .failed } }
    }
    /// Uses the account store's local expiry/scope only; no refresh request or network.
    func recheckLocalState(now: Date = Date()) async {
        guard !connecting else { return }
        let selected = activeID; let selection = selectionID; let operation = operationID
        do {
            let state = try await store.connectionState(selected, now: now)
            guard selected == activeID, selection == selectionID, operation == operationID, !connecting,
                  state != authenticatedState, state != .connected else { return }
            authenticatedState = state; connectionState = state
            if state == .expired { status = "接続の期限が切れています。設定からもう一度サインインしてください。" }
            else if state == .permissionNeeded { status = ChatGPTError.permission.userMessage }
            else if state == .signedOut { status = "ChatGPTに接続していません。" }
        } catch {
            if selected == activeID, selection == selectionID, operation == operationID, !connecting {
                status = ChatGPTError.storage.userMessage; connectionState = .failed
            }
        }
    }
    func cancel() { operationID = UUID(); operation?.cancel(); operation = nil; connecting = false; connectionState = authenticatedState }
    func select(_ id: String) {
        cancel(); selectionID = UUID(); authenticatedState = .signedOut; connectionState = .signedOut
        pendingClientID = nil; activeID = id; models = []; status = "選択した接続を確認中"
        UserDefaults.standard.set(id, forKey: "chatgptActiveClient")
        Task { await restore() }
    }
    func signIn(newAccount: Bool = false, consent: Bool = false) {
        cancel(); connecting = true; connectionState = .connecting; status = "ブラウザでChatGPTへの接続を許可してください。"
        Diagnostics.record(.signInStarted)
        if newAccount { pendingClientID = nil }
        let operationID = self.operationID; let selected = newAccount ? nil : activeID
        operation = Task {
            let listener = ChatGPTLoopback(); defer { listener.cancel(); if self.operationID == operationID { connecting = false; if connectionState == .connecting { connectionState = authenticatedState } } }
            do {
                let prior = try await store.record(selected)
                let redirect = try await listener.start()
                let attempt = try ChatGPTAttempt(redirect: redirect, clientID: prior?.clientID ?? pendingClientID, subject: prior?.subject)
                var host = UserDefaults.standard.string(forKey: "chatgptHostID")
                if host == nil { host = "urn:uuid:" + UUID().uuidString.lowercased(); UserDefaults.standard.set(host, forKey: "chatgptHostID") }
                guard !Task.isCancelled, NSWorkspace.shared.open(attempt.authorize(hostID: host!, idTokenHint: prior?.credential?.idToken, requestConsent: consent)) else { throw ChatGPTError.cancelled }
                let callback = try await listener.wait()
                let fields = try attempt.exchangeFields(callback: callback)
                if prior == nil { pendingClientID = fields["client_id"] }
                let data = try await ChatGPTHTTP.request(ChatGPTOAuth.issuer + "/api/accounts/oauth/token", fields: fields)
                let credential = try ChatGPTCredential.parse(data)
                let keys = try await ChatGPTHTTP.request(ChatGPTOAuth.issuer + "/.well-known/jwks.json")
                let client = fields["client_id"]!
                let identity = try ChatGPTIdentityVerifier.verify(credential.idToken, jwks: keys, clientID: client, nonce: attempt.nonce, expectedSubject: attempt.subject)
                guard !Task.isCancelled, self.operationID == operationID else { return }
                try await store.install(client: client, identity: identity, credential: credential)
                guard !Task.isCancelled, self.operationID == operationID else { return }
                pendingClientID = nil
                activeID = client; UserDefaults.standard.set(client, forKey: "chatgptActiveClient")
                accounts = try await store.accounts(); models = []
                authenticatedState = credential.permitsPlan ? .connected : .permissionNeeded
                connectionState = authenticatedState
                Diagnostics.record(.signInCompleted, count: credential.permitsPlan ? 1 : 0)
                if credential.permitsPlan {
                    let welcomeKey = "chatgptWelcome." + client
                    if !UserDefaults.standard.bool(forKey: welcomeKey) { showWelcome = true; UserDefaults.standard.set(true, forKey: welcomeKey) }
                    status = "ChatGPTプランを使用します。モデルを選択してください。"
                    try await fetchModels(for: client)
                } else { status = ChatGPTError.permission.userMessage }
            } catch { if self.operationID == operationID { recordFailure(error); Diagnostics.record(.signInFailed, failure: .provider) } }
        }
    }
    func refreshModels() {
        cancel(); let id = activeID; let operationID = self.operationID; connecting = true
        operation = Task {
            defer { if self.operationID == operationID { connecting = false } }
            do { try await fetchModels(for: id) } catch { if self.operationID == operationID { recordFailure(error) } }
        }
    }
    private func fetchModels(for id: String) async throws {
        let token = try await store.accessToken(id)
        guard !Task.isCancelled, activeID == id else { return }
        authenticatedState = .connected; connectionState = .connected
        let result = try await ChatGPTHTTP.request(ChatGPTOAuth.resource + "/models", bearer: token)
        guard !Task.isCancelled, activeID == id else { return }
        models = try ChatGPTHTTP.models(result)
        Diagnostics.record(.modelsListed, count: models.count)
        status = models.isEmpty ? "利用できるモデルが見つかりませんでした。" : "モデル一覧を取得しました。生成が完了するまでは接続確認のみです。"
    }
    func provider(model: String, accountID: String? = nil) async throws -> ChatGPTProvider {
        let id = accountID ?? activeID
        guard activeID == id else { throw ChatGPTError.cancelled }
        do {
            let token = try await store.accessToken(id)
            try Task.checkCancellation(); guard activeID == id else { throw ChatGPTError.cancelled }
            authenticatedState = .connected; connectionState = .connected
            return ChatGPTProvider(accessToken: token, model: model)
        } catch { if activeID == id { recordFailure(error) }; throw error }
    }
    func signOut() {
        cancel(); selectionID = UUID(); let id = activeID; models = []; status = "サインアウト中"; connecting = true
        authenticatedState = .signedOut; connectionState = .signedOut
        let operationID = self.operationID
        operation = Task {
            defer { if self.operationID == operationID { connecting = false } }
            do {
                let revoked = try await store.signOut(id)
                guard self.operationID == operationID else { return }
                accounts = try await store.accounts()
                Diagnostics.record(.signedOut, count: revoked ? 1 : 0)
                status = revoked ? "サインアウトしました。" : "このMacからサインアウトしました。サーバー側の解除は確認できません。「利用状況を管理」から接続を解除してください。"
            } catch { if self.operationID == operationID { status = ChatGPTError.storage.userMessage; connectionState = .failed } }
        }
    }
    private func recordFailure(_ error: Error) {
        status = Self.safe(error)
        switch error as? ChatGPTError {
        case .signInRequired: authenticatedState = .expired; connectionState = .expired
        case .permission: authenticatedState = .permissionNeeded; connectionState = .permissionNeeded
        default: connectionState = authenticatedState == .signedOut ? .failed : authenticatedState
        }
    }
    func recordGenerationFailure(_ error: Error) { recordFailure(error) }
    static func safe(_ error: Error) -> String { (error as? ChatGPTError)?.userMessage ?? (error is CancellationError ? ChatGPTError.cancelled.userMessage : ChatGPTError.unavailable.userMessage) }
}
