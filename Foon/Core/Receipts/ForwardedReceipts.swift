import Foundation
import Supabase

/// A store's receipt email, forwarded to the household's address and read into plain lines by `receipt-inbox` (#237).
/// It waits in Lists until someone reviews it; Confirm or Dismiss deletes it. Nothing about the sender is kept.
struct ForwardedReceipt: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let lines: [String]
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, lines
        case receivedAt = "received_at"
    }

    static let columns = "id, lines, received_at"
}

/// An address an adult forwards receipts from: only a hint ("c•••@gmail.com") reaches the app, never the address.
struct ReceiptSender: Decodable, Identifiable, Equatable, Sendable {
    let id: UUID
    let memberID: UUID
    let addressHint: String
    let confirmedAt: Date?
    let createdAt: Date

    var isConfirmed: Bool { confirmedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id
        case memberID = "member_id"
        case addressHint = "address_hint"
        case confirmedAt = "confirmed_at"
        case createdAt = "created_at"
    }

    static let columns = "id, member_id, address_hint, confirmed_at, created_at"
}

/// The household's private address for forwarded receipts.
enum ReceiptInbox {
    static let domain = "in.getfoon.com"

    static func address(token: String) -> String { "r-\(token)@\(domain)" }
}

/// A typed forwarding address, checked on the device before it's sent. The app never keeps it.
enum ReceiptSenderAddress {
    /// The trimmed address when it looks like one, otherwise nil. Foon's own inbox addresses can't forward to Foon.
    static func validated(_ typed: String) -> String? {
        let address = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.count <= 254, !address.contains(where: \.isWhitespace) else { return nil }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last,
              !local.isEmpty, local.count <= 64 else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              domain.lowercased() != ReceiptInbox.domain else { return nil }
        return address
    }
}

/// What `receipt-inbox?sender=add` answered. Mirrors `add_receipt_sender`'s outcomes, plus email being off (503) and
/// an address the server's stricter check refused (400 `bad_address`).
enum ReceiptSenderOutcome: Equatable, Sendable {
    case send, confirmed, taken, tooMany, rateLimited, badAddress, emailOff, failed

    init(status: Int, body: Data) {
        let answer = try? JSONDecoder().decode(Answer.self, from: body)
        guard (200..<300).contains(status) else {
            self = switch (status, answer?.error) {
            case (503, _): .emailOff
            case (400, "bad_address"): .badAddress
            default: .failed
            }
            return
        }
        self = switch answer?.outcome {
        case "send": .send
        case "confirmed": .confirmed
        case "taken": .taken
        case "too_many": .tooMany
        case "rate_limited": .rateLimited
        default: .failed
        }
    }

    /// The address went, or was already set up: the field can clear.
    var isDone: Bool { self == .send || self == .confirmed }

    func message(for address: String) -> String {
        switch self {
        case .send: String(localized: "Check \(address) for a link from Foon. It works for a day.")
        case .confirmed: String(localized: "That address is already set up.")
        case .taken: String(localized: "Another adult in your family already added that address.")
        case .tooMany: String(localized: "You can forward from up to 5 addresses. Remove one to add another.")
        case .rateLimited: String(localized: "Foon already sent that address several links. Check its inbox, including spam.")
        case .badAddress: String(localized: "That email doesn't look right. Check it and try again.")
        case .emailOff: String(localized: "Forwarding isn't available right now.")
        case .failed: String(localized: "Couldn't add it. Try again.")
        }
    }

    private struct Answer: Decodable {
        let outcome: String?
        let error: String?
    }
}

/// Forwarded receipts (anyone in the family) and the household's forwarding setup (adults). All of it needs a
/// connection; a check-off from a forwarded receipt still goes through the sync queue like a scanned one.
struct ForwardedReceiptClient: Sendable {
    /// Receipts waiting for review, newest first.
    var waiting: @Sendable (_ householdID: UUID) async throws -> [ForwardedReceipt]
    /// Confirmed or dismissed: it's gone for the whole family.
    var delete: @Sendable (_ receiptID: UUID) async throws -> Void
    /// The household's inbox token, made the first time an adult asks (`receipt_inbox_token`).
    var inboxToken: @Sendable (_ householdID: UUID) async throws -> String
    /// A new token; the old address stops working (`reset_receipt_inbox`).
    var resetInbox: @Sendable (_ householdID: UUID) async throws -> String
    /// The caller's own forwarding addresses.
    var senders: @Sendable (_ householdID: UUID, _ memberID: UUID) async throws -> [ReceiptSender]
    var removeSender: @Sendable (_ senderID: UUID) async throws -> Void
    /// Emails the address a confirmation link. Never throws: a failure is an outcome to show.
    var addSender: @Sendable (_ householdID: UUID, _ address: String) async -> ReceiptSenderOutcome
}

extension ForwardedReceiptClient {
    static let function = "receipt-inbox"

    static func live(_ client: SupabaseClient) -> ForwardedReceiptClient {
        ForwardedReceiptClient(
            waiting: { householdID in
                try await client.from("forwarded_receipts")
                    .select(ForwardedReceipt.columns)
                    .eq("household_id", value: householdID)
                    .order("received_at", ascending: false)
                    .execute()
                    .value
            },
            // Minimal: the column grants leave some columns unreadable, so a delete that returned the row would fail.
            delete: { receiptID in
                try await client.from("forwarded_receipts").delete(returning: .minimal).eq("id", value: receiptID).execute()
            },
            inboxToken: { householdID in
                try await client.rpc("receipt_inbox_token", params: ["target_household": householdID.uuidString])
                    .execute()
                    .value
            },
            resetInbox: { householdID in
                try await client.rpc("reset_receipt_inbox", params: ["target_household": householdID.uuidString])
                    .execute()
                    .value
            },
            senders: { householdID, memberID in
                try await client.from("receipt_senders")
                    .select(ReceiptSender.columns)
                    .eq("household_id", value: householdID)
                    .eq("member_id", value: memberID)
                    .order("created_at", ascending: true)
                    .execute()
                    .value
            },
            removeSender: { senderID in
                try await client.from("receipt_senders").delete(returning: .minimal).eq("id", value: senderID).execute()
            },
            addSender: { householdID, address in
                let options = FunctionInvokeOptions(query: [URLQueryItem(name: "sender", value: "add")],
                                                    body: AddSender(householdID: householdID, address: address))
                do {
                    return try await client.functions.invoke(function, options: options) { data, response in
                        ReceiptSenderOutcome(status: response.statusCode, body: data)
                    }
                } catch FunctionsError.httpError(let code, let data) {
                    return ReceiptSenderOutcome(status: code, body: data)
                } catch {
                    return .failed
                }
            }
        )
    }

    static func preview(
        waiting: [ForwardedReceipt] = [],
        token: String = "0123456789abcdef",
        senders: [ReceiptSender] = [],
        outcome: ReceiptSenderOutcome = .send,
        delete: @escaping @Sendable (UUID) async throws -> Void = { _ in }
    ) -> ForwardedReceiptClient {
        ForwardedReceiptClient(
            waiting: { _ in waiting }, delete: delete,
            inboxToken: { _ in token }, resetInbox: { _ in "0c1d2e3f4a5b6c7d" },
            senders: { _, _ in senders }, removeSender: { _ in }, addSender: { _, _ in outcome }
        )
    }

    /// The environment's default: fails loudly if a screen forgets the live client.
    static let unconfigured = ForwardedReceiptClient(
        waiting: { _ in
            assertionFailure("Set \\.forwardedReceiptClient at the app root")
            return []
        },
        delete: { _ in }, inboxToken: { _ in "" }, resetInbox: { _ in "" }, senders: { _, _ in [] },
        removeSender: { _ in }, addSender: { _, _ in .failed }
    )
}

private struct AddSender: Encodable, Sendable {
    let householdID: UUID
    let address: String

    enum CodingKeys: String, CodingKey {
        case address
        case householdID = "household_id"
    }
}
