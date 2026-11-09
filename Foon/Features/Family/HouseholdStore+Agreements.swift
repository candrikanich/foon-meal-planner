import Foundation

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

    /// The kid's hold, for a parent, while one is open.
    func kidHold(for member: Member) -> AgreementStatus.KidHold? {
        agreements.kidsHeld.first { $0.memberID == member.id }
    }
}
