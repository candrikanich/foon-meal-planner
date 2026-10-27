import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

@MainActor
struct LibraryStoreTests {
    private let household = Household.sample.id

    @Test func loadsTheLibraryWithHistoryAndAllergyFlags() async {
        let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let mac = LibraryMeal.fixture(name: "Mac and cheese", ingredients: ["milk", "elbow macaroni"])
        let history = MealHistory(mealID: mac.id, timesMade: 2, lastMade: CalendarDay(year: 2026, month: 10, day: 1))
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [mac] },
            history: { _ in [history] },
            allergies: { _ in [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)] }
        ))
        await store.load(members: [nora])
        #expect(store.visibleEntries.map(\.meal.name) == ["Mac and cheese"])
        #expect(store.visibleEntries[0].history == history)
        #expect(store.visibleEntries[0].flags.map(\.summary) == ["Contains milk (Nora)"])
        #expect(store.errorMessage == nil)
    }

    @Test func allergiesGroupByMemberAndSkipRemovedMembers() {
        let nora = Member.fixture(firstName: "Nora")
        let rita = Member.fixture(firstName: "Rita", status: .removed)
        let rows = [
            AllergyRow(memberID: nora.id, allergen: .milk, customText: nil),
            AllergyRow(memberID: nora.id, allergen: .custom, customText: "kiwi"),
            AllergyRow(memberID: rita.id, allergen: .peanuts, customText: nil)
        ]
        let allergies = LibraryStore.memberAllergies(rows, members: [nora, rita])
        #expect(allergies == [MemberAllergies(memberID: nora.id, firstName: "Nora", allergens: [.milk],
                                              customTexts: ["kiwi"])])
    }

    @Test func aFailedLoadSaysSoAndKeepsWhatWasShown() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let fail = Mutex(false)
        let store = LibraryStore(householdID: household, client: .fake(meals: { _ in
            if fail.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return [tacos]
        }))
        await store.load(members: [])
        fail.withLock { $0 = true }
        await store.load(members: [])
        #expect(store.visibleEntries.map(\.meal.name) == ["Tacos"])
        #expect(store.errorMessage != nil)
    }

    @Test func archivingMovesAMealOutOfRotation() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let calls = Mutex<[MealStatus]>([])
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [tacos] },
            setStatus: { id, status in
                #expect(id == tacos.id)
                calls.withLock { $0.append(status) }
            }
        ))
        await store.load(members: [])
        await store.setArchived(true, mealID: tacos.id)
        #expect(store.visibleEntries.isEmpty)
        store.filter = .archived
        #expect(store.visibleEntries.map(\.meal.name) == ["Tacos"])
        await store.setArchived(false, mealID: tacos.id)
        #expect(store.visibleEntries.isEmpty)
        #expect(calls.withLock { $0 } == [.archived, .active])
    }

    @Test func aFailedArchiveLeavesTheMealWhereItWas() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [tacos] },
            setStatus: { _, _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.load(members: [])
        await store.setArchived(true, mealID: tacos.id)
        #expect(store.visibleEntries.map(\.meal.name) == ["Tacos"])
        #expect(store.errorMessage != nil)
    }

    @Test func archivingSurvivesTheLibraryReloadingMeanwhile() async {
        let tacos = LibraryMeal.fixture(name: "Tacos"), chili = LibraryMeal.fixture(name: "Chili")
        let gate = AsyncStream<Void>.makeStream()
        let shrunk = Mutex(false), archiving = Mutex(false)
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in shrunk.withLock { $0 } ? [chili] : [tacos, chili] },
            setStatus: { _, _ in
                archiving.withLock { $0 = true }
                for await _ in gate.stream { break }
            }
        ))
        await store.load(members: [])
        async let archive: Void = store.setArchived(true, mealID: chili.id)
        while !archiving.withLock({ $0 }) { await Task.yield() }
        shrunk.withLock { $0 = true }
        await store.load(members: [])
        gate.continuation.yield()
        await archive
        #expect(store.meals.map(\.name) == ["Chili"])
        #expect(store.meals.first?.status == .archived)
    }

    @Test func onlyArchivedMealsComeBackIntoRotation() {
        #expect(LibraryStore.canRestore(.fixture(status: .archived)))
        #expect(!LibraryStore.canRestore(.fixture(status: .retired)), "the dislike rule retired it")
        #expect(!LibraryStore.canRestore(.fixture(status: .active)))
    }

    @Test func aCancelledLoadIsNotAnError() async {
        let store = LibraryStore(householdID: household, client: .fake(meals: { _ in throw CancellationError() }))
        await store.load(members: [])
        #expect(store.errorMessage == nil)
        let cancelledRequest = LibraryStore(householdID: household,
                                            client: .fake(meals: { _ in throw URLError(.cancelled) }))
        await cancelledRequest.load(members: [])
        #expect(cancelledRequest.errorMessage == nil)
    }

    @Test func onlyTheLatestLoadLandsAndClearsTheSpinner() async {
        let gate = AsyncStream<Void>.makeStream()
        let calls = Mutex(0)
        let first = LibraryMeal.fixture(name: "Stale"), second = LibraryMeal.fixture(name: "Fresh")
        let store = LibraryStore(householdID: household, client: .fake(meals: { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 {
                for await _ in gate.stream { break }
                return [first]
            }
            return [second]
        }))
        async let slow: Void = store.load(members: [])
        while calls.withLock({ $0 }) == 0 { await Task.yield() }
        await store.load(members: [])
        #expect(!store.isLoading)
        gate.continuation.yield()
        await slow
        #expect(store.meals.map(\.name) == ["Fresh"], "the slower, older load doesn't overwrite the newer one")
        #expect(!store.isLoading)
    }

    @Test func addingACatalogDishReloadsTheLibrary() async {
        let dish = CatalogDish.fixture(name: "Chili")
        let copy = LibraryMeal.fixture(name: "Chili", catalogMealID: dish.id)
        let added = Mutex(false)
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in added.withLock { $0 } ? [copy] : [] },
            catalog: { [dish] },
            addFromCatalog: { householdID, dishID in
                #expect(householdID == household)
                #expect(dishID == dish.id)
                added.withLock { $0 = true }
                return copy.id
            }
        ))
        await store.load(members: [])
        #expect(!store.isInLibrary(dish))
        #expect(await store.add(dish) == copy.id)
        #expect(store.isInLibrary(dish))
        #expect(store.visibleEntries.map(\.meal.name) == ["Chili"])
    }

    @Test func searchShowsMatchingCatalogDishesBelowTheFamilysOwn() async {
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [.fixture(name: "Our tacos")] },
            catalog: { [.fixture(name: "Fish tacos"), .fixture(name: "Chili")] }
        ))
        await store.load(members: [])
        store.search = "tacos"
        #expect(store.visibleEntries.map(\.meal.name) == ["Our tacos"])
        #expect(store.catalogMatches.map(\.name) == ["Fish tacos"])
    }

    @Test func savingSendsTheValidatedMealAndReloads() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let saved = Mutex<MealDraft.Saved?>(nil)
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [saved.withLock { $0 }.map { LibraryMeal.fixture(id: tacos.id, name: $0.name) } ?? tacos] },
            save: { id, meal in
                #expect(id == tacos.id)
                saved.withLock { $0 = meal }
            }
        ))
        await store.load(members: [])
        var draft = MealDraft(tacos)
        draft.name = "  Our tacos "
        #expect(await store.save(draft, mealID: tacos.id))
        #expect(saved.withLock { $0 }?.name == "Our tacos")
        #expect(store.meals.first?.name == "Our tacos")
    }

    @Test func anInvalidDraftNeverReachesTheServer() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [tacos] },
            save: { _, _ in Issue.record("should not be called") }
        ))
        await store.load(members: [])
        var draft = MealDraft(tacos)
        draft.name = ""
        #expect(!(await store.save(draft, mealID: tacos.id)))
        #expect(store.errorMessage == MealDraft.Problem.nameMissing.message)
    }

    @Test func aFailedSaveSaysSo() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [tacos] },
            save: { _, _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.load(members: [])
        #expect(!(await store.save(MealDraft(tacos), mealID: tacos.id)))
        #expect(store.errorMessage != nil)
    }

    @Test func copyAndTweakMakesANamedCopy() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let copyID = UUID()
        let copied = Mutex(false)
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in copied.withLock { $0 } ? [tacos, .fixture(id: copyID, name: "Tacos (copy)")] : [tacos] },
            copy: { id, name in
                #expect(id == tacos.id)
                #expect(name == "Tacos (copy)")
                copied.withLock { $0 = true }
                return copyID
            }
        ))
        await store.load(members: [])
        #expect(await store.copy(tacos) == copyID)
        #expect(store.meal(copyID)?.name == "Tacos (copy)")
    }

    @Test func copyingTwiceAtOnceMakesOneCopy() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let gate = AsyncStream<Void>.makeStream()
        let copies = Mutex(0)
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [tacos] },
            copy: { _, _ in
                copies.withLock { $0 += 1 }
                for await _ in gate.stream { break }
                return UUID()
            }
        ))
        await store.load(members: [])
        async let first = store.copy(tacos)
        while copies.withLock({ $0 }) == 0 { await Task.yield() }
        #expect(store.isCopying(tacos))
        #expect(await store.copy(tacos) == nil)
        gate.continuation.yield()
        _ = await first
        #expect(copies.withLock { $0 } == 1)
        #expect(!store.isCopying(tacos))
    }

    @Test func aCopyThatDoesNotShowUpSaysSo() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let store = LibraryStore(householdID: household, client: .fake(meals: { _ in [tacos] }))
        await store.load(members: [])
        #expect(await store.copy(tacos) == nil)
        #expect(store.errorMessage != nil)
    }

    @Test func retiredMealsAreNotCopied() {
        #expect(LibraryStore.canCopy(.fixture(status: .active)))
        #expect(LibraryStore.canCopy(.fixture(status: .archived)))
        #expect(!LibraryStore.canCopy(.fixture(status: .retired)))
    }

    @Test(arguments: [
        ("42501", "You can't change this meal. Only planners can."),
        ("P0002", "That meal isn't in your library anymore. Pull to refresh.")
    ])
    func serverRefusalsAreNotBlamedOnTheConnection(code: String, message: String) async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [tacos] },
            save: { _, _ in throw PostgrestError(code: code, message: "refused") }
        ))
        await store.load(members: [])
        #expect(!(await store.save(MealDraft(tacos), mealID: tacos.id)))
        #expect(store.errorMessage == message)
    }

    @Test func aPickedPhotoThatWontOpenSaysSo() async {
        let store = LibraryStore(householdID: household, client: .fake())
        store.reportPhotoLoadFailure()
        #expect(store.errorMessage == "Couldn't open that photo. Try another one.")
    }

    @Test func aPhotoThatIsNotAnImageIsRefusedBeforeUpload() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let store = LibraryStore(householdID: household, client: .fake(
            meals: { _ in [tacos] },
            setPhoto: { _, _ in Issue.record("should not upload") }
        ))
        await store.load(members: [])
        #expect(!(await store.setPhoto(Data("not a picture".utf8), for: tacos)))
        #expect(store.errorMessage != nil)
    }

    @Test func autocompleteDrawsOnEveryIngredientInTheLibrary() async {
        let store = LibraryStore(householdID: household, client: .fake(meals: { _ in [
            .fixture(name: "Tacos", ingredients: ["ground beef", "taco shells"]),
            .fixture(name: "Chili", ingredients: ["ground beef", "kidney beans"])
        ] }))
        await store.load(members: [])
        #expect(store.ingredientNames.sorted() == ["ground beef", "kidney beans", "taco shells"])
    }

    @Test func onlyPlannersChangeTheLibrary() {
        let ann = Member.fixture(firstName: "Ann", role: .planner, userID: UUID())
        let nora = Member.fixture(firstName: "Nora", ageGroup: .kid, userID: UUID())
        #expect(LibraryStore.canEdit(me: ann, isOwner: false))
        #expect(!LibraryStore.canEdit(me: nora, isOwner: false))
        #expect(LibraryStore.canEdit(me: nil, isOwner: true))
    }
}

extension LibraryClient {
    static func fake(
        meals: @escaping @Sendable (UUID) async throws -> [LibraryMeal] = { _ in [] },
        history: @escaping @Sendable (UUID) async throws -> [MealHistory] = { _ in [] },
        catalog: @escaping @Sendable () async throws -> [CatalogDish] = { [] },
        allergies: @escaping @Sendable (UUID) async throws -> [AllergyRow] = { _ in [] },
        setStatus: @escaping @Sendable (UUID, MealStatus) async throws -> Void = { _, _ in },
        addFromCatalog: @escaping @Sendable (UUID, UUID) async throws -> UUID = { _, _ in UUID() },
        photoURL: @escaping @Sendable (String) async throws -> URL = { _ in throw URLError(.fileDoesNotExist) },
        save: @escaping @Sendable (UUID, MealDraft.Saved) async throws -> Void = { _, _ in },
        copy: @escaping @Sendable (UUID, String) async throws -> UUID = { _, _ in UUID() },
        setPhoto: @escaping @Sendable (LibraryMeal, Data) async throws -> Void = { _, _ in }
    ) -> LibraryClient {
        LibraryClient(meals: meals, history: history, catalog: catalog, allergies: allergies, setStatus: setStatus,
                      addFromCatalog: addFromCatalog, photoURL: photoURL, save: save, copy: copy, setPhoto: setPhoto)
    }
}
