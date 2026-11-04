import Foundation

extension AIService {
    /// Previews of a phone that can run the model: it says yes, then every call fails, so the bundled results show.
    static let previewCapable = AIService(availability: { .available },
                                          respond: { _, _, _ in throw CancellationError() })
    /// A phone that can, still tidying: each call takes the whole time limit, so the wait shows.
    static let previewTidying = AIService(availability: { .available }, respond: { _, _, _ in
        try await Task.sleep(for: RecipeStructuring.timeLimit + .seconds(1))
        throw CancellationError()
    })
}
