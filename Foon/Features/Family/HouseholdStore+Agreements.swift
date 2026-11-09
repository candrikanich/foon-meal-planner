import Foundation
import Supabase

extension HouseholdStore.Phase {
    var isHeld: Bool {
        if case .held = self { true } else { false }
    }
}

/// What the agreements (#277) ask of the signed-in person, from the store's state. The decisions are AgreementPrompts'.
extension HouseholdStore {
    /// The owner counts before their profile loads; anyone else by their profile.
    var isAdult: Bool {
        household?.owner == userID || me?.ageGroup == .adult
    }

    /// The Terms gate before using the household, or (`creating`) before creating one.
    func termsGate(creating: Bool = false) -> TermsGate? {
        AgreementPrompts.termsGate(agreements, isAdult: creating || isAdult, creating: creating,
                                   justJoined: joinedJustNow)
    }

    /// Family's agreement cards. `hasOwnAllergies` is whether the signed-in person has any recorded.
    func agreementCards(hasOwnAllergies: Bool) -> [AgreementPrompt] {
        AgreementPrompts.cards(agreements, isAdult: isAdult, isParent: canManagePeople,
                               hasOwnAllergies: hasOwnAllergies)
    }

    /// `my_access_hold`, where a server without the function yet (PGRST202) has nobody held. Any other failure throws:
    /// it can't be read as "not held".
    func readAccessHold() async throws -> AccessHold? {
        do {
            return try await client.accessHold()
        } catch let error as PostgrestError where error.code == "PGRST202" {
            return nil
        }
    }

    /// The kid's hold, for a parent, while one is open.
    func kidHold(for member: Member) -> AgreementStatus.KidHold? {
        agreements.kidsHeld.first { $0.memberID == member.id }
    }
}
