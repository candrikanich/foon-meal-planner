import Foundation

extension AuthClient {
    /// Reports one session state once `SessionStore.start()` runs; sign-in and sign-out do nothing.
    static func preview(signedIn userID: UUID? = nil) -> AuthClient {
        AuthClient(
            sessionChanges: { AsyncStream { $0.yield(userID) } },
            signInWithApple: { _, _, _ in },
            signOut: {},
            accountStillExists: { true }
        )
    }
}
