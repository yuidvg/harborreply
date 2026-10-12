/// Generation requires an explicitly enabled and configured provider.
public enum GenerationRoute: Equatable, Sendable {
    case provider, needsConfiguration
    public static func select(cloudEnabled: Bool, configured: Bool) -> Self {
        cloudEnabled && configured ? .provider : .needsConfiguration
    }
}
