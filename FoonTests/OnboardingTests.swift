import Foundation
import Synchronization
import Testing
@testable import Foon

struct OnboardingSettingsTests {
    @Test func householdsFromBeforeOnboardingCountAsOnboarded() throws {
        let settings = try JSONDecoder().decode(HouseholdSettings.self, from: Data("{}".utf8))
        #expect(settings.onboarded)
        #expect(!settings.samplePending)
        #expect(settings.planningDay == 7)
        #expect(settings.planningTime == "09:00")
        #expect(settings.notificationPreset == .balanced)
    }

    @Test func rhythmSettingsRoundTripThroughTheirKeys() throws {
        var settings = HouseholdSettings()
        settings.planningDay = 6
        settings.planningTime = "10:30"
        settings.notificationPreset = .light
        settings.onboarded = false
        let decoded = try JSONDecoder().decode(HouseholdSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(json.contains("\"planning_day\":6"))
        #expect(json.contains("\"notification_preset\":\"light\""))
    }

    @Test func aBadPresetFallsBackToBalanced() throws {
        let settings = try JSONDecoder().decode(HouseholdSettings.self,
                                                from: Data(#"{"notification_preset": "loud"}"#.utf8))
        #expect(settings.notificationPreset == .balanced)
    }
}

struct DinnerPickerTests {
    private let catalog = [
        CatalogDish.fixture(name: "Tacos", category: "Tex-Mex", popular: true, sortOrder: 8),
        CatalogDish.fixture(name: "Chili", category: "Tex-Mex", sortOrder: 13),
        CatalogDish.fixture(name: "Lasagna", category: "Pasta", sortOrder: 5),
        CatalogDish.fixture(name: "Spaghetti", category: "Pasta", popular: true, sortOrder: 1),
        CatalogDish.fixture(name: "Burgers", category: "Grill", popular: true, sortOrder: 15)
    ]

    @Test func popularComesFirstInCatalogOrder() {
        #expect(DinnerPicker.visible(catalog, tab: .popular, search: "", showAll: true).map(\.name)
            == ["Spaghetti", "Tacos", "Burgers"])
    }

    @Test func categoryTabsFollowTheCatalog() {
        #expect(DinnerPicker.tabs(catalog) == [.popular, .category("Pasta"), .category("Tex-Mex"), .category("Grill")])
        #expect(DinnerPicker.visible(catalog, tab: .category("Tex-Mex"), search: "", showAll: true).map(\.name)
            == ["Tacos", "Chili"])
    }

    @Test func searchCoversEverything() {
        #expect(DinnerPicker.visible(catalog, tab: .popular, search: "las", showAll: false).map(\.name) == ["Lasagna"])
    }

    @Test func showMoreRevealsTheRest() {
        let many = (0..<20).map { CatalogDish.fixture(name: "Dish \($0)", category: "Pasta", sortOrder: $0) }
        #expect(DinnerPicker.visible(many, tab: .category("Pasta"), search: "", showAll: false).count
            == DinnerPicker.firstPage)
        #expect(DinnerPicker.visible(many, tab: .category("Pasta"), search: "", showAll: true).count == 20)
    }
}

@MainActor
struct OnboardingAllergyTests {
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let owen = Member.fixture(firstName: "Owen", ageGroup: .kid)

    @Test func flaggedDishesAreWarnedButStaySelectable() {
        let model = OnboardingModel()
        model.answers[nora.id] = OnboardingModel.Answer(allergens: [.milk])
        let mac = CatalogDish.fixture(name: "Mac and cheese", ingredients: ["elbow macaroni", "cheddar cheese"])
        #expect(model.flags(for: mac, members: [nora, owen]).map(\.summary) == ["Contains milk (Nora)"])
        model.toggle(mac)
        #expect(model.picked.contains(mac.id))
    }

    @Test func savingAllergiesRecordsConsentOnceThenEachMember() async {
        let consents = Mutex<[String]>([])
        let saved = Mutex<[UUID: ([Allergen], [String])]>([:])
        let client = HouseholdClient.fake(
            grantAllergyConsent: { _, version in consents.withLock { $0.append(version) } },
            setAllergies: { member, allergens, custom in saved.withLock { $0[member] = (allergens, custom) } }
        )
        let model = OnboardingModel()
        model.answers[nora.id] = OnboardingModel.Answer(allergens: [.milk, .treeNuts], otherText: "kiwi,  ,")
        model.answers[owen.id] = OnboardingModel.Answer()
        #expect(await model.saveAllergies(householdID: Household.sample.id, client: client))
        #expect(consents.withLock { $0 } == [AllergyConsent.textVersion])
        let saves = saved.withLock { $0 }
        #expect(saves.keys.sorted { $0.uuidString < $1.uuidString } == [nora.id])
        #expect(saves[nora.id]?.0 == [.milk, .treeNuts])
        #expect(saves[nora.id]?.1 == ["kiwi"])
    }

    @Test func noAllergiesAtAllSavesNothing() async {
        let client = HouseholdClient.fake(
            grantAllergyConsent: { _, _ in Issue.record("no consent needed") },
            setAllergies: { _, _, _ in Issue.record("nothing to save") }
        )
        #expect(await OnboardingModel().saveAllergies(householdID: Household.sample.id, client: client))
    }

    @Test func aFailedSaveSaysSo() async {
        let client = HouseholdClient.fake(grantAllergyConsent: { _, _ in throw URLError(.notConnectedToInternet) })
        let model = OnboardingModel()
        model.answers[nora.id] = OnboardingModel.Answer(allergens: [.milk])
        #expect(!(await model.saveAllergies(householdID: Household.sample.id, client: client)))
        #expect(model.errorMessage != nil)
    }

    @Test func otherTextKeepsWhatWasTypedAndSplitsOnRead() {
        var answer = OnboardingModel.Answer(otherText: "kiwi, ")
        #expect(answer.otherText == "kiwi, ", "a trailing comma survives while typing")
        #expect(answer.cleanedCustom == ["kiwi"])
        answer.otherText = "kiwi, sesame seeds , " + String(repeating: "x", count: 80)
        #expect(answer.cleanedCustom == ["kiwi", "sesame seeds", String(repeating: "x", count: 60)])
    }

    @Test func theSampleFamilyLogsItsOwnConsentVersion() async {
        let versions = Mutex<[String]>([])
        let client = HouseholdClient.fake(grantAllergyConsent: { _, version in versions.withLock { $0.append(version) } })
        let model = OnboardingModel()
        model.answers[nora.id] = OnboardingModel.Answer(allergens: [.milk])
        #expect(await model.saveAllergies(householdID: Household.sample.id, client: client,
                                          consentVersion: AllergyConsent.sampleVersion))
        #expect(versions.withLock { $0 } == ["sample-family-v1"])
    }

    @Test func memberAllergiesForTheMatcherComeFromTheAnswers() {
        let model = OnboardingModel()
        model.answers[nora.id] = OnboardingModel.Answer(allergens: [.eggs], otherText: "kiwi")
        #expect(model.memberAllergies(members: [nora, owen])
            == [MemberAllergies(memberID: nora.id, firstName: "Nora", allergens: [.eggs], customTexts: ["kiwi"])])
    }
}

struct SampleFamilyTests {
    @Test func theSampleFamilyIsSmallButComplete() {
        #expect(SampleFamily.members.map(\.firstName) == ["Ben", "Grace", "Owen", "Nora"])
        #expect(SampleFamily.members.contains { $0.ageGroup == .kid })
        #expect(SampleFamily.allergies.keys.contains("Nora"))
        #expect(SampleFamily.dishes.count >= 8)
    }

    @Test func sampleDishesComeFromTheStarterPack() {
        let catalog = SampleFamily.dishes.map { CatalogDish.fixture(name: $0) }
            + [CatalogDish.fixture(name: "Something else")]
        #expect(SampleFamily.pick(from: catalog).count == SampleFamily.dishes.count)
    }
}

@MainActor
struct OnboardingHouseholdTests {
    private let me = UUID()

    @Test func aNewHouseholdStartsOnboardingInTheSameCall() async {
        let saved = Mutex<HouseholdSettings?>(nil)
        let created = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: me)
        let store = HouseholdStore(userID: me, client: .fake(
            createHousehold: { _, _, _, settings in
                saved.withLock { $0 = settings }
                return created
            },
            members: { _ in [Member.fixture(firstName: "Ann", guardian: true, role: .planner, userID: self.me)] },
            updateSettings: { _, _ in Issue.record("the flags go with the household, not after it") }
        ))
        await store.createHousehold(name: "The Smiths", emoji: nil, firstName: "Ann")
        #expect(saved.withLock { $0 }?.onboarded == false)
        #expect(saved.withLock { $0 }?.timeZone == TimeZone.current.identifier, "so the server knows when last night was")
        #expect(store.needsOnboarding)
    }

    @Test func aSampleFamilyIsMarkedToBeFilledIn() async {
        let saved = Mutex<HouseholdSettings?>(nil)
        let store = HouseholdStore(userID: me, client: .fake(
            createHousehold: { name, _, _, settings in
                saved.withLock { $0 = settings }
                return Household(id: UUID(), name: name, emoji: nil, owner: self.me)
            }
        ))
        await store.createHousehold(name: "The Sample family", emoji: "🧪", firstName: "Ann", sample: true)
        #expect(saved.withLock { $0 }?.samplePending == true)
        #expect(store.household?.planningSettings.samplePending == true)
        #expect(saved.withLock { $0 }?.isSample == true, "it stays a sample, so Family can offer to start the real one")
    }

    @Test func eachNotificationPresetSaysWhatItSends() {
        #expect(HouseholdSettings.NotificationPreset.light.summary.contains("Only what you'd hate to miss"))
        #expect(HouseholdSettings.NotificationPreset.balanced.summary.contains("check-in"))
        #expect(HouseholdSettings.NotificationPreset.engaged.summary.contains("Everything"))
        #expect(Set(HouseholdSettings.NotificationPreset.allCases.map(\.summary)).count == 3)
    }

    @Test func theSampleMarkIsKeptInSettings() throws {
        var settings = HouseholdSettings()
        settings.isSample = true
        let json = try JSONEncoder().encode(settings)
        #expect(String(decoding: json, as: UTF8.self).contains(#""sample":true"#))
        #expect(try JSONDecoder().decode(HouseholdSettings.self, from: json).isSample)
        #expect(try !JSONDecoder().decode(HouseholdSettings.self, from: Data("{}".utf8)).isSample)
    }

    @Test func finishingOnboardingSavesTheRhythm() async {
        var settings = HouseholdSettings()
        settings.onboarded = false
        let saved = Mutex<HouseholdSettings?>(nil)
        let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: me, settings: settings)
        let store = HouseholdStore(userID: me, client: .fake(
            myHousehold: { household },
            updateSettings: { _, settings in saved.withLock { $0 = settings } }
        ))
        await store.load()
        var rhythm = settings
        rhythm.dinnerTime = "17:30"
        #expect(await store.finishOnboarding(rhythm))
        #expect(saved.withLock { $0 }?.onboarded == true)
        #expect(saved.withLock { $0 }?.dinnerTime == "17:30")
        #expect(!store.needsOnboarding)
    }

    @Test func onlyTheOwnerIsShownOnboarding() async {
        var settings = HouseholdSettings()
        settings.onboarded = false
        let household = Household(id: UUID(), name: "The Smiths", emoji: nil, owner: UUID(), settings: settings)
        let store = HouseholdStore(userID: me, client: .fake(myHousehold: { household }))
        await store.load()
        #expect(!store.needsOnboarding, "someone who joined by invite skips the owner's setup")
    }
}
