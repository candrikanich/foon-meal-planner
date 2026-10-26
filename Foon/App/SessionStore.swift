import Foundation
import Observation

@Observable @MainActor
final class SessionStore {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(UUID)
    }

    private(set) var state: State = .restoring
    private(set) var errorMessage: String?
    /// The first name Apple shared at first sign-in, for onboarding to prefill the owner's profile.
    private(set) var appleGivenName: String?

    private let auth: AuthClient
    private var pendingNonce: String?

    init(auth: AuthClient) {
        self.auth = auth
    }

    func start() async {
        for await userID in auth.sessionChanges() {
            state = userID.map(State.signedIn) ?? .signedOut
        }
    }

    /// Starts a Sign in with Apple request; returns the hashed nonce Apple needs.
    func appleRequestNonce() -> String {
        let nonce = AppleSignInNonce.make()
        pendingNonce = nonce
        errorMessage = nil
        return AppleSignInNonce.sha256(nonce)
    }

    func completeAppleSignIn(idToken: String, givenName: String?) async {
        guard let nonce = pendingNonce else {
            errorMessage = Self.signInFailed
            return
        }
        pendingNonce = nil
        do {
            try await auth.signInWithApple(idToken, nonce, givenName)
            if let givenName, !givenName.isEmpty {
                appleGivenName = givenName
            }
        } catch {
            errorMessage = Self.signInFailed
        }
    }

    func appleSignInFailed(cancelled: Bool) {
        pendingNonce = nil
        errorMessage = cancelled ? nil : Self.signInFailed
    }

    func signOut() async {
        errorMessage = nil
        await auth.signOut()
    }

    private static let signInFailed = "Sign in didn't work. Check your connection and try again."
}
