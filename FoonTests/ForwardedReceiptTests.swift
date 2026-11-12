import Foundation
import Supabase
import SwiftData
import Synchronization
import Testing
@testable import Foon

/// What `receipt-inbox?sender=add` answers, and what the app says for each (#237).
struct ReceiptSenderOutcomeTests {
    private func outcome(_ status: Int, _ json: String) -> ReceiptSenderOutcome {
        ReceiptSenderOutcome(status: status, body: Data(json.utf8))
    }

    @Test func readsEveryOutcome() {
        #expect(outcome(200, #"{"outcome":"send","id":"5E1A0000-0000-0000-0000-000000000001"}"#) == .send)
        #expect(outcome(200, #"{"outcome":"confirmed"}"#) == .confirmed)
        #expect(outcome(200, #"{"outcome":"taken"}"#) == .taken)
        #expect(outcome(200, #"{"outcome":"too_many"}"#) == .tooMany)
        #expect(outcome(200, #"{"outcome":"rate_limited"}"#) == .rateLimited)
    }

    @Test func emailOffIsA503AndAnythingElseFailed() {
        #expect(outcome(503, #"{"error":"email_off"}"#) == .emailOff)
        #expect(outcome(400, #"{"error":"bad_address"}"#) == .badAddress)
        #expect(outcome(400, #"{"error":"bad_request"}"#) == .failed)
        #expect(outcome(502, #"{"error":"send_failed"}"#) == .failed)
        #expect(outcome(403, "") == .failed)
        #expect(outcome(500, "") == .failed)
        #expect(outcome(200, #"{"outcome":"something_new"}"#) == .failed)
        #expect(outcome(200, "not json") == .failed)
    }

    @Test func eachOutcomeHasItsMessage() {
        let address = "chris@example.com"
        #expect(ReceiptSenderOutcome.send.message(for: address)
            == "Check chris@example.com for a link from Foon. It works for a day.")
        #expect(ReceiptSenderOutcome.confirmed.message(for: address) == "That address is already set up.")
        #expect(ReceiptSenderOutcome.taken.message(for: address)
            == "Another adult in your family already added that address.")
        #expect(ReceiptSenderOutcome.tooMany.message(for: address)
            == "You can forward from up to 5 addresses. Remove one to add another.")
        #expect(ReceiptSenderOutcome.rateLimited.message(for: address)
            == "Foon already sent that address several links. Check its inbox, including spam.")
        #expect(ReceiptSenderOutcome.badAddress.message(for: address)
            == "That email doesn't look right. Check it and try again.")
        #expect(ReceiptSenderOutcome.emailOff.message(for: address) == "Forwarding isn't available right now.")
        #expect(ReceiptSenderOutcome.failed.message(for: address) == "Couldn't add it. Try again.")
    }

    @Test func onlySentOrAlreadySetUpClearTheField() {
        #expect(ReceiptSenderOutcome.send.isDone)
        #expect(ReceiptSenderOutcome.confirmed.isDone)
        let refusals: [ReceiptSenderOutcome] = [.taken, .tooMany, .rateLimited, .badAddress, .emailOff, .failed]
        #expect(refusals.allSatisfy { !$0.isDone })
    }
}

struct ReceiptSenderAddressTests {
    @Test func acceptsAnEmailAndTrimsIt() {
        #expect(ReceiptSenderAddress.validated("  chris@example.com\n") == "chris@example.com")
        #expect(ReceiptSenderAddress.validated("c.a+receipts@mail.example.co.uk") == "c.a+receipts@mail.example.co.uk")
    }

    @Test func refusesWhatIsNotOne() {
        for typed in ["", "chris", "chris@", "@example.com", "chris@example", "chris@@example.com", "chris@example.",
                      "chris@.com", "chris @example.com", "a@b@example.com",
                      String(repeating: "a", count: 65) + "@example.com"] {
            #expect(ReceiptSenderAddress.validated(typed) == nil, "\(typed)")
        }
    }

    @Test func foonsOwnInboxCannotForwardToFoon() {
        #expect(ReceiptSenderAddress.validated("r-3f9a1c0b7d2e4a68@in.getfoon.com") == nil)
        #expect(ReceiptSenderAddress.validated("R-3F9A@IN.GETFOON.COM") == nil)
    }

    @Test func theHouseholdAddressIsBuiltFromItsToken() {
        #expect(ReceiptInbox.address(token: "3f9a1c0b7d2e4a68") == "r-3f9a1c0b7d2e4a68@in.getfoon.com")
    }
}

struct ForwardedReceiptDecodingTests {
    @Test func decodesAWaitingReceipt() throws {
        let json = """
        [{"id":"F0000000-0000-0000-0000-000000000001","lines":["Bananas 1.23","Milk 3.48"],
          "received_at":"2026-11-10T14:03:22.123456+00:00"}]
        """
        let rows = try PostgrestClient.Configuration.jsonDecoder.decode([ForwardedReceipt].self, from: Data(json.utf8))
        #expect(rows.first?.lines == ["Bananas 1.23", "Milk 3.48"])
        #expect(rows.first?.receivedAt != nil)
    }

    @Test func decodesASenderWaitingAndConfirmed() throws {
        let json = """
        [{"id":"5E1A0000-0000-0000-0000-000000000001","member_id":"0B2C7E7A-6D18-4A51-8E7C-2F6A9B1C3D4E",
          "address_hint":"c•••@gmail.com","confirmed_at":null,"created_at":"2026-11-10T14:03:22+00:00"},
         {"id":"5E1A0000-0000-0000-0000-000000000002","member_id":"0B2C7E7A-6D18-4A51-8E7C-2F6A9B1C3D4E",
          "address_hint":"c•••@work.example","confirmed_at":"2026-11-11T09:00:00.5+00:00",
          "created_at":"2026-11-10T14:03:22+00:00"}]
        """
        let rows = try PostgrestClient.Configuration.jsonDecoder.decode([ReceiptSender].self, from: Data(json.utf8))
        #expect(rows.map(\.addressHint) == ["c•••@gmail.com", "c•••@work.example"])
        #expect(rows.map(\.isConfirmed) == [false, true])
    }
}

/// A forwarded receipt goes through the same review as a photo, and leaves Lists once confirmed or dismissed.
@MainActor
struct ForwardedReceiptReviewTests {
    private let household = UUID()
    private let receipt = ReceiptFixtures.forwarded[0]

    private func store(delete: @escaping @Sendable (UUID) async throws -> Void = { _ in },
                       aliases: [ReceiptAlias] = []) -> ReceiptScanStore {
        ReceiptScanStore(householdID: household, client: .preview(aliases: aliases), itemClient: .preview,
                         source: .forwarded(receipt), forwardedClient: .preview(delete: delete))
    }

    @Test func startsReadingAndGoesStraightToTheReview() async {
        let store = store()
        #expect(store.phase == .reading, "no photo to choose")
        await store.readForwarded(items: ReceiptFixtures.items)
        #expect(store.phase == .review)
        #expect(store.review.itemIDs.contains(ReceiptFixtures.item("Bananas").id))
        #expect(store.review.itemIDs.contains(ReceiptFixtures.item("Milk").id))
    }

    @Test func anEmailWithNoGroceriesSaysSo() async {
        let empty = ForwardedReceipt(id: UUID(), lines: ["Thanks for shopping!", "Total 0.00"], receivedAt: .now)
        let store = ReceiptScanStore(householdID: household, client: .preview(), itemClient: .preview,
                                     source: .forwarded(empty), forwardedClient: .preview())
        await store.readForwarded(items: ReceiptFixtures.items)
        #expect(store.phase == .choosing)
        #expect(store.errorMessage == "Foon couldn't find any groceries in that email.")
    }

    @Test func aPhotoScanIgnoresTheForwardedPath() async {
        let photo = ReceiptScanStore(householdID: household, client: .preview(), itemClient: .preview)
        await photo.readForwarded(items: ReceiptFixtures.items)
        #expect(photo.phase == .choosing)
    }

    @Test func confirmingClearsItFromLists() async throws {
        let deleted = Mutex<[UUID]>([])
        let store = store(delete: { id in deleted.withLock { $0.append(id) } })
        await store.readForwarded(items: ReceiptFixtures.items)
        let reviewed = store.review.itemIDs.count
        let (container, sync, entries, stock) = try await syncedLists()
        await store.confirm(sync: sync, entries: entries, stock: stock)
        withExtendedLifetime(container) {}
        #expect(store.phase == .done)
        #expect(store.boughtCount == reviewed)
        #expect(deleted.withLock { $0 } == [receipt.id])
        #expect(store.clearMessage == nil)
    }

    @Test func confirmingOfflineMarksItBoughtAndKeepsItWaiting() async throws {
        let store = store(delete: { _ in throw URLError(.notConnectedToInternet) })
        await store.readForwarded(items: ReceiptFixtures.items)
        let (container, sync, entries, stock) = try await syncedLists()
        await store.confirm(sync: sync, entries: entries, stock: stock)
        withExtendedLifetime(container) {}
        #expect(store.phase == .done, "the check-offs went through the sync queue")
        #expect(store.clearMessage == "Couldn't clear it from the list. Dismiss it from Lists when you're online.")
    }

    @Test func dismissingDeletesWithoutChangingAnything() async {
        let deleted = Mutex<[UUID]>([])
        let store = store(delete: { id in deleted.withLock { $0.append(id) } })
        await store.readForwarded(items: ReceiptFixtures.items)
        #expect(await store.dismissForwarded())
        #expect(deleted.withLock { $0 } == [receipt.id])
        #expect(store.boughtCount == 0)
        #expect(store.phase == .review)
    }

    @Test func dismissingOfflineKeepsItAndSaysWhy() async {
        let store = store(delete: { _ in throw URLError(.notConnectedToInternet) })
        #expect(await store.dismissForwarded() == false)
        #expect(store.errorMessage == "Dismissing needs a connection. Try again when you're online.")
    }

    /// Bananas and milk both on the quick list, so Confirm has lines to check off. The container must outlive the sync.
    private func syncedLists() async throws -> (ModelContainer, SyncService, [ListEntry], [UUID: ReceiptStock]) {
        let bananas = ReceiptFixtures.item("Bananas").id
        let milk = ReceiptFixtures.item("Milk").id
        let household = household
        let snapshot = SyncSnapshot(
            plan: nil, nights: [],
            listItems: [bananas, milk].map {
                ListItemRow(id: UUID(), householdID: household, itemID: $0, list: .quick, urgency: .whenever,
                            source: .manual, note: nil, checkedAt: nil)
            },
            items: [ItemRow(id: bananas, householdID: household, canonicalName: "Bananas", category: .produce,
                            keepOnHand: false, stockState: nil),
                    ItemRow(id: milk, householdID: household, canonicalName: "Milk", category: .dairyEggs,
                            keepOnHand: false, stockState: nil)]
        )
        let container = try SyncService.inMemoryContainer()
        let sync = SyncService(householdID: household, context: container.mainContext, client: .fake(
            snapshot: { snapshot }, send: { _ in }
        ))
        await sync.pull()
        let lines = try container.mainContext.fetch(FetchDescriptor<CachedListItem>())
        let cached = try container.mainContext.fetch(FetchDescriptor<CachedItem>())
        let stock = Dictionary(uniqueKeysWithValues: cached.map {
            ($0.id, ReceiptStock(keepOnHand: $0.keepOnHand, state: $0.stockState))
        })
        return (container, sync, ListEntry.entries(lines: lines, items: cached), stock)
    }
}

@MainActor
struct ForwardedReceiptsStoreTests {
    @Test func loadsWhatsWaitingAndKeepsItWhenOffline() async {
        let offline = Mutex(false)
        let client = ForwardedReceiptClient(
            waiting: { _ in
                if offline.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
                return ReceiptFixtures.forwarded
            },
            delete: { _ in }, inboxToken: { _ in "" }, resetInbox: { _ in "" }, senders: { _, _ in [] },
            removeSender: { _ in }, addSender: { _, _ in .failed }
        )
        let store = ForwardedReceiptsStore(householdID: UUID(), client: client)
        await store.load()
        #expect(store.receipts == ReceiptFixtures.forwarded)
        offline.withLock { $0 = true }
        await store.load()
        #expect(store.receipts == ReceiptFixtures.forwarded)
    }
}

@MainActor
struct ReceiptForwardingStoreTests {
    @Test func loadsTheAddressAndMySenders() async {
        let client = ForwardedReceiptClient.preview(token: "3f9a1c0b7d2e4a68", senders: ReceiptFixtures.senders)
        let store = ReceiptForwardingStore(householdID: UUID(), memberID: UUID(), client: client)
        await store.load()
        #expect(store.address == "r-3f9a1c0b7d2e4a68@in.getfoon.com")
        #expect(store.senders == ReceiptFixtures.senders)
    }

    @Test func aBadAddressNeverLeavesThePhone() async {
        let sent = Mutex(0)
        var client = ForwardedReceiptClient.preview()
        client.addSender = { _, _ in
            sent.withLock { $0 += 1 }
            return .send
        }
        let store = ReceiptForwardingStore(householdID: UUID(), memberID: UUID(), client: client)
        #expect(await store.add("not an email") == false)
        #expect(sent.withLock { $0 } == 0)
        #expect(store.notice?.isProblem == true)
    }

    @Test func sendingALinkSaysWhereAndClearsTheField() async {
        let store = ReceiptForwardingStore(householdID: UUID(), memberID: UUID(), client: .preview(outcome: .send))
        #expect(await store.add(" chris@example.com "))
        #expect(store.notice == .init(text: "Check chris@example.com for a link from Foon. It works for a day.",
                                      isProblem: false))
    }

    @Test func aRefusalKeepsTheField() async {
        let store = ReceiptForwardingStore(householdID: UUID(), memberID: UUID(), client: .preview(outcome: .taken))
        #expect(await store.add("chris@example.com") == false)
        #expect(store.notice?.isProblem == true)
    }

    @Test func gettingANewAddressReplacesTheOldOne() async {
        let store = ReceiptForwardingStore(householdID: UUID(), memberID: UUID(), client: .preview(token: "aaaa"))
        await store.load()
        await store.resetAddress()
        #expect(store.address == "r-0c1d2e3f4a5b6c7d@in.getfoon.com")
    }

    @Test func removingDropsTheRow() async {
        let store = ReceiptForwardingStore(householdID: UUID(), memberID: UUID(),
                                           client: .preview(senders: ReceiptFixtures.senders))
        await store.load()
        await store.remove(ReceiptFixtures.senders[0])
        #expect(store.senders == [ReceiptFixtures.senders[1]])
    }
}
