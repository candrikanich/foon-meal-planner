import Foundation

extension DinnerClient {
    /// No server: nothing logged yet, and every write succeeds.
    static let preview = DinnerClient(
        logs: { _, _ in [] },
        confirm: { _ in UUID() },
        react: { _, _, _ in UUID() },
        correct: { _, _ in }
    )
}
