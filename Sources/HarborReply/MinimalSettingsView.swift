import SwiftUI

struct MinimalSettingsView: View {
    @ObservedObject var model: ReplyCoordinator
    @State private var importExpanded = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReplySurface {
                    ChatGPTSettingsView(model: model, connection: model.chatGPT)
                    if !model.settingsNotice.isEmpty {
                        Text(model.settingsNotice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                ReplySurface {
                    Label("メール索引", systemImage: "externaldrive").font(.headline)
                    Text("関連メールを探すための、このMac内の検索データです。原本は変更しません。")
                        .font(.callout)
                    if let status = model.mailIndexStatus {
                        Text("本文を収録：\(status.counts.captured.formatted())通").font(.callout)
                        if let metrics = status.metrics {
                            Text("確認 \(metrics.visited.formatted())通 · 変更なし \(metrics.unchanged.formatted())通 · 本文取得 \(metrics.body_reads.formatted())通").font(.callout)
                        }
                        if status.counts.unreadable + status.counts.tooLarge > 0 {
                            Text("未収録：\((status.counts.unreadable + status.counts.tooLarge).formatted())通").font(.callout)
                        }
                    }
                    HStack {
                        if model.mailIndexRunning {
                            ProgressView().controlSize(.small)
                            Button("停止", action: model.stopMailIndex)
                        } else {
                            Button(model.mailIndexStatus == nil ? "索引を作成" : "索引を更新") { model.startMailIndex() }
                                .disabled(model.busy || model.importing || model.styleExtracting)
                        }
                        Button("ファイルから追加") { importExpanded = true }
                            .disabled(model.busy || model.importing || model.mailIndexRunning)
                    }
                    if !model.mailIndexNotice.isEmpty { Text(model.mailIndexNotice).font(.callout).textSelection(.enabled) }
                    if model.importing {
                        Text(model.message).font(.callout)
                        Button("取り込みを停止", action: model.stopImport)
                    }
                }
                ReplySurface {
                    Label("Mail", systemImage: "envelope").font(.headline)
                    Toggle("パネルを開いたら選択メールを読む", isOn: Binding(
                        get: { model.settings.capturesMailAutomatically },
                        set: { model.setAutoCaptureMail($0) }
                    )).toggleStyle(.switch).controlSize(.small)
                    if !model.mailWriteNotice.isEmpty {
                        Text(model.mailWriteNotice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }.padding(24)
        }.task { await model.chatGPT.restore(); await model.loadMailIndexStatus() }
        .sheet(isPresented: $importExpanded) { RelatedImportView(model: model) }
    }
}
