import SwiftUI

/// Family → Email, for adults: the weekly plan email and founding-family updates, each theirs alone and off until they
/// turn it on. On shows what they're agreeing to first; off takes effect at once. Family loads the model, since a
/// section that shows nothing never appears to load itself.
struct EmailPreferencesSection: View {
    let model: EmailPreferencesModel
    @State private var agreeing: EmailOptIn?

    var body: some View {
        if model.isShown {
            Section {
                ForEach(EmailOptIn.allCases) { email in
                    Toggle(isOn: Binding(
                        get: { model.isOn(email) },
                        set: { isOn in
                            model.clearError()
                            if isOn {
                                agreeing = email
                            } else {
                                Task { _ = await model.turnOff(email) }
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(email.title)
                            Text(email.explanation).font(.foonCaption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.saving != nil)
                    .accessibilityHint(model.isOn(email)
                        ? Text("Turns this email off.")
                        : Text("Shows what you're agreeing to before it turns on."))
                }
            } header: {
                Text("Email")
            } footer: {
                if let message = model.errorMessage, agreeing == nil {
                    Text(message).foregroundStyle(.red)
                } else {
                    Text("Just for you, at the email Apple gave for your account. Nobody else in your family sees these settings.")
                }
            }
            .sheet(item: $agreeing, onDismiss: model.clearError) { email in
                EmailOptInAgreementView(email: email, model: model)
            }
        }
    }
}

/// Turning one on: what it sends, and Agree and turn on.
private struct EmailOptInAgreementView: View {
    @Environment(\.dismiss) private var dismiss
    let email: EmailOptIn
    let model: EmailPreferencesModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(email.statement)
                }
                if let message = model.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle(email.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agree and turn on") {
                        Task {
                            if await model.turnOn(email) { dismiss() }
                        }
                    }
                    .disabled(model.saving != nil)
                }
            }
        }
    }
}

#Preview("Both off") {
    let model = EmailPreferencesModel(client: .preview())
    NavigationStack {
        List { EmailPreferencesSection(model: model) }
    }
    .task { await model.load() }
}

#Preview("Weekly plan on") {
    var client = HouseholdClient.preview()
    client.emailPreferences = { EmailPreferences(weeklyPlan: true, canOptIn: true, available: true) }
    let model = EmailPreferencesModel(client: client)
    return NavigationStack {
        List { EmailPreferencesSection(model: model) }
    }
    .task { await model.load() }
}

#Preview("Agreeing") {
    EmailOptInAgreementView(email: .foundingUpdates, model: EmailPreferencesModel(client: .preview()))
}
