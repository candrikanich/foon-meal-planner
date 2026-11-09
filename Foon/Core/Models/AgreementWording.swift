import Foundation

/// The wording versions this build shows and logs (#277). Each is registered in `agreement_versions`; a change in what
/// one promises is a new version there and here. Terms, Privacy and the kid's parental wording aren't here: the server
/// says which is in force, the links show Terms and Privacy, and the parental wording is the consent email's.

/// The sentence a parent agrees to before Foon keeps the household's allergies.
enum AllergyConsent {
    /// v2 (#280): names who receives allergies and how to withdraw (Washington MHMDA .030(2)).
    static let textVersion = "allergy-data-v2"
    /// Logged by "Load a sample family", where nobody read the sentence: the record says so.
    static let sampleVersion = "sample-family-v1"
    /// The versions an agreement to `textVersion` covers, so this build can offer Agree when one of them is in force.
    /// Anything else in force is newer wording this build can't show.
    static let covers: Set<String> = ["allergy-data-v1", textVersion]

    static var statement: String {
        String(localized: """
        Foon keeps these so it can flag dishes. Only your household and our hosting provider, which stores them for \
        us, receive them. They're never sold, never used for ads, and never leave your devices for AI. A parent can \
        withdraw anytime in Family → Allergy alerts, which erases them all.
        """, comment: """
            Allergy consent parents agree to. Must say exactly what the English says; see AllergyConsent.textVersion.
            """)
    }
}

/// An adult who isn't a parent agrees for their own allergies: a parent's agreement covers the household, and this is
/// the adult's own say (`agree_to_own_allergies`).
enum OwnAllergyConsent {
    static let textVersion = "own-allergy-v1"
    static let covers: Set<String> = [textVersion]

    static var statement: String {
        String(localized: """
        Foon keeps your allergies so it can flag dishes for you. Only your household and our hosting provider, which \
        stores them for us, receive them. They're never sold, never used for ads, and never leave your devices for AI. \
        You can remove them anytime on your profile, which deletes them.
        """, comment: """
            Own-allergy consent an adult who isn't a parent agrees to. Must say exactly what the English says; see \
            OwnAllergyConsent.textVersion.
            """)
    }
}
