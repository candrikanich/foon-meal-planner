import Foundation
import Observation

/// Lists → Forward receipts by email (#237), for adults: the household's address, and the addresses this adult
/// forwards from. Adding one emails it a link to confirm; the typed address is sent once and never kept.
@Observable @MainActor
final class ReceiptForwardingStore {
    struct Notice: Equatable {
        let text: String
        let isProblem: Bool
    }

    private(set) var token: String?
    private(set) var senders: [ReceiptSender] = []
    private(set) var notice: Notice?
    private(set) var isWorking = false

    let householdID: UUID
    let memberID: UUID
    private let client: ForwardedReceiptClient

    init(householdID: UUID, memberID: UUID, client: ForwardedReceiptClient) {
        self.householdID = householdID
        self.memberID = memberID
        self.client = client
    }

    var address: String? { token.map(ReceiptInbox.address(token:)) }

    /// On appear and when the app comes back, so a link confirmed in Mail shows here.
    func load() async {
        do {
            async let token = client.inboxToken(householdID)
            async let senders = client.senders(householdID, memberID)
            let (loadedToken, loadedSenders) = try await (token, senders)
            self.token = loadedToken
            self.senders = loadedSenders
            if notice?.isProblem == true { notice = nil }
        } catch {
            notice = Notice(text: String(localized: "Couldn't load your forwarding address. Pull to try again."),
                            isProblem: true)
        }
    }

    /// True when the field can clear: the link went, or the address was already set up.
    func add(_ typed: String) async -> Bool {
        guard let address = ReceiptSenderAddress.validated(typed) else {
            notice = Notice(text: String(localized: "That email doesn't look right. Check it and try again."),
                            isProblem: true)
            return false
        }
        isWorking = true
        defer { isWorking = false }
        let outcome = await client.addSender(householdID, address)
        notice = Notice(text: outcome.message(for: address), isProblem: !outcome.isDone)
        if outcome == .send, let loaded = try? await client.senders(householdID, memberID) { senders = loaded }
        return outcome.isDone
    }

    func remove(_ sender: ReceiptSender) async {
        do {
            try await client.removeSender(sender.id)
            senders.removeAll { $0.id == sender.id }
        } catch {
            notice = Notice(text: String(localized: "Couldn't remove it. Try again."), isProblem: true)
        }
    }

    /// The old address stops working at once.
    func resetAddress() async {
        isWorking = true
        defer { isWorking = false }
        do {
            token = try await client.resetInbox(householdID)
            let text = String(localized: "Your family has a new address. Forward receipts to it from now on.")
            notice = Notice(text: text, isProblem: false)
        } catch {
            notice = Notice(text: String(localized: "Couldn't change the address. Try again."), isProblem: true)
        }
    }
}
