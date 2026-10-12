import SwiftUI

/// Import is an explicit local action reached from the related-mail island.
/// Direction is chosen by the user; the app never guesses sent authorship.
struct RelatedImportView: View {
    @ObservedObject var model: ReplyCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var direction = "unknown"
    @State private var account = ""
    @State private var internalMail = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("履歴を追加").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
            }
            ReplySurface {
                Picker("このファイルの送受信区分", selection: $direction) {
                    Text("不明").tag("unknown")
                    Text("受信").tag("received")
                    Text("送信済み").tag("sent")
                    Text("下書き").tag("draft")
                }
                Text("不明・下書きは、送信済みの発言として扱いません。")
                TextField("アカウント識別名（任意）", text: $account)
                Toggle("社内限定の資料として扱う", isOn: $internalMail)
                Button(".mbox / .eml / フォルダを選ぶ") {
                    model.chooseImport(direction: direction, account: account, internalMail: internalMail)
                }.buttonStyle(.borderedProminent).disabled(model.importing)
                Text("指定した範囲だけをこのMacで索引化します。原本は変更しません。")
                if model.importing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(model.message).textSelection(.enabled)
                        Spacer()
                        Button("停止", action: model.stopImport)
                    }
                } else if model.session.phase == .failed {
                    Text(model.actionNotice.isEmpty ? model.message : model.actionNotice)
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            if !unfinishedSources.isEmpty {
                DisclosureGroup("途中の取り込みを再開") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(unfinishedSources.enumerated()), id: \.offset) { _, source in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(URL(fileURLWithPath: source["path"] as? String ?? "").lastPathComponent)
                                        if source["status"] as? String != "available" {
                                            Text("原本が変更されたか、利用できません。再開前に元のファイルを確認してください。")
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    Button("再開") { model.resume(source["id"] as? String ?? "") }
                                        .disabled(model.importing || source["status"] as? String != "available")
                                }
                            }
                        }.padding(.top, 8)
                    }.frame(maxHeight: 140)
                }
            }
        }.font(.callout).padding(24).frame(width: 520)
            .task { await model.refresh() }
    }
    private var unfinishedSources: [[String: Any]] {
        model.sources.filter { ($0["done"] as? Int ?? 0) == 0 }
    }
}
