import Foundation
import Observation
import Supabase

/// Agree, for the Terms gate and the allergy sheets (#277). Each sheet has its own, so an error stays with the attempt
/// that made it.
@Observable @MainActor
final class AgreementActions {
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    /// Logs this account's agreement to the Terms and Privacy versions in force.
    func accept(_ gate: TermsGate, using client: HouseholdClient) async -> Bool {
        await run { try await client.acceptAgreements(gate.terms, gate.privacy, gate.context, AppVersion.client) }
    }

    /// A parent agrees, for the household, to the allergy sentence this build shows.
    func agreeForHousehold(_ householdID: UUID, using client: HouseholdClient) async -> Bool {
        await run { try await client.grantAllergyConsent(householdID, AllergyConsent.textVersion) }
    }

    /// An adult who isn't a parent agrees to keep their own allergies.
    func agreeForMyself(_ memberID: UUID, using client: HouseholdClient) async -> Bool {
        await run { try await client.agreeToOwnAllergies(memberID, OwnAllergyConsent.textVersion) }
    }

    private func run(_ agree: () async throws -> Void) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await agree()
            errorMessage = nil
            return true
        } catch {
            // A refusal won't pass on a retry, so it doesn't blame the connection.
            errorMessage = switch (error as? PostgrestError)?.code {
            case "28000": String(localized: "Sign in again, then agree.")
            case "22023": String(localized: "Update Foon to review the new wording.")
            case "42501":
                String(localized: "Foon can't record this for you now. Try again in a moment, or sign in again.")
            default: String(localized: "Couldn't save that. Check your connection and try again.")
            }
            return false
        }
    }
}
