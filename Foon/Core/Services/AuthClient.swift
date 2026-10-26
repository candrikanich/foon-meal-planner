import Foundation
import Supabase

/// The auth operations the app needs, as closures so tests and previews can swap them out.
struct AuthClient: Sendable {
    /// Emits the signed-in user's id, or nil when signed out, starting with the stored session.
    var sessionChanges: @Sendable () -> AsyncStream<UUID?>
    var signInWithApple: @Sendable (_ idToken: String, _ rawNonce: String, _ givenName: String?) async throws -> Void
    /// Signs out this device only; signing out everywhere is a separate action (#14).
    var signOut: @Sendable () async -> Void
    /// False only when the server says the account or session is gone (deleted account, revoked
    /// session). Network trouble counts as still signed in, so offline use keeps working.
    var accountStillExists: @Sendable () async -> Bool
    /// Ends every session for this account, this device included. Other devices lose household
    /// access at once (RLS checks the session). False if the server couldn't be reached.
    var signOutEverywhere: @Sendable () async -> Bool
}

extension AuthClient {
    /// supabase-swift keeps the session in the Keychain and refreshes it, so it survives relaunches.
    static func live(_ client: SupabaseClient) -> AuthClient {
        AuthClient(
            sessionChanges: {
                AsyncStream { continuation in
                    let task = Task {
                        for await change in client.auth.authStateChanges {
                            continuation.yield(change.session?.user.id)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            signInWithApple: { idToken, rawNonce, givenName in
                try await client.auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: rawNonce)
                )
                // Apple shares the name only on the first sign-in. Keep the first name alone (minimal data);
                // onboarding uses it to prefill the owner's profile. Best-effort: the user is already signed
                // in, and SessionStore keeps the name in memory if this save fails.
                if let givenName = givenName?.trimmingCharacters(in: .whitespaces), !givenName.isEmpty {
                    _ = try? await client.auth.update(user: UserAttributes(data: ["given_name": .string(givenName)]))
                }
            },
            signOut: {
                // The SDK clears the local session before calling the server, so a network failure
                // afterwards still leaves this device signed out. Nothing for the user to retry.
                try? await client.auth.signOut(scope: .local)
            },
            accountStillExists: {
                do {
                    _ = try await client.auth.user()
                    return true
                } catch let AuthError.api(_, errorCode, _, _)
                    where errorCode == .userNotFound || errorCode == .sessionNotFound {
                    return false
                } catch AuthError.sessionMissing {
                    // The SDK maps a revoked session (session_not_found) to this after clearing it locally.
                    return false
                } catch {
                    return true
                }
            },
            signOutEverywhere: {
                // The SDK clears this device before it calls the server, so check the server is
                // reachable first; otherwise other devices could stay signed in while this one looks done.
                do {
                    _ = try await client.auth.user()
                    try await client.auth.signOut(scope: .global)
                    return true
                } catch {
                    return false
                }
            }
        )
    }
}
