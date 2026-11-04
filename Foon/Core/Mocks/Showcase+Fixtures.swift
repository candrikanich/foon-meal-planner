import Foundation

extension AIService {
    /// Previews of a phone that can run the model: it says yes, then every call fails, so the bundled results show.
    static let previewCapable = AIService(availability: { .available },
                                          respond: { _, _, _ in throw CancellationError() })
}
