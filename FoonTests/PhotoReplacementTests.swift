import Foundation
import Testing
@testable import Foon

struct PhotoReplacementTests {
    private static let household = UUID()
    private static let old = "\(household.uuidString.lowercased())/meals/old.jpg"
    private static let new = "\(household.uuidString.lowercased())/meals/new.jpg"

    @Test func replacingDeletesTheOldPhotoOnceTheMealPointsAtTheNewOne() async throws {
        let log = StorageLog()
        try await Self.storage(log).replace(householdID: Self.household, preparedJPEG: Data()) { path in
            await log.record("point \(path)")
            return Self.old
        }
        #expect(await log.events == ["upload", "point \(Self.new)", "remove \(Self.old)"])
    }

    @Test func aFirstPhotoDeletesNothing() async throws {
        let log = StorageLog()
        try await Self.storage(log).replace(householdID: Self.household, preparedJPEG: Data()) { _ in nil }
        #expect(await log.events == ["upload"])
    }

    @Test func aRefusedChangeKeepsTheOldPhotoAndTakesTheUploadBack() async {
        let log = StorageLog()
        await #expect(throws: LibraryClientError.notAllowed) {
            try await Self.storage(log).replace(householdID: Self.household, preparedJPEG: Data()) { _ in
                throw LibraryClientError.notAllowed
            }
        }
        #expect(await log.events == ["upload", "remove \(Self.new)"])
    }

    @Test func aLostReplyDeletesNeitherPhoto() async {
        let log = StorageLog()
        await #expect(throws: URLError.self) {
            try await Self.storage(log).replace(householdID: Self.household, preparedJPEG: Data()) { _ in
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(await log.events == ["upload"])
    }

    @Test func anOldPhotoThatWontDeleteDoesntFailTheReplacement() async throws {
        let log = StorageLog()
        var storage = Self.storage(log)
        storage.remove = { _ in throw URLError(.notConnectedToInternet) }
        try await storage.replace(householdID: Self.household, preparedJPEG: Data()) { _ in Self.old }
        #expect(await log.events == ["upload"])
    }

    private static func storage(_ log: StorageLog) -> PhotoStorageClient {
        PhotoStorageClient(
            upload: { _, _ in
                await log.record("upload")
                return new
            },
            signedURL: { _ in throw URLError(.badURL) },
            remove: { path in await log.record("remove \(path)") }
        )
    }
}

private actor StorageLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}
