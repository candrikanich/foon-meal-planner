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

    /// Deletes the account, confirmed with Apple, then signs this device out (which wipes the offline cache).
    /// Returns whether it was deleted.
    func deleteAccount(authorizationCode: Data?) async -> Bool {
        errorMessage = nil
        guard let authorizationCode, let code = String(data: authorizationCode, encoding: .utf8), !code.isEmpty else {
            errorMessage = Self.message(for: .nothingDeleted)
            return false
        }
        do {
            try await auth.deleteAccount(code)
        } catch {
            errorMessage = Self.message(for: error as? AccountDeletionError ?? .unfinished)
            return false
        }
        pendingInviteCode = nil
        await auth.signOut()
        return true
    }

    /// Sign in with Apple failed (not cancelled) while confirming a deletion.
    func appleConfirmationFailed() {
        errorMessage = Self.message(for: .nothingDeleted)
    }

    private static func message(for error: AccountDeletionError) -> String {
        switch error {
        case .nothingDeleted:
            String(localized: "Couldn't delete your account, and nothing was deleted. Check your connection and try again.")
        case .otherAppleID:
            String(localized: "That's a different Apple ID from the one you use with Foon. Confirm with the Apple ID you signed in with. Nothing was deleted.")
        case .unfinished:
            String(localized: "Deleting your account didn't finish. Confirm with Apple again to finish it.")
        }
    }

    private static var signInFailed: String {
        String(localized: "Sign in didn't work. Check your connection and try again.")
    }
}
