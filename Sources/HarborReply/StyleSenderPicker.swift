import SwiftUI
import HarborCore

/// Sender choices for address-scoped Sent extraction.
struct StyleSenderPicker: View {
    let accounts: [MailAccountIdentity]
    let select: (String, String) -> Void
    let cancel: () -> Void
    @State private var listHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自分の差出人を選ぶ").font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("選ぶと、そのアドレスの送信済みを取得して文体を抽出します。共有アドレスは選ばないでください。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(accounts, id: \.id) { account in
                        ForEach(account.addresses, id: \.self) { address in
                            Button { select(account.id, address) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(address).font(.body.weight(.medium))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(account.name).font(.callout)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right").fixedSize()
                                }.padding(12).frame(maxWidth: .infinity, minHeight: 64)
                                    .contextGlassSurface()
                            }.buttonStyle(IslandButtonStyle())
                        }
                    }
                }
                // Native focus rings and the hover border extend beyond the
                // button. Keep them inside the scroll viewport at both ends.
                .padding(8)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SenderListHeight.self, value: geometry.size.height)
                    }
                }
            }.frame(height: listHeight)
                .onPreferenceChange(SenderListHeight.self) { height in
                    // Wrapped addresses can make rows taller. Fit actual
                    // content for small lists, then scroll within a fixed cap.
                    let bounded = min(320, max(96, height))
                    if abs(listHeight - bounded) > 0.5 { listHeight = bounded }
                }
            Button("取消", role: .cancel, action: cancel).nativeGlassAction()
        }.padding(24).frame(width: 460)
    }
}

private struct SenderListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
