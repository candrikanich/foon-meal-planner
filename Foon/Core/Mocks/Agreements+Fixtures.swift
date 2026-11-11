import Foundation

extension UUID {
    /// Grace, the grandparent who plans and isn't a parent, when a preview signs in as her.
    static let previewGrace = UUID(uuidString: "00000000-0000-0000-0000-0000000000f2")!
}

extension Member {
    /// The sample family with Grace's account linked, for previews seen as an adult who isn't a parent.
    static var sampleFamilySignedInAsGrace: [Member] {
        sampleFamily.enumerated().map { index, member in
            var linked = member
            if index == 2 { linked.userID = .previewGrace }
            return linked
        }
    }
}

/// The registry's summaries as the server sends them: English from the database, so not in the String Catalog.
extension AgreementStatus.Allergy {
    static var previewSummary: String {
        "Foon now names who receives your family's allergies (only your household and our hosting provider) and how "
            + "a parent withdraws, which erases them all."
    }
    static var previewOwnSummary: String {
        "Adults who aren't parents now agree for themselves before Foon keeps their own allergies."
    }
}

extension AgreementStatus {
    /// Everything in force and outdated: new allergy wording, Grace's own say, and Owen signed out.
    static let previewHeld = AgreementStatus(
        terms: Account(current: "terms-draft-v1", agreed: "terms-draft-v1", satisfied: true, summary: nil),
        privacy: Account(current: "privacy-draft-v1", agreed: "privacy-draft-v1", satisfied: true, summary: nil),
        allergy: Allergy(current: AllergyConsent.textVersion, summary: Allergy.previewSummary, consented: true,
                         householdCurrent: false, held: true, ownCurrent: false,
                         ownVersion: OwnAllergyConsent.textVersion, ownSummary: Allergy.previewOwnSummary),
        kidsHeld: [KidHold(memberID: Member.sampleFamily[3].id, firstName: "Owen",
                           heldAt: .now.addingTimeInterval(-86_400), emailedAt: .now.addingTimeInterval(-80_000),
                           requiredVersion: "parental-invite-v3",
                           summary: "Foon now confirms a parent's consent by email, and names the services that "
                               + "store and send your kid's information.",
                           emailedMeAt: .now.addingTimeInterval(-80_000))]
    )

    /// The household has agreed to the new allergy wording; Grace hasn't given her own say.
    static var previewOwnNeeded: AgreementStatus {
        var status = previewHeld
        status.allergy?.householdCurrent = true
        status.allergy?.held = false
        status.kidsHeld = []
        return status
    }

    /// Terms and Privacy in force, never agreed.
    static let previewTermsNew = AgreementStatus(
        terms: Account(current: "terms-draft-v1", agreed: nil, satisfied: false,
                       summary: "Foon's Terms of Use: the rules for using Foon, which every adult agrees to."),
        privacy: Account(current: "privacy-draft-v1", agreed: nil, satisfied: false,
                         summary: "Foon's Privacy Policy: what Foon keeps about your family, why, and for how long."),
        allergy: nil, kidsHeld: []
    )
}

extension TermsGate {
    static let previewFirstTime = TermsGate(firstTime: true, context: .nextLaunch, terms: "terms-draft-v1",
                                            privacy: "privacy-draft-v1", summaries: [])
    /// The gate every adult sees once privacy v2 is in force (#48), with its registry summary.
    static let previewChanged = TermsGate(
        firstTime: false, context: .changed, terms: "terms-draft-v1", privacy: "privacy-draft-v2",
        summaries: ["The Privacy Policy now lists the emails Foon sends adults (account notices, plus a weekly plan "
            + "email and founding-family updates only if you turn them on), and that Foon counts finished shopping "
            + "trips, never what was bought."]
    )
}

extension AccessHold {
    static let preview = AccessHold(householdName: "The Smiths", firstName: "Nora",
                                    heldAt: .now.addingTimeInterval(-3600))
}
