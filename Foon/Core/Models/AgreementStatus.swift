import Foundation

/// What the signed-in person has agreed to and what's waiting (`my_agreements`, #277). A version that's nil isn't in
/// force: while nothing is (the agreements ship dormant), every field reads as agreed and nothing is asked.
struct AgreementStatus: Decodable, Equatable, Sendable {
    /// This account's Terms of Use or Privacy Policy acceptance.
    struct Account: Decodable, Equatable, Sendable {
        /// The version in force, nil while none is.
        var current: String?
        /// The newest version this account agreed to, whether or not it still counts.
        var agreed: String?
        var satisfied: Bool
        /// What the version in force is about, in one plain English sentence from the server.
        var summary: String?

        static let dormant = Account(current: nil, agreed: nil, satisfied: true, summary: nil)
    }

    /// The household's allergy agreement and the caller's own.
    struct Allergy: Decodable, Equatable, Sendable {
        var current: String?
        var summary: String?
        /// Whether allergy alerts are on: a household that never agreed is asked when it turns them on, not here.
        var consented: Bool
        var householdCurrent: Bool
        /// Whether the server has opened a hold (it's enforced from `householdCurrent` either way).
        var held: Bool
        /// A parent's always is; an adult who isn't a parent needs their own once `ownVersion` is in force.
        var ownCurrent: Bool
        var ownVersion: String?
        var ownSummary: String?

        enum CodingKeys: String, CodingKey {
            case current, summary, consented, held
            case householdCurrent = "household_current"
            case ownCurrent = "own_current"
            case ownVersion = "own_version"
            case ownSummary = "own_summary"
        }
    }

    /// A kid signed out until a parent agrees to the kids' wording in force (parents only).
    struct KidHold: Decodable, Equatable, Sendable, Identifiable {
        var memberID: UUID
        var firstName: String
        var heldAt: Date
        /// When the renewal email went out to any parent.
        var emailedAt: Date?
        var requiredVersion: String
        /// What changed, from the server.
        var summary: String?
        /// When the renewal email last went to the signed-in parent.
        var emailedMeAt: Date?
        /// Whether the kid had signed in on their own device when the hold began, so the hold signed them out. Nil from
        /// a server before #277's turn-on migration, which didn't send it.
        var wasLinked: Bool?

        var id: UUID { memberID }

        /// The renewal's first line in the kid's invite section. Says the kid is signed out only when the hold did
        /// sign them out; a kid who never signed in gets the neutral line.
        var renewalExplanation: String {
            if wasLinked == true {
                String(localized: """
                Foon changed what parents agree to for kids. \(firstName) is signed out until a parent agrees. \
                Nothing was deleted.
                """)
            } else {
                String(localized: """
                Foon changed what parents agree to for kids. \(firstName) needs a parent's OK again before using \
                Foon. Nothing was deleted.
                """)
            }
        }

        enum CodingKeys: String, CodingKey {
            case summary
            case memberID = "member_id"
            case firstName = "first_name"
            case heldAt = "held_at"
            case emailedAt = "emailed_at"
            case requiredVersion = "required_version"
            case emailedMeAt = "emailed_me_at"
            case wasLinked = "was_linked"
        }
    }

    var terms: Account
    var privacy: Account
    /// Nil before the person has a household.
    var allergy: Allergy?
    var kidsHeld: [KidHold]

    static let dormant = AgreementStatus(terms: .dormant, privacy: .dormant, allergy: nil, kidsHeld: [])

    enum CodingKeys: String, CodingKey {
        case terms, privacy, allergy
        case kidsHeld = "kids_held"
    }

    init(terms: Account, privacy: Account, allergy: Allergy?, kidsHeld: [KidHold]) {
        self.terms = terms
        self.privacy = privacy
        self.allergy = allergy
        self.kidsHeld = kidsHeld
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terms = try container.decode(Account.self, forKey: .terms)
        privacy = try container.decode(Account.self, forKey: .privacy)
        allergy = try container.decodeIfPresent(Allergy.self, forKey: .allergy)
        kidsHeld = try container.decodeIfPresent([KidHold].self, forKey: .kidsHeld) ?? []
    }

    /// After Agree went through: the versions in force now count, before a reload confirms it.
    func acceptingTerms() -> AgreementStatus {
        var accepted = self
        accepted.terms = Account(current: terms.current, agreed: terms.current, satisfied: true, summary: terms.summary)
        accepted.privacy = Account(current: privacy.current, agreed: privacy.current, satisfied: true,
                                   summary: privacy.summary)
        return accepted
    }
}

/// A kid's own device after a hold signed them out (`my_access_hold`): their account has no household now.
struct AccessHold: Decodable, Equatable, Sendable {
    var householdName: String
    var firstName: String
    var heldAt: Date

    enum CodingKeys: String, CodingKey {
        case householdName = "household_name"
        case firstName = "first_name"
        case heldAt = "held_at"
    }
}

/// Where Terms and Privacy were agreed, as `accept_agreements` logs it.
enum AgreementContext: String, Equatable, Sendable {
    case createHousehold = "create_household"
    case join
    case nextLaunch = "next_launch"
    case changed
}

/// This build, as `accept_agreements` logs it ("iOS 0.1.0 (75)"), at most 40 characters.
enum AppVersion {
    static var client: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        return String("\(platform) \(version) (\(build))".prefix(40))
    }
}
