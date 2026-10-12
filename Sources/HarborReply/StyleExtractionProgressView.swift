import SwiftUI
import HarborCore

struct StyleExtractionProgressView: View {
    let progress: StyleTextProgress?
    let fallback: String
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("文体").font(.headline); Spacer(); ProgressView().controlSize(.small) }
            if let progress {
                Text(progress.phase == .discovering ? "1 / 2　送信済みを探しています" :
                     progress.phase == .collecting ? "1 / 2　本文をまとめています" : "2 / 2　LLMで文体を抽出しています")
                Text("\(progress.characters.formatted()) / \(progress.limit.formatted())文字・\(progress.messages)通")
                    .monospacedDigit()
                if progress.phase == .collecting {
                    ProgressView(value: Double(progress.characters), total: Double(progress.limit))
                }
                if progress.unavailable > 0 { Text("本文を取得できなかったメール：\(progress.unavailable)通") }
            } else { Text(fallback.isEmpty ? "差出人を確認しています" : fallback) }
            Button("取消", action: cancel).nativeGlassAction().controlSize(.small)
        }.font(.callout).padding(16).frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .contextGlassSurface()
    }
}
