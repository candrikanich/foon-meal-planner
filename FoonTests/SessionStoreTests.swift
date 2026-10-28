import Foundation
import Synchronization
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

    @Test func keepsAnInviteCodeFromAnOpenedLink() throws {
        let store = SessionStore(auth: .fake())
        store.open(try #require(URL(string: "foon://invite/THESM-7KQ4-M9XP")))
        #expect(store.pendingInviteCode == "THESM-7KQ4-M9XP")
        store.open(try #require(URL(string: "foon://somewhere-else")))
        #expect(store.pendingInviteCode == "THESM-7KQ4-M9XP", "unrelated links leave the code alone")
        store.clearPendingInvite()
        #expect(store.pendingInviteCode == nil)
    }

    @Test func cancellingTheAppleSheetIsNotAnError() {
        let store = SessionStore(auth: .fake())
        _ = store.appleRequestNonce()
        store.appleSignInFailed(cancelled: true)
        #expect(store.errorMessage == nil)
    }

    @Test func signsOutEverywhere() async {
        let store = SessionStore(auth: .fake(signOutEverywhere: { true }))
        #expect(await store.signOutEverywhere())
        #expect(store.errorMessage == nil)
    }

    @Test func aFailedSignOutEverywhereSaysSo() async {
        let store = SessionStore(auth: .fake(signOutEverywhere: { false }))
        #expect(!(await store.signOutEverywhere()))
        #expect(store.errorMessage != nil)
    }

    @Test func signOutClearsAnyMessageAndCallsAuth() async {
        let recorder = Recorder()
        let store = SessionStore(auth: .fake(onSignOut: { await recorder.recordSignOut() }))
        store.appleSignInFailed(cancelled: false)
        store.open(URL(string: "foon://invite/THESM-7KQ4-M9XP")!)
        await store.signOut()
        #expect(await recorder.signOuts == 1)
        #expect(store.pendingInviteCode == nil, "signing out forgets a pending invite")
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
        accountStillExists: @escaping @Sendable () async -> Bool = { true },
        signOutEverywhere: @escaping @Sendable () async -> Bool = { true },
        deleteAccount: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) -> AuthClient {
        AuthClient(
            sessionChanges: { sessionChanges },
            signInWithApple: onSignIn,
            signOut: onSignOut,
            accountStillExists: accountStillExists,
            signOutEverywhere: signOutEverywhere,
            deleteAccount: deleteAccount
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

@MainActor
struct AccountDeletionTests {
    @Test func deletingSendsApplesCodeThenSignsOut() async {
        let codes = Mutex<[String]>([])
        let signOuts = Mutex(0)
        let store = SessionStore(auth: .fake(
            onSignOut: { signOuts.withLock { $0 += 1 } },
            deleteAccount: { code in codes.withLock { $0.append(code) } }
        ))
        #expect(await store.deleteAccount(authorizationCode: Data("code-1".utf8)))
        #expect(codes.withLock { $0 } == ["code-1"])
        #expect(signOuts.withLock { $0 } == 1)
        #expect(store.errorMessage == nil)
    }

    @Test func aFailedDeleteKeepsYouSignedIn() async {
        let signOuts = Mutex(0)
        let store = SessionStore(auth: .fake(
            onSignOut: { signOuts.withLock { $0 += 1 } },
            deleteAccount: { _ in throw URLError(.notConnectedToInternet) }
        ))
        #expect(!(await store.deleteAccount(authorizationCode: Data("code-1".utf8))))
        #expect(signOuts.withLock { $0 } == 0)
        #expect(store.errorMessage != nil)
    }

    @Test(arguments: [
        (AccountDeletionError.nothingDeleted, "nothing was deleted"),
        (.otherAppleID, "different Apple ID"),
        (.unfinished, "didn't finish")
    ])
    func eachFailureSaysWhatHappened(error: AccountDeletionError, says: String) async {
        let store = SessionStore(auth: .fake(deleteAccount: { _ in throw error }))
        #expect(!(await store.deleteAccount(authorizationCode: Data("code-1".utf8))))
        #expect(store.errorMessage?.contains(says) == true)
    }

    @Test func serverStatusesMapToWhatHappened() {
        #expect(AccountDeletionError(status: 502) == .nothingDeleted)
        #expect(AccountDeletionError(status: 401) == .nothingDeleted)
        #expect(AccountDeletionError(status: 409) == .otherAppleID)
        #expect(AccountDeletionError(status: 500) == .unfinished)
        #expect(AccountDeletionError(status: nil) == .unfinished, "the server may have finished before we lost it")
    }

    @Test func withoutApplesCodeNothingIsSent() async {
        let store = SessionStore(auth: .fake(deleteAccount: { _ in Issue.record("nothing to send") }))
        #expect(!(await store.deleteAccount(authorizationCode: nil)))
        #expect(store.errorMessage != nil)
    }
}
