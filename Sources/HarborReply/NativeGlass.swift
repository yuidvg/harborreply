import SwiftUI

/// Uses native Liquid Glass only for the supporting cards and their controls.
/// Reading and writing surfaces keep an opaque background for legibility.
struct ContextGlassContainer<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

private struct NativeGlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
        }
    }
}

private struct NativeGlassAction: ViewModifier {
    let prominent: Bool
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass).foregroundStyle(colorScheme == .dark ? Color.white : Color.black) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

/// Standard native button styles keep keyboard and accessibility behavior.
struct NativeGenerateButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        if #available(macOS 26.0, *) {
            Button(title, systemImage: "sparkles", action: action)
                .buttonStyle(.glassProminent).controlSize(.large).buttonBorderShape(.capsule)
        } else {
            Button(title, systemImage: "sparkles", action: action)
                .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
        }
    }
}

/// Native Button semantics with a large hit area. Hover and press only change
/// the border, so reduced motion never requires an animated transition.
struct IslandButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(isEnabled && (hovering || configuration.isPressed) ? Color.accentColor : Color.clear, lineWidth: 2))
            .onHover { hovering = $0 }
    }
}

/// A static river between cards. It draws only when normal SwiftUI layout or
/// state changes require it: no timer, timeline, particles, or looping GPU work.
struct ReplyFlowConnector: View {
    var branches = false
    var columnSpacing: CGFloat = 12
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ReplyFlowPath(branches: branches, columnSpacing: columnSpacing)
            .stroke(Color.accentColor.opacity(reduceTransparency ? 1 : 0.44),
                    style: StrokeStyle(lineWidth: 8, lineCap: .butt, lineJoin: .round))
            .frame(maxWidth: .infinity).allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ReplyFlowPath: Shape {
    let branches: Bool
    let columnSpacing: CGFloat
    func path(in rect: CGRect) -> Path {
        let center = rect.midX
        var path = Path()
        if branches {
            // Align each inlet to its card's center. One level crossbar merges
            // them into a single trunk; only the two corners are rounded.
            let inset = max(0, (rect.width - columnSpacing) / 4)
            let left = rect.minX + inset, right = rect.maxX - inset
            let junction = rect.midY
            let radius = min(8, rect.height / 4, (right - left) / 4)
            path.move(to: CGPoint(x: left, y: rect.minY))
            path.addLine(to: CGPoint(x: left, y: junction - radius))
            path.addQuadCurve(to: CGPoint(x: left + radius, y: junction),
                              control: CGPoint(x: left, y: junction))
            path.addLine(to: CGPoint(x: right - radius, y: junction))
            path.addQuadCurve(to: CGPoint(x: right, y: junction - radius),
                              control: CGPoint(x: right, y: junction))
            path.addLine(to: CGPoint(x: right, y: rect.minY))
            path.move(to: CGPoint(x: center, y: junction))
            path.addLine(to: CGPoint(x: center, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: center, y: rect.minY))
            path.addLine(to: CGPoint(x: center, y: rect.maxY))
        }
        return path
    }
}

extension View {
    func contextGlassSurface() -> some View { modifier(NativeGlassSurface()) }
    func nativeGlassAction(prominent: Bool = false) -> some View {
        modifier(NativeGlassAction(prominent: prominent))
    }
}
