import SwiftUI

/// Email the invite (#48 PR B): one field for the adult's address, then Send. Foon emails them the link and the code,
/// says who sent it, and keeps no copy of the address.
struct InviteEmailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: InviteEmailModel

    init(model: InviteEmailModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.phase == .sent {
                    sentSection
                } else {
                    addressSection
                }
            }
            .navigationTitle("Email the invite")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
    }

    private var addressSection: some View {
        Section {
            TextField("\(model.member.firstName)'s email", text: $model.address)
                .autocorrectionDisabled()
                #if os(iOS)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.send)
                .onSubmit { Task { await model.send() } }
                .disabled(model.phase == .sending)
                .accessibilityLabel("\(model.member.firstName)'s email address")
            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Foon emails \(model.member.firstName) the link and the code, and says it's from you. It uses this address only to send this one email, and doesn't keep it.")
        }
    }

    private var sentSection: some View {
        Section {
            Label("Invite sent to \(model.member.firstName).", systemImage: "checkmark.circle")
                .accessibilityAddTraits(.isHeader)
            Text("If it doesn't arrive, ask them to check their spam folder, or send the invite another way.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.phase == .sent {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.phase == .sending {
                    ProgressView()
                        .accessibilityLabel("Sending")
                } else {
                    Button("Send") { Task { await model.send() } }
                        .disabled(!model.canSend)
                        .accessibilityHint("Emails the invite to \(model.member.firstName)")
                }
            }
        }
    }
}

@MainActor
private func inviteEmailPreview(
    typed: String = "", sendNow: Bool = false,
    result: @escaping @Sendable () throws -> Void = {}
) -> some View {
    let model = InviteEmailModel(member: Member.sampleFamily[1], code: "THESM-7KQ4-M9XP") { _ in try result() }
    model.address = typed
    return InviteEmailSheet(model: model)
        .task { if sendNow { await model.send() } }
}

#Preview("Type the address") { inviteEmailPreview() }

#Preview("Sent") { inviteEmailPreview(typed: "sam@example.com", sendNow: true) }

#Preview("Email is off") {
    inviteEmailPreview(typed: "sam@example.com", sendNow: true) { throw InviteEmailError.emailOff }
}

#Preview("Not an address") { inviteEmailPreview(typed: "sam@example", sendNow: true) }
