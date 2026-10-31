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

/// Family → a person → allergies (parents only). The same consent as onboarding's one screen: the sentence shows whenever
/// the answer has anything in it, and Agree and save records it. Taking the last allergy away keeps nothing, so it asks
/// for nothing. Reads the list fresh, because an empty screen from a failed load must never save as "no allergies".
@Observable @MainActor
final class AllergyEditorModel {
    enum Phase: Equatable {
        case loading, failed, ready
    }

    private(set) var phase: Phase = .loading
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    var answer = OnboardingModel.Answer()

    /// Bumped per load, so Try again finishing first can't be overwritten by the load it replaced.
    private var loadGeneration = 0
    private var loaded = AllergyChoice()

    private let memberID: UUID
    private let householdID: UUID
    private let household: HouseholdClient
    private let library: LibraryClient

    init(memberID: UUID, householdID: UUID, household: HouseholdClient, library: LibraryClient) {
        self.memberID = memberID
        self.householdID = householdID
        self.household = household
        self.library = library
    }

    var needsConsent: Bool { !answer.isEmpty }

    var canSave: Bool { phase == .ready && !isSaving && AllergyChoice(answer) != loaded }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        do {
            let rows = try await library.allergies(householdID)
            guard generation == loadGeneration else { return }
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
            errorMessage = (error as? PostgrestError)?.code == "42501"
                ? String(localized: "Only parents can change allergies.")
                : String(localized: "Couldn't save the allergies. Check your connection and try again.")
            return nil
        }
    }
}
