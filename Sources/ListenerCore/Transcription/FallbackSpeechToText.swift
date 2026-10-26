/// Opens streams from `primary`, or from `fallback` whenever `primary` cannot open one,
/// for example while its model is still downloading.
public struct FallbackSpeechToText: SpeechToTextProvider {
    public let primary: any SpeechToTextProvider
    public let fallback: any SpeechToTextProvider
    /// Hears why `primary` was passed over.
    public let onFallback: @Sendable (any Error) -> Void

    public init(
        primary: any SpeechToTextProvider, fallback: any SpeechToTextProvider,
        onFallback: @escaping @Sendable (any Error) -> Void = { _ in }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.onFallback = onFallback
    }

    public var displayName: String { "\(primary.displayName), else \(fallback.displayName)" }

    public func openStream(for speaker: Speaker) async throws -> any SpeechStream {
        do {
            return try await primary.openStream(for: speaker)
        } catch {
            onFallback(error)
            return try await fallback.openStream(for: speaker)
        }
    }
}
