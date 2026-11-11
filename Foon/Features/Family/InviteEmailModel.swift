import Foundation
import Observation

/// Invite → Email the invite, for an adult's profile with a code just made (#48 PR B). The typed address is checked
/// here as the server checks it, sent once, and forgotten once the email is out.
@Observable @MainActor
final class InviteEmailModel {
    enum Phase: Equatable {
        case editing, sending, sent
        case failed(String)
    }

    var address = ""
    private(set) var phase: Phase = .editing
    let member: Member
    private let code: String
    private let emailInvite: @Sendable (InviteEmailRequest) async throws -> Void

    init(member: Member, code: String, emailInvite: @escaping @Sendable (InviteEmailRequest) async throws -> Void) {
        self.member = member
        self.code = code
        self.emailInvite = emailInvite
    }

    var canSend: Bool {
        phase != .sending && phase != .sent && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { message } else { nil }
    }

    func send() async {
        guard canSend else { return }
        let request = InviteEmailRequest(memberID: member.id, code: code, email: address)
        guard ConsentEmail.isValid(request.email) else {
            phase = .failed(InviteEmailError.badEmail.message)
            return
        }
        phase = .sending
        do {
            try await emailInvite(request)
            address = ""
            phase = .sent
        } catch let error as InviteEmailError {
            phase = .failed(error.message)
        } catch {
            phase = .failed(InviteEmailError.tryAgain.message)
        }
    }
}
