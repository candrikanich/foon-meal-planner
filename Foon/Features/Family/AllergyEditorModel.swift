import Foundation
import Observation
import Supabase

/// A person's allergies as a set, so "kiwi, mango" and "mango, kiwi" are the same answer, and so are "kiwi" and "Kiwi".
struct AllergyChoice: Equatable, Sendable {
    var allergens: Set<Allergen> = []
    var custom: Set<String> = []

    var isEmpty: Bool { allergens.isEmpty && custom.isEmpty }

    init(allergens: Set<Allergen> = [], custom: Set<String> = []) {
        self.allergens = allergens
        // Sorted first, so which spelling stays doesn't depend on the order they came in.
        var seen = Set<String>()
        self.custom = Set(custom.sorted().filter { seen.insert(Self.key($0)).inserted })
    }

    private static func key(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil)
    }

    private var customKeys: Set<String> { Set(custom.map(Self.key)) }

    static func == (lhs: AllergyChoice, rhs: AllergyChoice) -> Bool {
        lhs.allergens == rhs.allergens && lhs.customKeys == rhs.customKeys
    }

    init(_ answer: OnboardingModel.Answer) {
        self.init(allergens: answer.allergens, custom: Set(answer.cleanedCustom))
    }

    init(rows: [AllergyRow], memberID: UUID) {
        let own = rows.filter { $0.memberID == memberID }
        self.init(allergens: Set(own.map(\.allergen).filter { $0 != .custom }),
                  custom: Set(own.filter { $0.allergen == .custom }.compactMap(\.customText)))
    }

    /// `current`, with what this edit added and took away. The server replaces a person's whole list, so saving the screen's
    /// copy would drop an allergy another parent added while this one was open.
    func merging(editFrom old: AllergyChoice, onto current: AllergyChoice) -> AllergyChoice {
        let removed = old.customKeys.subtracting(customKeys)
        return AllergyChoice(
            allergens: current.allergens.union(allergens.subtracting(old.allergens))
                .subtracting(old.allergens.subtracting(allergens)),
            custom: current.custom.filter { !removed.contains(Self.key($0)) }
                .union(custom.filter { !old.customKeys.contains(Self.key($0)) })
        )
    }
}

/// Family → a person → allergies: a parent for anyone, or an adult who isn't a parent for themselves (#285). For a parent
/// it's onboarding's one consent screen: the sentence shows whenever the answer has anything in it, and Agree and save
/// records it. An adult on their own profile sees the same sentence but can't agree for the household, so they keep
/// allergies only once a parent has. Taking the last allergy away keeps nothing, so it asks for nothing. Reads the list
/// fresh, because an empty screen from a failed load must never save as "no allergies".
@Observable @MainActor
final class AllergyEditorModel {
    enum Phase: Equatable {
        case loading, failed, ready
    }

    private(set) var phase: Phase = .loading
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    var answer = OnboardingModel.Answer()
    /// Whether a parent has agreed to keep allergy data. Only read for an adult's own profile: a parent agrees on save.
    private(set) var householdAgreed = true

    /// Bumped per load, so Try again finishing first can't be overwritten by the load it replaced.
    private var loadGeneration = 0
    private var loaded = AllergyChoice()

    private let memberID: UUID
    private let householdID: UUID
    private let ownProfile: Bool
    private let household: HouseholdClient
    private let library: LibraryClient

    init(memberID: UUID, householdID: UUID, ownProfile: Bool = false, household: HouseholdClient,
         library: LibraryClient) {
        self.memberID = memberID
        self.householdID = householdID
        self.ownProfile = ownProfile
        self.household = household
        self.library = library
    }

    /// The sentence saying what Foon does with allergies, shown whenever the answer keeps any.
    var showsStatement: Bool { !answer.isEmpty }

    /// A parent agrees to it on save; an adult on their own profile is under the agreement a parent already gave.
    var needsConsent: Bool { !ownProfile && showsStatement }

    /// Adding needs the household's agreement; taking away never does.
    var canAdd: Bool { !ownProfile || householdAgreed }

    var canSave: Bool {
        let edit = AllergyChoice(answer)
        return phase == .ready && !isSaving && edit != loaded && (canAdd || edit.isEmpty)
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        do {
            let rows = try await library.allergies(householdID)
            let agreed = try await ownProfile ? household.allergyAlerts(householdID) == .on : true
            guard generation == loadGeneration else { return }
            householdAgreed = agreed
            loaded = AllergyChoice(rows: rows, memberID: memberID)
            answer = OnboardingModel.Answer(allergens: loaded.allergens,
                                            otherText: loaded.custom.sorted().joined(separator: ", "))
            phase = .ready
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            phase = .failed
        }
    }

    /// Returns what was saved, or nil with a message.
    func save() async -> AllergyChoice? {
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }
        let edit = AllergyChoice(answer)
        do {
            let current = AllergyChoice(rows: try await library.allergies(householdID), memberID: memberID)
            let merged = edit.merging(editFrom: loaded, onto: current)
            if needsConsent {
                try await household.grantAllergyConsent(householdID, AllergyConsent.textVersion)
            }
            try await household.setAllergies(memberID, Allergen.allCases.filter(merged.allergens.contains),
                                             merged.custom.sorted())
            errorMessage = nil
            return merged
        } catch {
            errorMessage = switch ((error as? PostgrestError)?.code == "42501", ownProfile) {
            // Signed out elsewhere, removed, or a parent turned allergy alerts off while this was open.
            case (true, true):
                String(localized: "Foon can't save these to your profile now. Ask a parent, or sign in again.")
            case (true, false): String(localized: "Only parents can change allergies.")
            case (false, _): String(localized: "Couldn't save the allergies. Check your connection and try again.")
            }
            return nil
        }
    }
}

/// An adult who isn't a parent removes all of their own allergies at once (#285): one step to delete their health data
/// and withdraw for themselves. Editing one at a time is the editor's job; this only deletes, so there's nothing to
/// merge and no consent to ask for.
@Observable @MainActor
final class OwnAllergiesRemoval {
    private(set) var isRemoving = false
    private(set) var errorMessage: String?

    private let memberID: UUID
    private let household: HouseholdClient

    init(memberID: UUID, household: HouseholdClient) {
        self.memberID = memberID
        self.household = household
    }

    /// True once the server has deleted them.
    func remove() async -> Bool {
        guard !isRemoving else { return false }
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await household.setAllergies(memberID, [], [])
            errorMessage = nil
            return true
        } catch {
            // A refusal (signed out elsewhere, removed, made a kid) won't pass on a retry, so don't blame the connection.
            let refused = ["42501", "P0002"].contains((error as? PostgrestError)?.code)
            errorMessage = refused
                ? String(localized: "Foon can't remove these from your profile now. Sign in again, or ask a parent.")
                : String(localized: "Couldn't remove your allergies. Check your connection and try again.")
            return false
        }
    }
}
