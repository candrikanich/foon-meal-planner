import Foundation
import Observation
import Supabase

/// Whether the household keeps allergies, read from its allergy consent log.
enum AllergyAlerts: Equatable, Sendable {
    /// Nobody has agreed yet: a family without allergies, which sees no allergy settings.
    case neverOn
    case on
    /// A parent turned them off, which erased every allergy the household had.
    case off

    /// From each allergy consent's revocation time, nil while it's active.
    init(revokedAt: [Date?]) {
        if revokedAt.contains(where: { $0 == nil }) {
            self = .on
        } else {
            self = revokedAt.isEmpty ? .neverOn : .off
        }
    }
}

/// Family → Allergy alerts (parents). Off revokes the household's consent, and the database erases every allergy; on
/// asks for the same consent as onboarding. Shown only once the family has turned them on, so a family without
/// allergies never sees it, and never while the state is unknown.
@Observable @MainActor
final class AllergyAlertsModel {
    enum Phase: Equatable {
        case loading, failed
        case ready(AllergyAlerts)
    }

    private(set) var phase: Phase = .loading
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let householdID: UUID
    private let client: HouseholdClient

    init(householdID: UUID, client: HouseholdClient) {
        self.householdID = householdID
        self.client = client
    }

    var isShown: Bool {
        phase == .ready(.on) || phase == .ready(.off)
    }

    /// A failed reload keeps what it knew; only a first load that fails shows nothing.
    func load() async {
        do {
            phase = .ready(try await client.allergyAlerts(householdID))
        } catch {
            guard !Task.isCancelled, phase == .loading else { return }
            phase = .failed
        }
    }

    /// True once the server has erased the household's allergies.
    func turnOff() async -> Bool {
        let (client, householdID) = (client, householdID)
        return await save(.off) { try await client.revokeAllergyConsent(householdID) }
    }

    func turnOn() async -> Bool {
        let (client, householdID) = (client, householdID)
        return await save(.on) { try await client.grantAllergyConsent(householdID, AllergyConsent.textVersion) }
    }

    private func save(_ result: AllergyAlerts, _ write: () async throws -> Void) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            try await write()
            phase = .ready(result)
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? PostgrestError)?.code == "42501"
                ? String(localized: "Only parents can turn allergy alerts on or off.")
                : String(localized: "Couldn't change allergy alerts. Check your connection and try again.")
            return false
        }
    }
}
