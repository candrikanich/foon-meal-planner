import SwiftUI

/// A kid's invite section until a parent's consent is active (COPPA email plus, #275): Foon emails the parent, who
/// agrees on getfoon.com. The invite itself is made here once consent is active.
struct ParentalConsentRows: View {
    @Environment(HouseholdStore.self) private var store
    let member: Member
    @State private var typedEmail = ""
    @State private var isSending = false

    var body: some View {
        let step = store.consentStep(for: member)
        explanation(for: step)
        if step.offersPolicyLinks {
            PolicyLinks()
        }
        if store.consentRequests.needsTypedEmail(member.id), step.button != nil {
            Text("Your Apple sign-in doesn't share an email with Foon. Type the one to send it to.")
                .font(.callout)
            TextField("Your email", text: $typedEmail)
                .autocorrectionDisabled()
                #if os(iOS)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
        }
        if let title = step.button {
            Button(title) {
                Task { await send() }
            }
            .disabled(isSending || (store.consentRequests.needsTypedEmail(member.id) && typedEmail.isEmpty))
        }
        if let notice = store.consentRequests.notice(for: member.id) {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func send() async {
        isSending = true
        let email = store.consentRequests.needsTypedEmail(member.id) ? typedEmail : nil
        await store.askForConsent(member, email: email)
        isSending = false
    }

    @ViewBuilder
    private func explanation(for step: ParentalConsentStep) -> some View {
        let name = member.firstName
        let another = String(localized: "another parent", comment: "Stands in for a parent whose name isn't known")
        switch step {
        case .emailMe, .sendNewEmail, .invite:
            Text("To invite \(name), Foon emails you to confirm you're their parent.")
                .font(.callout)
        case .checkEmail(let sentTo, .me):
            Text("Check your email. We sent it to \(sentTo.description). Tap the link to agree, then come back here.")
                .font(.callout)
        case .checkEmail(_, .otherParent(let parent)):
            Text("Foon emailed \(parent ?? another) to confirm. Once they agree, you can invite \(name) here.")
                .font(.callout)
        case .almostDone(.me):
            Text("Almost done. Open the email and tap I agree again to finish.")
                .font(.callout)
        case .almostDone(.otherParent(let parent)):
            Text("Almost done: \(parent ?? another) agreed in the email, and it's finishing up.")
                .font(.callout)
        case .refused(.me):
            Text("You said no in the email. \(name) can't be invited.")
                .font(.callout)
        case .refused(.otherParent(let parent?)):
            Text("\(parent) said no in the email. \(name) can't be invited.")
                .font(.callout)
        case .refused(.otherParent(nil)):
            Text("A parent said no in the email. \(name) can't be invited.")
                .font(.callout)
        }
    }
}

extension ParentalConsentStep {
    /// What the one button says, if the step has one; every one sends email 1.
    var button: LocalizedStringKey? {
        switch self {
        case .emailMe: "Email me"
        case .checkEmail(_, .me): "Send again"
        case .checkEmail(_, .otherParent): "Email me instead"
        case .refused: "Ask again"
        case .sendNewEmail: "Send a new email"
        case .almostDone, .invite: nil
        }
    }

    /// Before the email goes out, the parent can read what they'd be agreeing to.
    var offersPolicyLinks: Bool {
        switch self {
        case .emailMe, .sendNewEmail, .refused: true
        case .checkEmail, .almostDone, .invite: false
        }
    }
}

extension ConsentEmailAddress {
    /// How "We sent it to …" ends.
    var description: String {
        switch self {
        case .address(let email): email
        case .hideMyEmail: String(localized: "your Hide My Email address, which forwards to your inbox")
        case .accountEmail: String(localized: "the email on your Apple sign-in")
        case .typedEmail: String(localized: "the address you gave")
        }
    }
}

@MainActor
private func consentPreview(
    requests: [ParentalConsentRequest] = [], consented: Bool = false,
    answer: ParentalConsentAnswer? = nil, error: ParentalConsentError? = nil
) -> some View {
    let kid = Member.sampleFamily[4]
    var client = HouseholdClient.preview()
    client.parentalConsentRequests = { _ in requests }
    client.parentalConsentMemberIDs = { _ in consented ? [kid.id] : [] }
    client.requestParentalConsent = { _, _ in
        if let error { throw error }
        return answer ?? .noEmail
    }
    let store = HouseholdStore(userID: .previewUser, client: client)
    return MemberEditorView(member: kid)
        .environment(store)
        .task {
            await store.load()
            await store.loadConsentRequests()
            if answer != nil || error != nil { await store.askForConsent(kid) }
        }
}

private func previewRequest(_ status: ParentalConsentRequest.Status, by parent: UUID = .previewUser,
                            expiresIn days: Double = 6) -> ParentalConsentRequest {
    ParentalConsentRequest(
        id: UUID(), householdID: Household.sample.id, memberID: Member.sampleFamily[4].id, requestedBy: parent,
        status: status, emailSource: .account, expiresAt: .now.addingTimeInterval(days * 86_400),
        createdAt: .now.addingTimeInterval(-3600)
    )
}

#Preview("Email me") { consentPreview() }

#Preview("Check your email") {
    consentPreview(answer: .sent(requestID: UUID(), email: "ann@example.com", source: .account))
}

#Preview("Check your email, Hide My Email") {
    consentPreview(answer: .sent(requestID: UUID(), email: "x7q2p9@privaterelay.appleid.com", source: .account))
}

#Preview("Another parent was emailed") { consentPreview(requests: [previewRequest(.pending, by: UUID())]) }

#Preview("Almost done") { consentPreview(requests: [previewRequest(.consented)]) }

#Preview("You said no") { consentPreview(requests: [previewRequest(.refused)]) }

#Preview("Send a new email") { consentPreview(requests: [previewRequest(.pending, expiresIn: -1)]) }

#Preview("No email on the account") { consentPreview(answer: .noEmail) }

#Preview("Try again in a little while") { consentPreview(error: .rateLimited) }

#Preview("Email is off") { consentPreview(error: .emailOff) }

#Preview("Invite") { consentPreview(consented: true) }
