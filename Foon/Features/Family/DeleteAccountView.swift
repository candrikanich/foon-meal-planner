import AuthenticationServices
import SwiftUI

/// What deleting this person's account does, so the confirmation can say it plainly (docs/spec.md, Retention).
enum AccountDeletion: Equatable {
    /// The owner: the household goes, for everyone.
    case household(name: String)
    /// An adult: their profile leaves; ratings stay as "Former member."
    case adult(householdName: String)
    /// A kid: their account goes; the profile their parents entered stays.
    case kid
    case noHousehold

    static func outcome(household: Household?, me: Member?, userID: UUID) -> AccountDeletion {
        guard let household else { return .noHousehold }
        if household.owner == userID { return .household(name: household.name) }
        if me?.ageGroup == .kid { return .kid }
        return .adult(householdName: household.name)
    }

    var consequence: String {
        switch self {
        case .household(let name):
            String(localized: "This deletes \(name) for everyone: meals, plans, lists, photos, and family profiles. Family members keep their own accounts and can start or join another household. This can't be undone.")
        case .adult(let householdName):
            String(localized: "Your profile leaves \(householdName), and your ratings stay as \"Former member.\" Your allergies and settings are deleted. This can't be undone.")
        case .kid:
            String(localized: "Your account is deleted. Your profile stays in the family, and your parents manage it.")
        case .noHousehold:
            String(localized: "Your account is deleted. This can't be undone.")
        }
    }

    /// What the button that opens this says: an owner's account takes the household with it.
    var buttonTitle: String {
        switch self {
        case .household: String(localized: "Delete my account and household")
        default: String(localized: "Delete my account")
        }
    }

    var title: String {
        switch self {
        case .household: String(localized: "Delete your account and household?")
        default: String(localized: "Delete your account?")
        }
    }
}

/// Delete my account (everyone) and, for the owner, the household. Confirming with Apple gives the server a fresh
/// authorization code, which it needs to revoke Foon's Sign in with Apple token.
struct DeleteAccountView: View {
    @Environment(SessionStore.self) private var session
    @Environment(HouseholdStore.self) private var household
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDeleting = false
    @State private var exportURL: URL?

    private var outcome: AccountDeletion {
        .outcome(household: household.household, me: household.me, userID: household.userID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(outcome.consequence)
                }
                if case .household = outcome, household.canExport {
                    Section {
                        ExportButton(exportURL: $exportURL)
                    } footer: {
                        if let message = household.errorMessage {
                            Text(message).foregroundStyle(.red)
                        } else {
                            Text("Want a copy first? Export saves everything as a file.")
                        }
                    }
                }
                Section {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = []
                    } onCompletion: { result in
                        confirm(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 44)
                    .disabled(isDeleting)
                    .accessibilityHint("Confirms with Apple, then deletes your account")
                    if isDeleting {
                        ProgressView("Deleting…")
                    }
                } footer: {
                    if let message = session.errorMessage {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Confirm with Apple to delete. Foon also stops using Sign in with Apple for your account.")
                    }
                }
            }
            .navigationTitle(outcome.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
        }
    }

    private func confirm(_ result: Result<ASAuthorization, any Error>) {
        let authorization: ASAuthorization
        switch result {
        case .success(let value): authorization = value
        case .failure(let error as ASAuthorizationError) where error.code == .canceled: return
        case .failure: session.appleConfirmationFailed(); return
        }
        let code = (authorization.credential as? ASAuthorizationAppleIDCredential)?.authorizationCode
        Task {
            isDeleting = true
            defer { isDeleting = false }
            // Signing out swaps the root view, so there's nothing to dismiss on success.
            _ = await session.deleteAccount(authorizationCode: code)
        }
    }
}

/// Builds the household export, then offers it to share or save.
struct ExportButton: View {
    @Environment(HouseholdStore.self) private var household
    @Binding var exportURL: URL?
    @State private var isExporting = false

    var body: some View {
        if let exportURL {
            ShareLink(item: exportURL) {
                Label("Share or save the export", systemImage: "square.and.arrow.up")
            }
            // The file holds allergies: don't leave it in tmp, or share an old snapshot later.
            .onDisappear {
                try? FileManager.default.removeItem(at: exportURL)
                self.exportURL = nil
            }
        } else {
            Button {
                Task {
                    isExporting = true
                    exportURL = await household.exportFile()
                    isExporting = false
                }
            } label: {
                Label(isExporting ? "Exporting…" : "Export household data", systemImage: "doc.text")
            }
            .disabled(isExporting)
        }
    }
}

#Preview("Owner") {
    let store = HouseholdStore.preview()
    DeleteAccountView()
        .environment(store)
        .environment(SessionStore(auth: .preview(signedIn: .previewUser)))
        .task { await store.load() }
}

#Preview("No household yet") {
    DeleteAccountView()
        .environment(HouseholdStore.preview(household: nil))
        .environment(SessionStore(auth: .preview(signedIn: .previewUser)))
}
