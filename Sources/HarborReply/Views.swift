import SwiftUI
import HarborCore

struct MainView: View {
    @ObservedObject var model: ReplyCoordinator
    @ObservedObject private var connection: ChatGPTConnection
    init(model: ReplyCoordinator) {
        self.model = model
        _connection = ObservedObject(wrappedValue: model.chatGPT)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if model.tab != 0 {
                    Button { model.tab = 0 } label: { Label("返信へ", systemImage: "chevron.left") }
                        .nativeGlassAction()
                }
                Text(model.tab == 0 ? "HarborReply" : "設定").font(.headline)
                Spacer()
                ChatGPTStatusControl(model: model, connection: model.chatGPT)
                Button { model.tab = model.tab == 0 ? 2 : 0 } label: {
                    Image(systemName: model.tab == 0 ? "gearshape" : "xmark").frame(width: 20, height: 20)
                }.nativeGlassAction().accessibilityLabel(model.tab == 0 ? "設定を開く" : "設定を閉じる")
            }.padding(.horizontal, 24).padding(.vertical, 16)
            if let restriction = model.updateRestriction {
                Text(restriction).font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Group {
                if model.tab == 0 { ReplyView(model: model) }
                else { MinimalSettingsView(model: model) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 720, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await model.loadReplyOverview()
            await model.chatGPT.restore()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await model.chatGPT.recheckLocalState()
            }
        }
        .onChange(of: connection.activeID) { _, _ in
            model.invalidate(); model.settings.chatgptModel = nil; model.settings.cloudEnabled = false
            model.saveSettings(key: "")
        }
        .onChange(of: model.settings.endpoint) { _, _ in model.invalidate() }
        .onChange(of: model.settings.model) { _, _ in model.invalidate() }
        .onChange(of: model.settings.chatgptModel) { _, _ in model.invalidate() }
        .onChange(of: model.settings.cloudEnabled) { _, _ in model.invalidate() }
        .onChange(of: model.settings.style) { _, _ in model.invalidate() }
        .onChange(of: model.settings.useChatGPT) { _, _ in model.invalidate() }
    }
}

struct ReplyView: View {
    @ObservedObject var model: ReplyCoordinator
    @State private var relatedExpanded = false
    @State private var styleExpanded = false
    @State private var importExpanded = false
    @State private var reviewingMessageID: String?
    @State private var query = ""
    @State private var newCaseLabel = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ContextGlassContainer {
                    HStack(alignment: .top, spacing: 12) {
                        styleCard
                        relatedCard
                    }
                }
                ReplyFlowConnector(branches: true).frame(height: 42)
                currentMailCard
                ReplyFlowConnector().frame(height: 26)
                adjustmentCard
                ReplyFlowConnector().frame(height: 22)
                NativeGenerateButton(title: model.busy ? phaseLabel : "生成する", action: model.generate)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || model.styleExtracting || model.session.target == nil || model.session.phase == .listening || model.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ReplyFlowConnector().frame(height: 22)
                replyCard
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
        }
        .sheet(isPresented: $importExpanded) { RelatedImportView(model: model) }
        .sheet(isPresented: $model.choosingStyleAddress) {
            StyleSenderPicker(accounts: model.styleAccounts,
                              select: { model.selectStyleAddress(accountID: $0, address: $1) },
                              cancel: { model.choosingStyleAddress = false })
        }
    }
    @ViewBuilder private var styleCard: some View {
        if model.styleExtracting {
            StyleExtractionProgressView(progress: model.styleProgress, fallback: model.styleMessage,
                                        cancel: model.stopStyleExtraction)
        } else if styleReady, let summary = model.styleSummary {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("文体").font(.headline)
                    Spacer()
                    Button("再抽出") { model.beginStyleExtraction() }.nativeGlassAction().controlSize(.small).disabled(model.busy || model.importing)
                }
                if let address = summary.sourceAddress {
                    Text(address).font(.callout).lineLimit(1)
                }
                Text(summary.explanation).font(.callout).lineLimit(2)
                if let info = summary.sampleInfo {
                    Text("\(info.selectedMessages)通から抽出").font(.callout)
                }
                if let phrase = summary.sourcePhrases.first {
                    Text(phrase).font(.callout).lineLimit(1)
                    Text("送信例の表現").font(.caption).foregroundStyle(.secondary)
                }
                if !model.styleMessage.isEmpty {
                    Text(model.styleMessage).font(.callout)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Button("確認・微調整") { styleExpanded = true }.buttonStyle(.plain)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                .contextGlassSurface()
                .popover(isPresented: $styleExpanded, arrowEdge: .bottom) { styleDetails }
        } else {
            Button {
                if model.styleCanResume { model.resumeStyleExtraction(restart: model.styleNeedsRestart) }
                else { model.beginStyleExtraction() }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(model.styleCanResume ? (model.styleNeedsRestart ? "最初から再抽出" : "文体抽出を再試行") : "文体を抽出する", systemImage: "text.alignleft").font(.headline)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    Text(model.styleCanResume ? (model.styleNeedsRestart ? "送信済みを新しく確認して取得" : "本文を集め直して抽出") : "差出人を選び、送信済みから抽出").font(.callout)
                    if !model.styleMessage.isEmpty {
                        Text(model.styleMessage).font(.callout)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }.padding(16).frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                    .contextGlassSurface()
            }.buttonStyle(IslandButtonStyle()).disabled(model.styleExtracting || model.busy || model.importing)
                .accessibilityHint("送信済みメールを選び、本人の文体として抽出します")
        }
    }
    private var relatedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("関連メール").font(.headline)
                Spacer()
                if model.relatedLoading { ProgressView().controlSize(.small) }
                Text("\(model.candidates.filter { ($0["source_status"] as? String == "available") && model.relatedIsSelected($0["id"] as? String ?? "") }.count)通を使用").font(.callout)
            }
            Text("索引から見つかったメールです。使わないものはチェックを外してください。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if model.session.target == nil {
                Text("対象メールを選ぶと、関連メールがここに並びます。").font(.callout)
            } else if model.candidates.isEmpty && !model.relatedLoading {
                Text("関連メールが見つかりませんでした。").font(.callout)
            }
            if !model.candidates.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { relatedRows(model.candidates) }
                }.frame(maxHeight: 220)
            }
            if !model.relatedErrorCode.isEmpty {
                Text("関連メールを取得できませんでした。\n\(model.relatedErrorCode)")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.warnings.contains(where: { $0.contains("長い関連メール") }) {
                Text("長い本文は先頭を抜粋して使用します。").font(.caption)
            }
            Button { model.tab = 2 } label: {
                Label("検索元：メール索引", systemImage: "externaldrive")
            }.buttonStyle(.plain).font(.callout)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .contextGlassSurface()
            .popover(isPresented: $relatedExpanded, arrowEdge: .bottom) { relatedDetails }
    }
    private var indexActionTitle: String {
        switch model.mailIndexStatus?.status {
        case "complete": return "索引を更新"
        case "paused", "running": return "索引を再開"
        default: return "全メールを索引化"
        }
    }
    @ViewBuilder private var currentMailCard: some View {
        if let target = model.session.target {
            ReplySurface {
                HStack {
                    Text("対象メール").font(.headline)
                    Spacer()
                    Button(action: model.captureMail) { Image(systemName: "arrow.triangle.2.circlepath") }
                        .nativeGlassAction().controlSize(.small).disabled(model.busy)
                        .accessibilityLabel("対象メールを読み替える").help("Mailで選択したメールに読み替える")
                }
                if !model.mailWriteNotice.isEmpty {
                    Text(model.mailWriteNotice).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text(target.subject).font(.callout.weight(.medium)).textSelection(.enabled)
                Text("\(target.sender) · \(target.account)").font(.callout).textSelection(.enabled)
                ScrollView {
                    Text(target.body).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 78)
                if target.id.count == 64 {
                    Text("書き出し履歴のプレビューです。Mailで選択したメールとしては扱いません。")
                        .font(.callout)
                }
                if model.currentInternal { Text("社内限定として扱います").font(.callout) }
            }
        } else {
            Button { model.busy ? model.cancel() : model.captureMail() } label: {
                ReplySurface {
                    VStack(spacing: 12) {
                        if model.busy { ProgressView() }
                        else { Image(systemName: "envelope").font(.system(size: 28, weight: .regular)) }
                        Text(model.busy ? "対象メールを読み込み中…" : "対象メールを読み込む").font(.headline)
                        if model.busy {
                            Text("クリックで取り消す").font(.callout)
                        } else if !model.captureErrorCode.isEmpty {
                            Text(model.message).font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Mailで選んだ1通を取得します。").font(.callout)
                        }
                        if !model.mailWriteNotice.isEmpty {
                            Text(model.mailWriteNotice).font(.callout).foregroundStyle(.orange)
                        }
                        if !model.busy, model.session.phase == .cancelled {
                            Text(model.message).font(.callout).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 108)
                }
            }.buttonStyle(IslandButtonStyle())
                .accessibilityHint(model.busy ? "読み込みを取り消します" : "Apple Mailで選んだメールを取得します")
                .help(model.captureErrorCode.isEmpty ? "Apple Mailの一覧で対象メールを1通選んでください" : "診断コード: \(model.captureErrorCode)")
                .contextMenu {
                    if !model.captureErrorCode.isEmpty {
                        Button("診断コードをコピー", action: model.copyCaptureDiagnostic)
                    }
                }
        }
    }
    private var adjustmentCard: some View {
        ReplySurface {
            HStack {
                Text("調整").font(.headline)
                Spacer()
                if model.session.phase == .listening {
                    Label("録音中", systemImage: "record.circle.fill").font(.callout).foregroundStyle(.red)
                    Button("停止") { model.voice.stop(); model.voiceNote = "認識結果の確定を待っています。" }
                        .nativeGlassAction().controlSize(.small)
                } else {
                    Button("話して入力", systemImage: "mic", action: model.startVoice)
                        .nativeGlassAction().controlSize(.small).disabled(model.session.target == nil || model.busy)
                }
            }
            ZStack(alignment: .topLeading) {
                if model.intent.isEmpty {
                    Text("返信で伝えたいことを入力").font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false)
                }
                TextEditor(text: $model.intent).font(.callout).scrollContentBackground(.hidden)
                    .frame(height: 62).accessibilityLabel("返信で伝えたいこと")
            }
            if !model.voiceNote.isEmpty { Text(model.voiceNote).font(.callout).foregroundStyle(.orange) }
            HStack(spacing: 12) {
                Picker("返信方法", selection: $model.replyAll) { Text("返信").tag(false); Text("全員に返信").tag(true) }
                Picker("言語", selection: $model.language) { Text("English").tag("English"); Text("日本語").tag("日本語") }
                Picker("語調", selection: $model.tone) { Text("丁寧・明確").tag("丁寧・明確"); Text("丁寧・強め").tag("丁寧・強め") }
            }.font(.callout).disabled(model.session.draft != nil)
        }
    }
    private var replyCard: some View {
        ReplySurface {
            HStack {
                Text("返信").font(.headline)
                Spacer()
                Button("Mailに配置", systemImage: "arrow.up.doc", action: model.placeReply)
                    .nativeGlassAction().controlSize(.small).disabled(!model.canUseReply)
                Button(model.replyCopied ? "コピー済み" : "コピー", systemImage: model.replyCopied ? "checkmark" : "document.on.document", action: model.copyReply)
                    .nativeGlassAction().controlSize(.small).disabled(!model.canUseReply)
                    .help("クリップボード履歴に残る場合があります")
            }
            if model.busy, model.session.target != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.message).font(.callout)
                    Spacer()
                    Button("取消", action: model.cancel).nativeGlassAction()
                }
            }
            if !model.actionNotice.isEmpty {
                Text(model.actionNotice).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            } else if model.session.target != nil, [.failed, .needsResolution, .cancelled].contains(model.session.phase) {
                Text(model.message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !model.errors.isEmpty {
                Label("確認が必要です", systemImage: "exclamationmark.circle").font(.callout.weight(.medium)).foregroundStyle(.red)
                ForEach(model.errors, id: \.self) { Text($0).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            if model.replyNeedsRegeneration {
                Text("変更前の返信です。現在の調整内容で生成し直してください。").font(.callout)
            }
            Text(model.replyBody.isEmpty ? "生成した返信がここに表示されます。" : model.replyBody)
                .font(.callout).frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading).textSelection(.enabled)
            if !model.productionMailInsertionVerified, !model.replyBody.isEmpty, model.actionNotice.isEmpty {
                Text("このMacではMailへの配置確認が未完了です。本文をコピーできます。")
                    .font(.callout)
            }
            if let draft = model.session.draft {
                Text("差出人: \(draft.fields[1])\nTo: \(draft.fields[5])\nCc: \(draft.fields[6])\nBcc: \(draft.fields[7])").font(.callout).textSelection(.enabled)
                Toggle("差出人・To/Cc・返信方法を確認した", isOn: $model.recipientsConfirmed)
            }
            if !model.warnings.isEmpty {
                DisclosureGroup("未確認事項 \(model.warnings.count)件") {
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.callout).textSelection(.enabled).padding(.top, 4)
                    }
                }.font(.callout)
            }
            if !model.replyBody.isEmpty { Text("送信前に本文と宛先を確認してください。").font(.callout) }
        }
    }
    private var styleDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("文体").font(.headline)
                if let summary = model.styleSummary, styleReady {
                    Text(summary.explanation).font(.callout)
                    if !summary.sourcePhrases.isEmpty {
                        Text("送信例の表現").font(.callout.weight(.medium))
                        ForEach(summary.sourcePhrases, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                    }
                }
                if !model.styleMessage.isEmpty { Text(model.styleMessage).font(.callout) }
                Text("送信済みの本文を最大\(model.settings.effectiveStyleCharacterLimit.formatted())文字まで連結し、LLMで文体を抽出します。").font(.callout)
                TextField("文体の微調整", text: $model.settings.style, axis: .vertical).lineLimit(3...6)
                Button("保存") { model.saveSettings(key: "") }
                if !model.settingsNotice.isEmpty {
                    Text(model.settingsNotice).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                Button("Mailから再抽出") { styleExpanded = false; model.beginStyleExtraction() }
                    .disabled(model.busy || model.importing)
            }.padding(20)
        }.frame(width: 420).frame(maxHeight: 520)
    }
    private var relatedDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("メールの内容").font(.headline)
                    Spacer()
                    Button("閉じる") { relatedExpanded = false }
                }
                reviewedSource
            }.padding(20)
        }.frame(width: 520, height: 440)
    }
    private func relatedRows(_ rows: [[String: Any]]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, candidate in
            let id = candidate["id"] as? String ?? ""
            HStack(alignment: .top, spacing: 10) {
                Toggle(isOn: Binding(get: { candidate["source_status"] as? String == "available" && model.relatedIsSelected(id) },
                                     set: { model.setRelatedSelected(id, $0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate["subject"] as? String ?? "件名なし").font(.callout).lineLimit(2)
                        Text(candidate["source_status"] as? String == "available" ? (candidate["date"] as? String ?? "日時不明") : "本文を取得できません").font(.caption)
                    }
                }.toggleStyle(.checkbox).disabled(candidate["source_status"] as? String != "available")
                Spacer(minLength: 0)
                Button("本文") { relatedExpanded = true; inspectRelated(id) }.buttonStyle(.plain)
            }
        }
    }
    @ViewBuilder private var reviewedSource: some View {
        if let id = reviewingMessageID {
            Divider()
            if let original = model.selectedMessage, original["id"] as? String == id {
                Text("本文を確認").font(.callout.weight(.medium))
                Text(original["subject"] as? String ?? "件名なし").font(.callout).textSelection(.enabled)
                Text(original["from"] as? String ?? "差出人不明").font(.callout).textSelection(.enabled)
                Button("このメールから返信") { relatedExpanded = false; model.previewArchived() }
                    .disabled(original["source_status"] as? String != "available")
                Text(original["source_status"] as? String == "available" ?
                     (["apple_mail_readonly_snapshot", "apple_mail_index_snapshot", "mail_store_readonly"].contains(original["origin"] as? String ?? "") ? "Mailから取得した本文の保存済みコピーです。取得後の変更は未確認です。" : "原本との照合済み") :
                     "原本を照合できません。表示は取り込み時点の本文です。この本文は生成には使えません。")
                    .font(.callout).foregroundStyle(original["source_status"] as? String == "available" ? Color.primary : Color.orange)
                Text(original["body_text"] as? String ?? "").font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !(original["attachments"] as? [Any] ?? []).isEmpty {
                    Text("添付ファイルの内容は未解析です。").font(.callout).foregroundStyle(.orange)
                }
            } else {
                Text("本文を確認できていません。読み込みに失敗した場合はもう一度選んでください。").font(.callout)
            }
        }
    }
    private func inspectRelated(_ id: String) {
        guard !id.isEmpty else { return }
        reviewingMessageID = id; model.inspect(id)
    }
    private func reviewedSourceAvailable(_ id: String) -> Bool {
        guard reviewingMessageID == id, let original = model.selectedMessage else { return false }
        return original["id"] as? String == id && original["source_status"] as? String == "available"
    }
    private var caseLabelParts: [String] {
        let parts = newCaseLabel.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.count == 3 && parts.allSatisfy({ !$0.isEmpty }) ? parts : []
    }
    private var relativeEvidence: [[String: Any]] { Array(model.evidence.dropFirst()) }
    private var styleReady: Bool { model.styleSummary?.isExtracted == true }
    private var phaseLabel: String {
        switch model.session.phase {
        case .retrieving: "検索中"
        case .generating: "生成中"
        case .validating: "検査中"
        default: "準備中"
        }
    }
}

struct ReplySurface<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }
}

struct CasePicker: View {
    @ObservedObject var model: ReplyCoordinator
    var body: some View {
        Picker("案件", selection: $model.caseID) {
            Text("未選択 / 現在のメールのみ").tag("")
            ForEach(Array(model.cases.enumerated()), id: \.offset) { _, c in
                Text(c["label"] as? String ?? "").tag(c["id"] as? String ?? "")
            }
        }
    }
}
