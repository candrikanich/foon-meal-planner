import Foundation

/// The Terms and Privacy gate: shown to an adult before creating a household or using one, until they agree to the
/// versions in force.
struct TermsGate: Equatable, Sendable {
    /// Never agreed to any version: "Before you start". Otherwise "We updated our terms".
    var firstTime: Bool
    var context: AgreementContext
    var terms: String
    var privacy: String
    /// What changed, for the ones that need agreeing again.
    var summaries: [String]
}

/// Something waiting on the signed-in person, shown as a card on Family (#277).
enum AgreementPrompt: Equatable, Sendable, Identifiable {
    /// A parent: the household's allergy wording changed. Review, then Agree.
    case allergyAgreement(summary: String?)
    /// An adult who isn't a parent: a parent needs to agree. Read it.
    case allergyWaitingOnParent(summary: String?)
    /// An adult who isn't a parent: keep your own allergies in Foon?
    case ownAllergies(summary: String?)
    /// The wording in force is newer than this build can show.
    case updateFoon
    /// A parent: a kid is signed out until a parent agrees to the kids' wording again.
    case kidHeld(AgreementStatus.KidHold)

    var id: String {
        switch self {
        case .allergyAgreement: "allergy"
        case .allergyWaitingOnParent: "allergy-waiting"
        case .ownAllergies: "own-allergies"
        case .updateFoon: "update"
        case .kidHeld(let hold): "kid-\(hold.memberID)"
        }
    }
}

/// Why the allergy editor can't add right now; taking away always works.
enum AllergyAddBlock: Equatable, Sendable {
    /// The household's wording changed and only a parent agrees to it.
    case waitingOnParent
    /// The adult's own agreement is needed first.
    case ownAgreementNeeded
    /// The wording in force is newer than this build can show.
    case updateFoon
}

/// Decides what to ask from what the server says is in force. Pure, so dormant (nothing in force) asks nothing.
enum AgreementPrompts {
    /// Nil unless both Terms and Privacy are in force and this person hasn't agreed to one of them. Kids never see it.
    static func termsGate(_ status: AgreementStatus, isAdult: Bool, creating: Bool, justJoined: Bool) -> TermsGate? {
        guard isAdult, let terms = status.terms.current, let privacy = status.privacy.current,
              !(status.terms.satisfied && status.privacy.satisfied) else { return nil }
        let firstTime = status.terms.agreed == nil && status.privacy.agreed == nil
        let context: AgreementContext = if !firstTime {
            .changed
        } else if creating {
            .createHousehold
        } else if justJoined {
            .join
        } else {
            .nextLaunch
        }
        let summaries = [status.terms, status.privacy].filter { !$0.satisfied }.compactMap(\.summary)
        return TermsGate(firstTime: firstTime, context: context, terms: terms, privacy: privacy, summaries: summaries)
    }

    /// Family's cards, allergy ones first. `isAdult` and `isParent` are the signed-in person's; `hasOwnAllergies`
    /// keeps "Keep your allergies?" from asking someone with none.
    static func cards(
        _ status: AgreementStatus, isAdult: Bool, isParent: Bool, hasOwnAllergies: Bool,
        allergyCovers: Set<String> = AllergyConsent.covers, ownCovers: Set<String> = OwnAllergyConsent.covers
    ) -> [AgreementPrompt] {
        var prompts: [AgreementPrompt] = []
        if let allergy = status.allergy, allergy.consented, let current = allergy.current, !allergy.householdCurrent {
            if isParent {
                let canShow = allergyCovers.contains(current)
                prompts.append(canShow ? .allergyAgreement(summary: allergy.summary) : .updateFoon)
            } else if isAdult {
                prompts.append(.allergyWaitingOnParent(summary: allergy.summary))
            }
        }
        if let allergy = status.allergy, allergy.consented, let own = allergy.ownVersion, !allergy.ownCurrent,
           isAdult, !isParent, hasOwnAllergies {
            let prompt: AgreementPrompt = ownCovers.contains(own)
                ? .ownAllergies(summary: allergy.ownSummary) : .updateFoon
            if !prompts.contains(prompt) { prompts.append(prompt) }
        }
        if isParent {
            prompts += status.kidsHeld.map(AgreementPrompt.kidHeld)
        }
        return prompts
    }

    /// Whether the allergy editor may add, for a parent (`ownProfile` false) or an adult on their own profile.
    static func addBlock(
        _ status: AgreementStatus, ownProfile: Bool,
        allergyCovers: Set<String> = AllergyConsent.covers, ownCovers: Set<String> = OwnAllergyConsent.covers
    ) -> AllergyAddBlock? {
        guard let allergy = status.allergy, allergy.consented else { return nil }
        if let current = allergy.current, !allergy.householdCurrent {
            // A parent's Agree and save agrees to the wording, when this build has it.
            if !ownProfile { return allergyCovers.contains(current) ? nil : .updateFoon }
            return .waitingOnParent
        }
        if ownProfile, let own = allergy.ownVersion, !allergy.ownCurrent {
            return ownCovers.contains(own) ? .ownAgreementNeeded : .updateFoon
        }
        return nil
    }
}
