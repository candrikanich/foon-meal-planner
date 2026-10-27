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
    /// An invite code from a `foon://invite/…` link, kept until the person signs in and joins.
    private(set) var pendingInviteCode: String?

    private let auth: AuthClient
    private var pendingNonce: String?

    init(auth: AuthClient) {
        self.auth = auth
    }

    func start() async {
        var verified: UUID?
        for await userID in auth.sessionChanges() {
            state = userID.map(State.signedIn) ?? .signedOut
            // A stored session can outlive its account (deleted elsewhere, revoked); check once per user.
            if let userID, userID != verified {
                verified = userID
                if await !auth.accountStillExists() {
                    await auth.signOut()
                }
            }
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

    func open(_ url: URL) {
        if let code = InviteCode.code(from: url) {
            pendingInviteCode = code
        }
    }

    func clearPendingInvite() {
        pendingInviteCode = nil
    }

    func appleSignInFailed(cancelled: Bool) {
        pendingNonce = nil
        errorMessage = cancelled ? nil : Self.signInFailed
    }

    func signOut() async {
        errorMessage = nil
        pendingInviteCode = nil
        await auth.signOut()
    }

    /// Returns whether every device was signed out.
    func signOutEverywhere() async -> Bool {
        errorMessage = nil
        pendingInviteCode = nil
        guard await auth.signOutEverywhere() else {
            errorMessage = String(localized: "Couldn't sign out your other devices. Check your connection and try again.")
            return false
        }
        return true
    }

    private static var signInFailed: String {
        String(localized: "Sign in didn't work. Check your connection and try again.")
    }
}
