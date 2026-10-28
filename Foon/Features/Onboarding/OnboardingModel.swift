import Foundation
import Observation

/// Which starter dishes the dinner picker shows: popular first, then the catalog's own categories, with search
/// over everything and a first page before Show more.
enum DinnerPicker {
    enum Tab: Hashable, Sendable {
        case popular
        case category(String)

        var title: String {
            switch self {
            case .popular: String(localized: "Popular")
            case .category(let name): name
            }
        }
    }

    static let firstPage = 12

    static func tabs(_ catalog: [CatalogDish]) -> [Tab] {
        [.popular] + LibraryQuery.catalogSections(catalog).map { .category($0.category) }
    }

    static func visible(_ catalog: [CatalogDish], tab: Tab, search: String, showAll: Bool) -> [CatalogDish] {
        let ordered = catalog.sorted { $0.sortOrder < $1.sortOrder }
        let typed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            return ordered.filter { $0.name.localizedStandardContains(typed) }
        }
        let inTab = switch tab {
        case .popular: ordered.filter(\.popular)
        case .category(let name): ordered.filter { $0.category == name }
        }
        return showAll ? inTab : Array(inTab.prefix(firstPage))
    }
}

/// Onboarding's answers as the family goes through it: allergies (asked once, skippable) and the dinners
/// they make. Pure enough to test; the view drives it.
@Observable @MainActor
final class OnboardingModel {
    struct Answer: Equatable, Sendable {
        static let customLimit = 60

        var allergens: Set<Allergen> = []
        /// The Other field as typed; split on commas only when read, so typing "kiwi, " keeps its comma.
        var otherText = ""

        init(allergens: Set<Allergen> = [], otherText: String = "") {
            self.allergens = allergens
            self.otherText = otherText
        }

        var isEmpty: Bool { allergens.isEmpty && cleanedCustom.isEmpty }

        var cleanedCustom: [String] {
            otherText.split(separator: ",")
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.customLimit)) }
                .filter { !$0.isEmpty }
        }
    }

    /// Member id → their allergies, as entered on the one allergy screen.
    var answers: [UUID: Answer] = [:]
    /// Catalog dishes tapped in the dinner picker.
    private(set) var picked: Set<UUID> = []
    private(set) var errorMessage: String?

    func toggle(_ dish: CatalogDish) {
        if picked.contains(dish.id) { picked.remove(dish.id) } else { picked.insert(dish.id) }
    }

    func memberAllergies(members: [Member]) -> [MemberAllergies] {
        members.compactMap { member in
            guard let answer = answers[member.id], !answer.isEmpty else { return nil }
            return MemberAllergies(memberID: member.id, firstName: member.firstName,
                                   allergens: answer.allergens, customTexts: answer.cleanedCustom)
        }
    }

    /// Flagged, never hidden: a dish with an allergen shows a warning and stays selectable.
    func flags(for dish: CatalogDish, members: [Member]) -> [AllergyFlag] {
        AllergyMatcher.flags(ingredients: dish.ingredients, members: memberAllergies(members: members))
    }

    /// Records the household's consent once, then each member's allergies. Nothing to save, nothing asked.
    /// `consentVersion` is the wording the parent agreed to (the sample family logs its own, since nobody read it).
    func saveAllergies(householdID: UUID, client: HouseholdClient,
                       consentVersion: String = AllergyConsent.textVersion) async -> Bool {
        let toSave = answers.filter { !$0.value.isEmpty }
        guard !toSave.isEmpty else { return true }
        do {
            try await client.grantAllergyConsent(householdID, consentVersion)
            for (memberID, answer) in toSave.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                try await client.setAllergies(memberID, Allergen.allCases.filter(answer.allergens.contains),
                                              answer.cleanedCustom)
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "Couldn't save the allergies. Check your connection and try again.")
            return false
        }
    }
}

/// "Load a sample family" (for App Review and the curious): a small household with a kid's allergy, a handful of
/// starter dishes, and a planned week, so every screen has something on it.
enum SampleFamily {
    static let members: [MemberDraft] = [
        draft("Ben", avatar: "🐻", ageGroup: .adult, guardian: true),
        draft("Grace", avatar: "🌻", ageGroup: .adult, role: .planner),
        draft("Owen", avatar: "🦊", ageGroup: .kid),
        draft("Nora", avatar: "🐢", ageGroup: .kid)
    ]

    /// First name → allergens, so the flags show up.
    static let allergies: [String: [Allergen]] = ["Nora": [.milk]]

    /// Starter dishes by name (docs/starter-pack.md).
    static let dishes = [
        "Tacos", "Pasta with sauce and meatballs", "Homemade mac and cheese", "Chicken Alfredo", "Burgers",
        "Grilled chicken", "Sloppy joes", "Chili", "Quesadillas", "Tomato soup and grilled cheese"
    ]

    static func pick(from catalog: [CatalogDish]) -> [CatalogDish] {
        dishes.compactMap { name in catalog.first { $0.name == name } }
    }

    private static func draft(_ name: String, avatar: String, ageGroup: AgeGroup, guardian: Bool = false,
                              role: MemberRole = .member) -> MemberDraft {
        var draft = MemberDraft()
        draft.firstName = name
        draft.avatar = avatar
        draft.ageGroup = ageGroup
        draft.guardian = guardian
        draft.role = role
        return draft
    }
}
