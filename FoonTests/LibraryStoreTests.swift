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

    @Test func offersDeleteOnlyForWhatTheServerSaysIsUnused() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let chili = LibraryMeal.fixture(name: "Chili")
        var client = LibraryClient.fake(meals: { _ in [tacos, chili] })
        client.unusedMeals = { _ in [tacos.id] }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        #expect(store.canDelete(tacos))
        #expect(!store.canDelete(chili))
    }

    @Test func aFailedReadOfWhatsUnusedKeepsWhatWasOffered() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let reads = Mutex(0)
        var client = LibraryClient.fake(meals: { _ in [tacos] })
        client.unusedMeals = { _ in
            let read = reads.withLock { $0 += 1; return $0 }
            if read > 1 { throw URLError(.notConnectedToInternet) }
            return [tacos.id]
        }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        await store.load(members: [])
        #expect(store.canDelete(tacos))
        #expect(store.errorMessage == nil)
    }

    @Test func deletingRemovesTheDishAndItsPhoto() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let removed = Mutex<[String]>([])
        var client = LibraryClient.fake(meals: { _ in [tacos] })
        client.unusedMeals = { _ in [tacos.id] }
        client.deleteUnused = { id in
            #expect(id == tacos.id)
            return "household/meals/tacos.jpg"
        }
        client.removePhoto = { path in removed.withLock { $0.append(path) } }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        #expect(await store.delete(tacos))
        #expect(store.visibleEntries.isEmpty)
        #expect(!store.canDelete(tacos))
        await store.deleteCleanup?.value
        #expect(removed.withLock { $0 } == ["household/meals/tacos.jpg"])
    }

    @Test func aSlowPhotoRemovalDoesntHoldUpTheDelete() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let gate = AsyncStream<Void>.makeStream()
        var client = LibraryClient.fake(meals: { _ in [tacos] })
        client.deleteUnused = { _ in "household/meals/tacos.jpg" }
        client.removePhoto = { _ in for await _ in gate.stream { break } }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        #expect(await store.delete(tacos), "returns with the photo still going")
        gate.continuation.yield()
        await store.deleteCleanup?.value
    }

    @Test func aReadFromBeforeTheDeleteDoesntBringTheDishBack() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let gate = AsyncStream<Void>.makeStream()
        let deleted = Mutex(false), holding = Mutex(false), held = Mutex(false)
        var client = LibraryClient.fake(meals: { _ in
            let snapshot = deleted.withLock { $0 } ? [] : [tacos]
            if holding.withLock({ $0 }) {
                held.withLock { $0 = true }
                holding.withLock { $0 = false }
                for await _ in gate.stream { break }
            }
            return snapshot
        })
        client.deleteUnused = { _ in
            deleted.withLock { $0 = true }
            return "household/meals/tacos.jpg"
        }
        // The old read lands while the photo is going, the moment nothing else is out to notice it.
        let landed = AsyncStream<Void>.makeStream()
        client.removePhoto = { _ in
            gate.continuation.yield()
            for await _ in landed.stream { break }
        }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        holding.withLock { $0 = true }
        async let stale: Void = store.refreshReactions(members: [])
        while !held.withLock({ $0 }) { await Task.yield() }
        async let deleting = store.delete(tacos)
        await stale
        landed.continuation.yield()
        #expect(await deleting)
        await store.deleteCleanup?.value
        #expect(store.meals.isEmpty)
    }

    @Test func aDishPlannedAfterLoadingIsNoLongerOffered() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let planned = Mutex(false)
        var client = LibraryClient.fake(meals: { _ in [tacos] })
        client.unusedMeals = { _ in planned.withLock { $0 } ? [] : [tacos.id] }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        #expect(store.canDelete(tacos))
        planned.withLock { $0 = true }
        await store.refreshUnused()
        #expect(!store.canDelete(tacos))
    }

    @Test(arguments: [
        ("P0002", "isn't in your library"),
        ("42501", "Only planners")
    ])
    func aRefusedDeleteSaysWhyAndReadsAgain(code: String, words: String) async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let reads = Mutex(0)
        var client = LibraryClient.fake(meals: { _ in [tacos] })
        client.unusedMeals = { _ in
            reads.withLock { $0 += 1; return $0 } == 1 ? [tacos.id] : []
        }
        client.deleteUnused = { _ in throw PostgrestError(code: code, message: "refused") }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        #expect(await !store.delete(tacos))
        #expect(!store.canDelete(tacos))
        #expect(store.errorMessage?.contains(words) == true)
        #expect(store.errorMessage?.contains("connection") == false)
    }

    @Test func aPhotoThatWontGoDoesntUndoTheDelete() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        var client = LibraryClient.fake(meals: { _ in [tacos] })
        client.deleteUnused = { _ in "household/meals/tacos.jpg" }
        client.removePhoto = { _ in throw URLError(.notConnectedToInternet) }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        #expect(await store.delete(tacos))
        #expect(store.visibleEntries.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func aDishPlannedOnAnotherPhoneIsRefusedAndNoLongerOffered() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        let reads = Mutex(0)
        let removed = Mutex(0)
        var client = LibraryClient.fake(meals: { _ in [tacos] })
        client.unusedMeals = { _ in
            reads.withLock { $0 += 1; return $0 } == 1 ? [tacos.id] : []
        }
        client.deleteUnused = { _ in throw LibraryClientError.inUse }
        client.removePhoto = { _ in removed.withLock { $0 += 1 } }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        #expect(await !store.delete(tacos))
        #expect(store.visibleEntries.map(\.meal.name) == ["Tacos"])
        #expect(!store.canDelete(tacos))
        #expect(store.errorMessage?.contains("in use") == true)
        #expect(removed.withLock { $0 } == 0)
    }

    @Test func aFailedDeleteKeepsTheDishAndSaysSo() async {
        let tacos = LibraryMeal.fixture(name: "Tacos")
        var client = LibraryClient.fake(meals: { _ in [tacos] })
        client.unusedMeals = { _ in [tacos.id] }
        client.deleteUnused = { _ in throw URLError(.notConnectedToInternet) }
        let store = LibraryStore(householdID: household, client: client)
        await store.load(members: [])
        #expect(await !store.delete(tacos))
        #expect(store.visibleEntries.map(\.meal.name) == ["Tacos"])
        #expect(store.canDelete(tacos))
        #expect(store.errorMessage?.contains("Check your connection") == true)
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

    @Test func archivedAndRetiredMealsCanComeBackIntoRotation() {
        #expect(LibraryStore.canRestore(.fixture(status: .archived)))
        #expect(LibraryStore.canRestore(.fixture(status: .retired)), "a planner can bring back what the family voted out")
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
        create: @escaping @Sendable (UUID, MealDraft.Saved) async throws -> UUID = { _, _ in UUID() },
        itemNames: @escaping @Sendable (UUID) async throws -> [String] = { _ in [] },
        setPhoto: @escaping @Sendable (LibraryMeal, Data) async throws -> Void = { _, _ in },
        importRecipe: @escaping @Sendable (String) async throws -> RecipeImport = { _ in
            throw RecipeImportError.unavailable
        }
    ) -> LibraryClient {
        LibraryClient(meals: meals, history: history, catalog: catalog, allergies: allergies, setStatus: setStatus,
                      addFromCatalog: addFromCatalog, photoURL: photoURL, save: save, copy: copy, create: create,
                      itemNames: itemNames, setPhoto: setPhoto, importRecipe: importRecipe)
    }
}

struct RowPagesTests {
    private func read(_ total: Int, size: Int, serverCap: Int = .max) async throws -> (rows: [UUID], asked: [UUID?]) {
        let ids = (0..<total).map { _ in UUID() }
        var asked: [UUID?] = []
        let rows = try await RowPages.all(size: size, key: { $0 }, page: { after, size in
            asked.append(after)
            let start = after.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            return Array(ids[start...].prefix(min(size, serverCap)))
        })
        #expect(rows == ids, "every row, in order, once")
        return (rows, asked)
    }

    @Test func anEmptyListAsksOnce() async throws {
        #expect(try await read(0, size: 5).asked == [nil])
    }

    @Test func aLongListKeepsReadingFromTheLastRow() async throws {
        let read = try await read(12, size: 5)
        #expect(read.asked == [nil, read.rows[4], read.rows[9], read.rows[11]])
    }

    @Test func aServerCapBelowThePageSizeLosesNothing() async throws {
        #expect(try await read(12, size: 5, serverCap: 2).rows.count == 12)
    }

    @Test func aListThatEndsOnAPageBoundaryStillEnds() async throws {
        #expect(try await read(10, size: 5).asked.count == 3)
    }

    /// Verdicts page on two columns: one person's rows can straddle a page, and the next person's still come.
    @Test func aKeyOfTwoColumnsReadsEveryRow() async throws {
        struct Row: Equatable { let member: Int, meal: Int }
        let rows = (0..<3).flatMap { member in (0..<4).map { Row(member: member, meal: $0) } }
        let read = try await RowPages.all(size: 5, key: { (row: Row) in row }, page: { after, size in
            Array(rows.drop { row in
                guard let after else { return false }
                return row.member < after.member || (row.member == after.member && row.meal <= after.meal)
            }.prefix(size))
        })
        #expect(read == rows)
    }

    @Test func aFailedPageFailsTheRead() async {
        struct Failed: Error {}
        await #expect(throws: Failed.self) {
            _ = try await RowPages.all(size: 2, key: { $0 }, page: { after, _ -> [UUID] in
                guard after == nil else { throw Failed() }
                return [UUID(), UUID()]
            })
        }
    }
}

/// Entries are kept until an input changes, so each input has to change what the grid shows.
@MainActor
struct LibraryEntriesKeepUpTests {
    final class Server: @unchecked Sendable {
        var meals: [LibraryMeal] = []
        var allergies: [AllergyRow] = []
        var history: [MealHistory] = []
        var verdicts: [MealVerdict] = []
    }

    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let mac = LibraryMeal.fixture(name: "Mac", ingredients: ["pasta"])
    private let server = Server()

    private func loaded() async -> LibraryStore {
        let server = server
        var client = LibraryClient.fake(meals: { _ in server.meals }, history: { _ in server.history },
                                        allergies: { _ in server.allergies })
        client.verdicts = { _ in server.verdicts }
        let store = LibraryStore(householdID: Household.sample.id, client: client)
        server.meals = [mac]
        await store.load(members: [nora])
        return store
    }

    private func tile(_ store: LibraryStore, _ meal: LibraryMeal) -> LibraryEntry? {
        store.visibleEntries.first { $0.meal.id == meal.id }
    }

    @Test func aNewAllergyFlagsATileAlreadyRead() async {
        let store = await loaded()
        var milky = mac
        milky.ingredients = LibraryMeal.fixture(ingredients: ["milk"]).ingredients
        server.meals = [milky]
        await store.load(members: [nora])
        #expect(tile(store, mac)?.flags.isEmpty == true, "read once with no allergies")

        server.allergies = [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)]
        await store.load(members: [nora])
        #expect(tile(store, mac)?.flags.count == 1)
    }

    @Test func aRemovedAllergyClearsTheFlag() async {
        let milky = LibraryMeal.fixture(name: "Mac", ingredients: ["milk"])
        server.allergies = [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)]
        let store = await loaded()
        server.meals = [milky]
        await store.load(members: [nora])
        #expect(tile(store, milky)?.flags.count == 1)

        server.allergies = []
        await store.load(members: [nora])
        #expect(tile(store, milky)?.flags.isEmpty == true)
    }

    @Test func aSideGettingAnIngredientFlagsTheDishItGoesWith() async {
        server.allergies = [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)]
        let store = await loaded()
        let bread = LibraryMeal.fixture(name: "Cornbread", ingredients: ["cornmeal"])
        var withBread = mac
        withBread.sides = [.meal(bread.id)]
        server.meals = [withBread, bread]
        await store.load(members: [nora])
        #expect(tile(store, withBread)?.flags.isEmpty == true)

        var milkyBread = bread
        milkyBread.ingredients = LibraryMeal.fixture(ingredients: ["milk"]).ingredients
        server.meals = [withBread, milkyBread]
        await store.load(members: [nora])
        #expect(tile(store, withBread)?.flags.count == 1, "the dish itself didn't change, only its side")
    }

    @Test func historyAndVerdictsReachTheTile() async {
        let store = await loaded()
        #expect(tile(store, mac)?.history == nil)
        #expect(tile(store, mac)?.isFavorite == false)

        server.history = [MealHistory(mealID: mac.id, timesMade: 2, lastMade: CalendarDay(year: 2037, month: 1, day: 1))]
        server.verdicts = [MealVerdict(mealID: mac.id, memberID: nora.id, kind: .favorite,
                                       reactedOn: CalendarDay(year: 2037, month: 1, day: 1))]
        await store.load(members: [nora])
        #expect(tile(store, mac)?.history?.timesMade == 2)
        #expect(tile(store, mac)?.isFavorite == true)
    }

    @Test func aLastUncheckedDishLeavesTheCount() async {
        server.allergies = [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)]
        let store = await loaded()
        let bare = LibraryMeal.fixture(name: "Chili")
        server.meals = [bare]
        await store.load(members: [nora])
        #expect(store.uncheckedCount == 1)

        var filled = bare
        filled.ingredients = LibraryMeal.fixture(ingredients: ["beans"]).ingredients
        server.meals = [filled]
        await store.load(members: [nora])
        #expect(store.uncheckedCount == 0)
    }

    /// A kept answer must still tell SwiftUI what it depends on, or a screen wouldn't redraw on the next change.
    @Test func aReadAnsweredFromWhatsKeptStillRedrawsOnAChange() async {
        let store = await loaded()
        _ = store.visibleEntries
        final class Fired: @unchecked Sendable { var value = false }
        let fired = Fired()
        withObservationTracking { _ = store.visibleEntries } onChange: { fired.value = true }

        server.allergies = [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)]
        await store.load(members: [nora])
        #expect(fired.value)
    }
}
