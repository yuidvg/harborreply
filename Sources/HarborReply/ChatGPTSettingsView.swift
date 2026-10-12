import SwiftUI

struct ChatGPTStatusControl: View {
    @ObservedObject var model: ReplyCoordinator
    @ObservedObject var connection: ChatGPTConnection
    var body: some View {
        Button { model.tab = 2 } label: {
            Group {
                if connection.connecting { ProgressView().controlSize(.small) }
                else {
                    switch connection.connectionState {
                    case .connected:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .permissionNeeded, .expired, .failed:
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    case .signedOut, .connecting:
                        Image(systemName: "person.crop.circle")
                    }
                }
            }.frame(width: 24, height: 24)
        }.buttonStyle(.plain).accessibilityLabel(statusLabel).help(statusLabel)
    }
    private var statusLabel: String {
        if connection.connecting { return "ChatGPTに接続中" }
        switch connection.connectionState {
        case .connected: return "ChatGPT接続済み: \(connection.accountName)"
        case .permissionNeeded: return "ChatGPTプランの利用許可が必要"
        case .expired: return "ChatGPTの再接続が必要"
        case .failed: return "ChatGPTの接続を確認"
        case .signedOut, .connecting: return "ChatGPTの接続設定"
        }
    }
}

/// The connection card has one account, one model and separate disclosure consent.
struct ChatGPTSettingsView: View {
    @ObservedObject var model: ReplyCoordinator
    @ObservedObject var connection: ChatGPTConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ChatGPT").font(.headline)
            connectionAction
            if connection.connectionState == .connected { modelSelection }
            if let issue = connectionIssue {
                Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Toggle("メールの抜粋をChatGPTに送って返信を生成", isOn: disclosureConsent)
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!disclosureConsent.wrappedValue && !canEnableDisclosure)
            Text("選択メール・関連履歴・指示・文体例・登録規程を送ります。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var connectionAction: some View {
        if connection.connecting {
            HStack {
                ProgressView().controlSize(.small)
                Text("接続中")
                Spacer()
                Button("取消") { connection.cancel() }.buttonStyle(.plain)
            }
        } else {
            switch connection.connectionState {
            case .connected:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(connection.accountName).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Button("サインアウト", action: signOut).font(.caption).buttonStyle(.plain)
                }
            case .permissionNeeded:
                HStack {
                    Button("プラン利用を許可する") { model.invalidate(); connection.signIn(consent: true) }
                        .nativeGlassAction(prominent: true)
                    Spacer()
                    Button("サインアウト", action: signOut).font(.caption).buttonStyle(.plain)
                }
            case .signedOut, .expired, .failed, .connecting:
                HStack {
                    Button("Sign in with ChatGPT") { model.invalidate(); connection.signIn() }
                        .buttonStyle(.borderedProminent).tint(.black)
                    Spacer()
                    if connection.connectionState == .expired, !connection.activeID.isEmpty {
                        Button("サインアウト", action: signOut).font(.caption).buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private var modelSelection: some View {
        HStack(spacing: 8) {
            Picker("モデル", selection: selectedModel) {
                Text(connection.models.isEmpty ? "モデル一覧を取得" : "モデルを選択").tag("")
                ForEach(connection.models) { Text($0.name).tag($0.id) }
            }.disabled(connection.connecting || connection.models.isEmpty)
            if needsModelRefresh {
                Button { connection.refreshModels() } label: { Image(systemName: "arrow.clockwise") }
                    .nativeGlassAction().controlSize(.small)
                    .disabled(connection.connecting)
                    .accessibilityLabel("モデル一覧を取得").help("モデル一覧を取得")
            }
        }
    }
    private var selectedModel: Binding<String> {
        Binding(get: {
            let saved = model.settings.chatgptModel ?? ""
            return connection.models.contains(where: { $0.id == saved }) ? saved : ""
        }, set: { value in
            guard value.isEmpty || connection.models.contains(where: { $0.id == value }) else { return }
            if !model.settings.usesChatGPT || value.isEmpty { model.settings.cloudEnabled = false }
            model.settings.useChatGPT = true
            model.settings.chatgptModel = value.isEmpty ? nil : value
            model.saveSettings(key: "")
        })
    }
    private var disclosureConsent: Binding<Bool> {
        Binding(get: { model.settings.usesChatGPT && model.settings.cloudEnabled }, set: { enabled in
            guard !enabled || canEnableDisclosure else { return }
            if enabled { model.settings.useChatGPT = true }
            model.settings.cloudEnabled = enabled
            model.saveSettings(key: "")
        })
    }
    private var canEnableDisclosure: Bool {
        connection.connectionState == .connected && !connection.connecting &&
        connection.models.contains(where: { $0.id == (model.settings.chatgptModel ?? "") && !$0.id.isEmpty })
    }
    private var needsModelRefresh: Bool {
        connection.models.isEmpty || (!(model.settings.chatgptModel ?? "").isEmpty &&
                                     !connection.models.contains(where: { $0.id == (model.settings.chatgptModel ?? "") }))
    }
    private var connectionIssue: String? {
        switch connection.connectionState {
        case .permissionNeeded: return "プラン利用の許可が必要です。"
        case .expired: return "もう一度サインインしてください。"
        case .failed: return connection.status
        case .signedOut:
            return connection.status.hasPrefix("このMacからサインアウト") ? "このMacからサインアウトしました。サーバー側の解除は未確認です。" : nil
        case .connected:
            return connection.models.isEmpty && !connection.connecting && connection.status != "ChatGPTにサインイン済みです。" ? connection.status : nil
        case .connecting: return nil
        }
    }
    private func signOut() {
        model.settings.cloudEnabled = false
        model.saveSettings(key: "")
        connection.signOut()
    }
}
