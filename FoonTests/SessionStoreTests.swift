import Foundation
import Testing
@testable import Foon

@MainActor
struct SessionStoreTests {
    private let userID = UUID()

    @Test func startsRestoringUntilAuthReportsASession() {
        let store = SessionStore(auth: .fake())
        #expect(store.state == .restoring)
    }

    @Test func followsAuthStateChanges() async {
        let (stream, continuation) = AsyncStream<UUID?>.makeStream()
        let store = SessionStore(auth: .fake(sessionChanges: stream))
        let listening = Task { await store.start() }

        continuation.yield(userID)
        #expect(await store.waitUntil { $0.state == .signedIn(userID) })
        continuation.yield(nil)
        #expect(await store.waitUntil { $0.state == .signedOut })

        continuation.finish()
        await listening.value
    }

    @Test func signsOutWhenARestoredAccountNoLongerExists() async {
        let recorder = Recorder()
        let (stream, continuation) = AsyncStream<UUID?>.makeStream()
        let store = SessionStore(auth: .fake(
            sessionChanges: stream,
            onSignOut: { await recorder.recordSignOut() },
            accountStillExists: { false }
        ))
        let listening = Task { await store.start() }
        continuation.yield(userID)
        continuation.finish()
        await listening.value
        #expect(await recorder.signOuts == 1)
    }

    @Test func keepsAnAccountThatStillExists() async {
        let recorder = Recorder()
        let (stream, continuation) = AsyncStream<UUID?>.makeStream()
        let store = SessionStore(auth: .fake(
            sessionChanges: stream,
            onSignOut: { await recorder.recordSignOut() },
            accountStillExists: { true }
        ))
        let listening = Task { await store.start() }
        continuation.yield(userID)
        continuation.yield(userID)
        continuation.finish()
        await listening.value
        #expect(await recorder.signOuts == 0)
        #expect(store.state == .signedIn(userID))
    }

    @Test func signsInWithTheRawNonceWhileAppleGetsItsHash() async throws {
        let recorder = Recorder()
        let store = SessionStore(auth: .fake(onSignIn: { idToken, nonce, givenName in
            await recorder.record(idToken, nonce, givenName)
        }))

        let hashed = store.appleRequestNonce()
        await store.completeAppleSignIn(idToken: "token", givenName: "Nora")

        let call = try #require(await recorder.calls.first)
        #expect(call.idToken == "token")
        #expect(AppleSignInNonce.sha256(call.nonce) == hashed)
        #expect(call.givenName == "Nora")
        #expect(store.errorMessage == nil)
        #expect(store.appleGivenName == "Nora")
    }

    @Test func aFailedSignInShowsAMessage() async {
        let store = SessionStore(auth: .fake(onSignIn: { _, _, _ in throw URLError(.notConnectedToInternet) }))
        _ = store.appleRequestNonce()
        await store.completeAppleSignIn(idToken: "token", givenName: nil)
        #expect(store.errorMessage != nil)
    }

    @Test func completingWithoutARequestIsAnError() async {
        let recorder = Recorder()
        let store = SessionStore(auth: .fake(onSignIn: { idToken, nonce, givenName in
            await recorder.record(idToken, nonce, givenName)
        }))
        await store.completeAppleSignIn(idToken: "token", givenName: nil)
        #expect(await recorder.calls.isEmpty)
        #expect(store.errorMessage != nil)
    }

    @Test func eachNonceIsUsedOnce() async {
        let recorder = Recorder()
        let store = SessionStore(auth: .fake(onSignIn: { idToken, nonce, givenName in
            await recorder.record(idToken, nonce, givenName)
        }))
        _ = store.appleRequestNonce()
        await store.completeAppleSignIn(idToken: "first", givenName: nil)
        await store.completeAppleSignIn(idToken: "replayed", givenName: nil)
        #expect(await recorder.calls.map(\.idToken) == ["first"])
    }

    @Test func cancellingTheAppleSheetIsNotAnError() {
        let store = SessionStore(auth: .fake())
        _ = store.appleRequestNonce()
        store.appleSignInFailed(cancelled: true)
        #expect(store.errorMessage == nil)
    }

    @Test func signOutClearsAnyMessageAndCallsAuth() async {
        let recorder = Recorder()
        let store = SessionStore(auth: .fake(onSignOut: { await recorder.recordSignOut() }))
        store.appleSignInFailed(cancelled: false)
        await store.signOut()
        #expect(await recorder.signOuts == 1)
        #expect(store.errorMessage == nil)
    }
}

private actor Recorder {
    struct Call { let idToken: String; let nonce: String; let givenName: String? }
    private(set) var calls: [Call] = []
    private(set) var signOuts = 0

    func record(_ idToken: String, _ nonce: String, _ givenName: String?) {
        calls.append(Call(idToken: idToken, nonce: nonce, givenName: givenName))
    }

    func recordSignOut() { signOuts += 1 }
}

private extension AuthClient {
    static func fake(
        sessionChanges: AsyncStream<UUID?> = AsyncStream { _ in },
        onSignIn: @escaping @Sendable (String, String, String?) async throws -> Void = { _, _, _ in },
        onSignOut: @escaping @Sendable () async -> Void = {},
        accountStillExists: @escaping @Sendable () async -> Bool = { true }
    ) -> AuthClient {
        AuthClient(
            sessionChanges: { sessionChanges },
            signInWithApple: onSignIn,
            signOut: onSignOut,
            accountStillExists: accountStillExists
        )
    }
}

private extension SessionStore {
    /// Lets the store's listening task run; returns whether the condition was reached.
    func waitUntil(_ condition: (SessionStore) -> Bool) async -> Bool {
        for _ in 0..<200 where !condition(self) {
            await Task.yield()
        }
        return condition(self)
    }
}
