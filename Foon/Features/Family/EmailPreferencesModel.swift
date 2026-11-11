import Foundation
import Observation
import Supabase

/// Family → Email (#48): an adult's own email switches. Turning one on logs their agreement to its wording; off needs
/// nothing. Shown only once loaded, so never a switch that might be wrong.
@Observable @MainActor
final class EmailPreferencesModel {
    enum Phase: Equatable {
        case loading, failed
        case ready(EmailPreferences)
    }

    private(set) var phase: Phase = .loading
    /// The switch being saved, so only it waits.
    private(set) var saving: EmailOptIn?
    private(set) var errorMessage: String?

    private let client: HouseholdClient

    init(client: HouseholdClient) {
        self.client = client
    }

    var isShown: Bool {
        if case .ready(let preferences) = phase { preferences.isShown } else { false }
    }

    func isOn(_ email: EmailOptIn) -> Bool {
        if case .ready(let preferences) = phase { preferences.isOn(email) } else { false }
    }

    /// A failed reload keeps what it knew; only a first load that fails shows nothing.
    func load() async {
        do {
            phase = .ready(try await client.emailPreferences())
        } catch {
            guard !Task.isCancelled, phase == .loading else { return }
            phase = .failed
        }
    }

    func turnOn(_ email: EmailOptIn) async -> Bool {
        await save(email, isOn: true, wording: email.textVersion)
    }

    func turnOff(_ email: EmailOptIn) async -> Bool {
        await save(email, isOn: false, wording: nil)
    }

    /// An error belongs to the attempt that made it.
    func clearError() {
        errorMessage = nil
    }

    private func save(_ email: EmailOptIn, isOn: Bool, wording: String?) async -> Bool {
        errorMessage = nil
        saving = email
        defer { saving = nil }
        do {
            phase = .ready(try await client.setEmailPreference(email, isOn, wording, AppVersion.client))
            return true
        } catch {
            errorMessage = switch (error as? PostgrestError)?.code {
            case "42501": String(localized: "Only adults can get email from Foon.")
            case "55000": String(localized: "Foon doesn't send email yet. Try again later.")
            default: String(localized: "Couldn't change your email. Check your connection and try again.")
            }
            return false
        }
    }
}
