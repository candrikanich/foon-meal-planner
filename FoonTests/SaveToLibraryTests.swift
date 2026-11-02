import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

private let link = URL(string: "https://recipes.example/chili")!

struct LibrarySaveRouteTests {
    private let asker = UUID()

    @Test func anIdeaWithALinkIsReadFirstWithItsOwnName() {
        let idea = DinnerRequest(requestedByMemberID: asker, title: "Grandma's chili", link: link)
        #expect(RequestBoard.librarySave(idea, made: nil) == .read(IdeaLink(url: link, name: "Grandma's chili")))
    }

    @Test func aLinkWithNoNameLeavesTheNameToThePage() {
        let idea = DinnerRequest(requestedByMemberID: asker, link: link)
        #expect(RequestBoard.librarySave(idea, made: nil) == .read(IdeaLink(url: link, name: nil)))
        let blank = DinnerRequest(requestedByMemberID: asker, title: "  ", link: link)
        #expect(RequestBoard.librarySave(blank, made: nil) == .read(IdeaLink(url: link, name: nil)))
    }

    @Test func aNameOnlyIdeaIsMadeAsToday() {
        let idea = DinnerRequest(requestedByMemberID: asker, title: "Crab legs")
        guard case .make(let draft) = RequestBoard.librarySave(idea, made: nil) else {
            Issue.record("should make it from the name")
            return
        }
        #expect(draft.name == "Crab legs")
        #expect(draft.link.isEmpty)
        #expect(draft.lines.isEmpty)
    }

    @Test func aRetryLinksTheDishAlreadyMadeRatherThanReadingAgain() {
        let dish = UUID()
        let withLink = DinnerRequest(requestedByMemberID: asker, title: "Chili", link: link)
        let nameOnly = DinnerRequest(requestedByMemberID: asker, title: "Crab legs")
        #expect(RequestBoard.librarySave(withLink, made: dish) == .link(dish))
        #expect(RequestBoard.librarySave(nameOnly, made: dish) == .link(dish))
    }

    @Test func aLinkThatIsntAWebAddressIsntReadAndTheSaveIsRefused() throws {
        let odd = try #require(URL(string: "ftp://recipes.example/chili"))
        let idea = DinnerRequest(requestedByMemberID: asker, title: "Chili", link: odd)
        guard case .make(let draft) = RequestBoard.librarySave(idea, made: nil) else {
            Issue.record("there's nothing to read")
            return
        }
        #expect(draft.name == "Chili")
        #expect(draft.link == odd.absoluteString)
        #expect(throws: MealDraft.Problem.badLink) { try draft.validated() }
    }
}

struct IdeaDraftTests {
    private let recipe = RecipeImport.Recipe(name: "Best Ever Chili", servings: 4, ingredients: ["1 lb ground beef"],
                                             steps: ["Simmer."], imageURL: nil)

    @Test func aReadRecipeKeepsTheIdeasNameAndEverythingItRead() throws {
        let draft = RecipeImport(recipe: recipe, title: "Best Ever Chili | Blog", url: link)
            .draft(householdSize: 8, named: "Grandma's chili")
        #expect(draft.name == "Grandma's chili")
        #expect(draft.servings == 8)
        #expect(draft.lines.map(\.name) == ["ground beef"])
        #expect(draft.lines.map(\.quantity) == ["2 lb"], "scaled, as a link from the library is")
        #expect(draft.stepsText == "Simmer.")
        #expect(draft.link == link.absoluteString)
        _ = try draft.validated()
    }

    @Test func noNameFallsBackToTheRecipeThenThePage() {
        #expect(RecipeImport(recipe: recipe, title: "Blog", url: link).draft(householdSize: 4).name == "Best Ever Chili")
        #expect(RecipeImport(recipe: nil, title: "Blog", url: link).draft(householdSize: 4).name == "Blog")
    }

    @Test func noRecipeOnThePageSavesTheIdeasNameAndLink() throws {
        let draft = RecipeImport(recipe: nil, title: "Some blog", url: link).draft(householdSize: 4, named: "Chili")
        #expect(draft.name == "Chili")
        #expect(draft.link == link.absoluteString)
        #expect(draft.lines.isEmpty)
        _ = try draft.validated()
    }

    @Test func savingJustTheLinkKeepsTheIdeasName() {
        let linkOnly = RecipeImport(recipe: nil, title: nil, url: link)
        #expect(linkOnly.draft(householdSize: 4, named: "Chili").name == "Chili")
        #expect(linkOnly.draft(householdSize: 4).name == "recipes.example", "the library's own path has no name to keep")
    }

    @Test func aLongNameStillFitsAMeal() throws {
        let long = String(repeating: "c", count: 200)
        let draft = RecipeImport(recipe: nil, title: nil, url: link).draft(householdSize: 4, named: long)
        #expect(draft.name.count == 80)
        _ = try draft.validated()
    }

    @Test func thePreviewSaysWhyThereAreNoIngredients() throws {
        let linkOnly = RecipeImport(recipe: nil, title: nil, url: link)
        let couldnt = try #require(linkOnly.noIngredientsNote(lineCount: 0, couldntRead: true))
        #expect(couldnt.contains("couldn't read"))
        #expect(!couldnt.contains("No recipe card"), "it never saw the page, so it can't say that")
        let noCard = try #require(linkOnly.noIngredientsNote(lineCount: 0, couldntRead: false))
        #expect(noCard.contains("No recipe card"))
        let empty = RecipeImport(recipe: .init(name: "Chili", servings: 4, ingredients: [], steps: [], imageURL: nil),
                                 title: nil, url: link)
        let noLines = try #require(empty.noIngredientsNote(lineCount: 0, couldntRead: false))
        #expect(noLines.contains("no ingredients"))
        #expect(RecipeImport(recipe: recipe, title: nil, url: link).noIngredientsNote(lineCount: 1, couldntRead: false) == nil)
    }
}

@MainActor
struct IdeaDishLinkTests {
    /// Every link sent, the first `failures` of them failing.
    private final class Server: Sendable {
        let linked = Mutex<[UUID?]>([])
        let failuresLeft: Mutex<Int>

        init(failures: Int) { failuresLeft = Mutex(failures) }

        @MainActor func ideas() -> IdeasStore {
            IdeasStore(householdID: UUID(), client: IdeasClient(
                requests: { _ in [] }, make: { _, _ in UUID() }, toggleMeToo: { _, _ in true },
                update: { [self] _, update in
                    linked.withLock { $0.append(update.linkMealID) }
                    let fails = failuresLeft.withLock { left in
                        defer { left -= 1 }
                        return left > 0
                    }
                    if fails { throw URLError(.notConnectedToInternet) }
                }
            ))
        }
    }

    @Test func aLinkThatWorksForgetsTheDish() async {
        let server = Server(failures: 0)
        let ideas = server.ideas()
        let idea = UUID(), dish = UUID()
        #expect(await ideas.linkDish(dish, to: idea))
        #expect(server.linked.withLock { $0 } == [dish])
        #expect(ideas.madeDishes[idea] == nil)
    }

    @Test func aFailedLinkRemembersTheDish() async {
        let ideas = Server(failures: 1).ideas()
        let idea = UUID(), dish = UUID()
        #expect(!(await ideas.linkDish(dish, to: idea)))
        #expect(ideas.madeDishes[idea] == dish)
        #expect(ideas.errorMessage != nil)
    }

    @Test func aDishMadeInTheSheetIsRememberedBeforeAnythingIsLinked() {
        let ideas = Server(failures: 0).ideas()
        let idea = UUID(), dish = UUID()
        ideas.rememberDish(dish, for: idea)
        #expect(ideas.madeDishes[idea] == dish)
        #expect(ideas.madeDishes[UUID()] == nil, "only that idea")
    }

    /// The whole of what the button does, by the route it's given: two failures, then a link, one dish.
    @Test(arguments: [DinnerRequest(requestedByMemberID: UUID(), title: "Crab legs"),
                      DinnerRequest(requestedByMemberID: UUID(), title: "Chili", link: link)])
    func retriesMakeOneDishAndLinkItOnce(idea: DinnerRequest) async {
        let server = Server(failures: 2)
        let ideas = server.ideas()
        var dishesMade: [UUID] = []
        var linked = false
        func makeDish() -> UUID {
            dishesMade.append(UUID())
            return dishesMade[dishesMade.count - 1]
        }
        for _ in 0..<3 {
            switch RequestBoard.librarySave(idea, made: ideas.madeDishes[idea.id]) {
            case .link(let dish): linked = await ideas.linkDish(dish, to: idea.id)
            case .make: linked = await ideas.linkDish(makeDish(), to: idea.id)
            case .read:
                // Add in the sheet makes the dish, and closing the sheet links it.
                let dish = makeDish()
                ideas.rememberDish(dish, for: idea.id)
                linked = await ideas.linkDish(dish, to: idea.id)
            }
        }
        #expect(linked)
        #expect(dishesMade.count == 1)
        #expect(server.linked.withLock { $0 } == [dishesMade[0], dishesMade[0], dishesMade[0]])
        #expect(ideas.madeDishes[idea.id] == nil)
    }

    @Test func aRefusedLinkDoesntBlameTheConnection() {
        let message = IdeasStore.message(for: .update, code: "P0002")
        #expect(message.contains("not here anymore"))
        #expect(!message.contains("connection"))
    }
}

struct UncheckedAllergyNoteTests {
    private let nora = UUID(), owen = UUID()
    private var allergies: [MemberAllergies] {
        [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])]
    }
    private let bare = LibraryMeal.fixture(name: "Chili")
    private let cooked = LibraryMeal.fixture(name: "Mac", ingredients: ["milk"])

    private func note(_ meal: LibraryMeal, library: [LibraryMeal]? = nil, members: [MemberAllergies]) -> String? {
        AllergyMatcher.uncheckedNote(meal: meal, library: library ?? [meal], members: members)
    }

    @Test func aDishWithNoIngredientsSaysAllergiesCantBeChecked() {
        #expect(note(bare, members: allergies)?.contains("allergies can't be checked") == true)
    }

    @Test func aDishWithIngredientsSaysNothing() {
        #expect(note(cooked, members: allergies) == nil)
    }

    @Test(arguments: [[MemberAllergies](),
                      [MemberAllergies(memberID: UUID(), firstName: "Owen")],
                      [MemberAllergies(memberID: UUID(), firstName: "Owen", allergens: [.custom])],
                      [MemberAllergies(memberID: UUID(), firstName: "Owen", customTexts: ["  -  "])]])
    func aFamilyWithNoAllergiesRecordedNeverHearsIt(members: [MemberAllergies]) {
        #expect(note(bare, members: members) == nil)
    }

    @Test func anAllergyTypedUnderOtherCounts() {
        let kiwi = [MemberAllergies(memberID: owen, firstName: "Owen", customTexts: ["kiwi"])]
        #expect(note(bare, members: kiwi) != nil)
    }

    @Test func aSidesIngredientsDontMakeTheDishChecked() {
        var meal = bare
        meal.sides = [.meal(cooked.id), .item(itemID: UUID(), name: "salsa")]
        #expect(note(meal, library: [meal, cooked], members: allergies) != nil)
    }

    @Test func aSideWithNoIngredientsIsNamed() throws {
        let bread = LibraryMeal.fixture(name: "Cornbread")
        var meal = cooked
        meal.sides = [.meal(bread.id)]
        let said = try #require(note(meal, library: [meal, bread], members: allergies))
        #expect(said.contains("Cornbread"), "the dish has its ingredients; it's the side that doesn't")
    }

    @Test func sidesThatCantBeMissingIngredientsSayNothing() {
        let retired = LibraryMeal.fixture(name: "Liver", status: .retired)
        var meal = cooked
        meal.sides = [.meal(retired.id), .item(itemID: UUID(), name: "salsa")]
        #expect(note(meal, library: [meal, retired], members: allergies) == nil,
                "a retired side isn't served, and a simple side is its own ingredient")
    }

    @Test func aSideThatIsntInTheLibraryCantBeChecked() throws {
        var meal = cooked
        meal.sides = [.meal(UUID())]
        let said = try #require(note(meal, library: [meal], members: allergies))
        #expect(said.contains("allergies can't be checked"))
    }

    @Test func aFamilyWithNoAllergiesDoesntHearAboutAMissingSide() {
        var meal = cooked
        meal.sides = [.meal(UUID())]
        #expect(note(meal, library: [meal], members: []) == nil)
    }

    @Test func aBareSideIsStillNamedWhenAnotherIsMissing() throws {
        let bread = LibraryMeal.fixture(name: "Cornbread")
        var meal = cooked
        meal.sides = [.meal(UUID()), .meal(bread.id)]
        let said = try #require(note(meal, library: [meal, bread], members: allergies))
        #expect(said.contains("Cornbread"), "that's the one the family can fix")
    }

    @Test func aMissingSideReachesTheWholeCheck() {
        var meal = cooked
        meal.sides = [.meal(UUID())]
        #expect(AllergyMatcher.check(meal: meal, library: [meal], members: allergies).note != nil)
    }
}

/// Every path to a dish reads the same function: Build, Swap, and Plan it all reach the card through a night's dish.
struct UncheckedOnTheCardTests {
    private let sunday = CalendarDay(year: 2037, month: 11, day: 1)
    private let nora = UUID(), owen = UUID()
    private var allergies: [MemberAllergies] {
        [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])]
    }
    private let bare = LibraryMeal.fixture(name: "Chili")

    private func night(_ offset: Int, meal: LibraryMeal? = nil, pick: QuickPick? = nil, leftoversFrom: UUID? = nil,
                       stash: UUID? = nil, home: [UUID: Bool]? = nil) -> WeekNight {
        WeekNight(id: UUID(), date: sunday.adding(days: offset), effort: .normal, dinnerTime: "18:00", mealID: meal?.id,
                  mealName: meal?.name, quickPick: pick, locked: false, attendance: home ?? [nora: true, owen: true],
                  leftoversFrom: leftoversFrom, stashItemID: stash)
    }

    @MainActor
    private func card(_ target: WeekNight, week: [WeekNight]? = nil, library: [LibraryMeal]? = nil,
                      allergies: [MemberAllergies]? = nil) -> DayCardModel {
        WeekStore.planCard(for: target, nights: week ?? [target], members: [], library: library ?? [bare],
                           allergies: allergies ?? self.allergies, settings: HouseholdSettings(), today: sunday,
                           minuteNow: 0, lookup: .loaded)
    }

    private func unchecked(_ card: DayCardModel) -> [String] {
        card.badges.compactMap { if case .allergyUnchecked(let text) = $0 { text } else { nil } }
    }

    @MainActor
    @Test func aPlannedDishWithNoIngredientsSaysSoOnItsCard() throws {
        let model = card(night(1, meal: bare))
        let said = try #require(unchecked(model).first)
        #expect(said.contains("allergies can't be checked"))
        #expect(DayCardText.accessibilitySummary(model, today: sunday).contains(said), "VoiceOver reads it too")
    }

    @MainActor
    @Test func itsOnlySaidWhenTheOneWithAllergiesIsHome() {
        #expect(unchecked(card(night(1, meal: bare, home: [nora: false, owen: true]))).isEmpty)
    }

    @MainActor
    @Test func aFamilyWithNoAllergiesSeesNothing() {
        #expect(card(night(1, meal: bare), allergies: []).badges.isEmpty)
    }

    @MainActor
    @Test func aDishWithIngredientsSeesOnlyItsFlags() {
        let mac = LibraryMeal.fixture(name: "Mac", ingredients: ["milk"])
        let model = card(night(1, meal: mac), library: [mac])
        #expect(unchecked(model).isEmpty)
        #expect(model.badges.count == 1)
    }

    @MainActor
    @Test func aFreezerNightStillSaysSo() {
        #expect(unchecked(card(night(1, meal: bare, stash: UUID()))).count == 1)
    }

    @MainActor
    @Test func leftoversOfThatDishStillSaySo() {
        let monday = night(1, meal: bare, home: [nora: false, owen: true])
        let tuesday = night(2, pick: .leftovers, leftoversFrom: monday.id)
        #expect(unchecked(card(tuesday, week: [monday, tuesday])).count == 1)
        #expect(unchecked(card(monday, week: [monday, tuesday])).isEmpty, "Nora's out for the dish itself")
    }

    @MainActor
    @Test(arguments: [QuickPick.takeout, .eatOut, .fendForYourselves, .freezerRaid, .leftovers])
    func aQuickPickNamesNoDishSoSaysNothing(pick: QuickPick) {
        #expect(card(night(1, pick: pick)).badges.isEmpty)
    }

    @MainActor
    @Test func anEmptyNightSaysNothing() {
        #expect(card(night(1)).badges.isEmpty)
    }
}

struct UncheckedInTheLibraryTests {
    private let allergies = [MemberAllergies(memberID: UUID(), firstName: "Nora", allergens: [.milk])]
    private let bare = LibraryMeal.fixture(name: "Chili")
    private let mac = LibraryMeal.fixture(name: "Mac", ingredients: ["milk"])

    private func entries(_ allergies: [MemberAllergies]) -> [LibraryEntry] {
        LibraryQuery.entries(allOf: [bare, mac], history: [], allergies: allergies, favorites: [])
    }

    @Test func theTileSaysSoAndSoDoesVoiceOver() throws {
        let entry = try #require(entries(allergies).first { $0.meal.id == bare.id })
        let note = try #require(entry.uncheckedNote)
        #expect(LibraryText.accessibilityLabel(entry, madeBy: nil).contains(note))
        #expect(entries(allergies).first { $0.meal.id == mac.id }?.uncheckedNote == nil)
    }

    @Test func aFamilyWithNoAllergiesKeepsJustTheAddIngredientsChip() throws {
        let entry = try #require(entries([]).first { $0.meal.id == bare.id })
        #expect(entry.uncheckedNote == nil)
        #expect(LibraryText.accessibilityLabel(entry, madeBy: nil) == "Chili, Add ingredients")
    }

    @Test func itIsntAnAllergyFlag() {
        let flagged = LibraryQuery.apply(entries(allergies), filter: .allergyFlags, sort: .recentlyAdded, search: "")
        #expect(flagged.map(\.meal.id) == [mac.id])
    }

    @Test func theFlagsFilterDoesntCallUncheckedDishesSafe() {
        let clear = LibraryText.emptyState(filter: .allergyFlags, searching: false)
        #expect(clear.message.contains("None of your meals contain"))
        let one = LibraryText.emptyState(filter: .allergyFlags, searching: false, unchecked: 1)
        #expect(!one.message.contains("None of your meals contain"))
        #expect(one.message.contains("1 meal"))
        let some = LibraryText.emptyState(filter: .allergyFlags, searching: false, unchecked: 3)
        #expect(some.message.contains("3 meals"))
        #expect(some.systemImage != "checkmark.shield", "nothing here has been checked clear")
    }
}

struct UncheckedInTheFreezerTests {
    private let sunday = CalendarDay(year: 2037, month: 11, day: 1)
    private let nora = UUID(), owen = UUID()

    private func offer(meal: LibraryMeal, home: [UUID: Bool]) -> FreezerStash.Offer? {
        let target = WeekNight(id: UUID(), date: sunday.adding(days: 2), effort: .normal, dinnerTime: nil, mealID: nil,
                               mealName: nil, quickPick: nil, locked: false, attendance: home)
        let item = FreezerItem(id: UUID(), mealID: meal.id, mealName: meal.name, madeOn: sunday, state: .in, plannedOn: nil)
        return FreezerStash.offers([item], on: target, week: [target], library: [meal], notForMe: [:], snoozed: [],
                                   allergies: [MemberAllergies(memberID: nora, firstName: "Nora", allergens: [.milk])],
                                   today: sunday).first
    }

    @Test func swapSaysSoForWhoeversHomeThatNight() {
        let bare = LibraryMeal.fixture(name: "Chili")
        #expect(offer(meal: bare, home: [nora: true])?.uncheckedNote != nil)
        #expect(offer(meal: bare, home: [nora: false, owen: true])?.uncheckedNote == nil)
        #expect(offer(meal: LibraryMeal.fixture(name: "Mac", ingredients: ["pasta"]), home: [nora: true])?.uncheckedNote == nil)
    }
}

/// Meal detail asks for one dish; its sides still have to be found in the whole library.
@MainActor
struct MealDetailEntryTests {
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)

    private func store(_ meals: [LibraryMeal]) async -> LibraryStore {
        let milk = AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in meals },
                                                                                 allergies: { _ in [milk] }))
        await store.load(members: [nora])
        return store
    }

    private func dish(_ name: String, ingredients: [String], side: LibraryMeal) -> LibraryMeal {
        var meal = LibraryMeal.fixture(name: name, ingredients: ingredients)
        meal.sides = [.meal(side.id)]
        return meal
    }

    @Test func detailFlagsWhatsInASide() async throws {
        let caesar = LibraryMeal.fixture(name: "Caesar", ingredients: ["milk"])
        let spaghetti = dish("Spaghetti", ingredients: ["pasta"], side: caesar)
        let library = await store([spaghetti, caesar])
        let entry = try #require(library.entry(spaghetti.id))
        #expect(entry.meal.id == spaghetti.id)
        #expect(entry.flags.map(\.summary) == ["Contains milk (Nora)"])
        #expect(entry.flags == library.visibleEntries.first { $0.meal.id == spaghetti.id }?.flags,
                "the tile and the dish agree")
    }

    @Test func detailNamesABareSide() async throws {
        let cornbread = LibraryMeal.fixture(name: "Cornbread")
        let chili = dish("Chili", ingredients: ["beans"], side: cornbread)
        let library = await store([chili, cornbread])
        let note = try #require(library.entry(chili.id)?.uncheckedNote)
        #expect(note.contains("Cornbread"))
    }

    @Test func detailStillSkipsARetiredSide() async throws {
        let liver = LibraryMeal.fixture(name: "Liver", status: .retired, ingredients: ["milk"])
        let bare = LibraryMeal.fixture(name: "Old side", status: .retired)
        var chili = dish("Chili", ingredients: ["beans"], side: liver)
        chili.sides.append(.meal(bare.id))
        let library = await store([chili, liver, bare])
        let entry = try #require(library.entry(chili.id))
        #expect(entry.flags.isEmpty)
        #expect(entry.uncheckedNote == nil)
    }
}

/// Ideas have no realtime: phone B can be looking at an idea phone A has already saved and planned.
@MainActor
struct StalePhoneTests {
    private let asker = UUID()

    private func ideas(
        _ requests: @escaping @Sendable () throws -> [DinnerRequest],
        update: @escaping @Sendable (UUID, RequestUpdate) async throws -> Void = { _, _ in }
    ) -> IdeasStore {
        IdeasStore(householdID: UUID(), client: IdeasClient(
            requests: { _ in try requests() }, make: { _, _ in UUID() }, toggleMeToo: { _, _ in true }, update: update
        ))
    }

    @Test func anIdeaAnotherPhoneSavedIsntSavedAgain() async {
        let seen = DinnerRequest(requestedByMemberID: asker, title: "Chili", link: link)
        let dish = UUID()
        let saved = DinnerRequest(id: seen.id, requestedByMemberID: asker, mealID: dish, title: "Chili", link: link,
                                  status: .planned, plannedNightID: UUID())
        let store = ideas { [saved] }
        #expect(await store.latestToSave(seen) == nil)
        #expect(store.requests.first?.mealID == dish, "and the screen now shows its dish")
    }

    @Test func anIdeaArchivedElsewhereIsntSaved() async {
        let seen = DinnerRequest(requestedByMemberID: asker, title: "Chili")
        #expect(await ideas { [] }.latestToSave(seen) == nil)
    }

    @Test func anIdeaStillWithoutADishGoesAhead() async {
        let seen = DinnerRequest(requestedByMemberID: asker, title: "Chili")
        #expect(await ideas { [seen] }.latestToSave(seen)?.id == seen.id)
    }

    @Test func offlineItGoesAheadOnWhatItHasWithNoError() async {
        let seen = DinnerRequest(requestedByMemberID: asker, title: "Chili")
        let store = ideas { throw URLError(.notConnectedToInternet) }
        #expect(await store.latestToSave(seen)?.id == seen.id, "the server refuses a second dish if it comes to that")
        #expect(store.errorMessage == nil)
    }

    @Test func aDishLostToAnotherPhoneSaysSoAndIsForgotten() async {
        let first = UUID(), second = UUID()
        let idea = DinnerRequest(requestedByMemberID: asker, mealID: first, title: "Chili")
        let store = ideas({ [idea] }, update: { _, _ in throw PostgrestError(code: "FD014", message: "already linked") })
        #expect(!(await store.linkDish(second, to: idea.id)))
        #expect(store.madeDishes[idea.id] == nil, "a retry would only be refused again")
        #expect(store.requests.first?.mealID == first, "the screen shows the dish it has")
        #expect(store.errorMessage == IdeasStore.message(for: .update, code: "FD014"))
        #expect(store.errorMessage?.contains("already") == true)
        #expect(store.errorMessage?.contains("connection") == false)
    }

    @Test func deletingADishForgetsItForTheIdeaThatMadeIt() async {
        let dish = UUID(), other = UUID()
        let idea = DinnerRequest(requestedByMemberID: asker, title: "Chili")
        let otherIdea = DinnerRequest(requestedByMemberID: asker, title: "Soup")
        let store = ideas { [idea, otherIdea] }
        store.rememberDish(dish, for: idea.id)
        store.rememberDish(other, for: otherIdea.id)
        await store.dishDeleted(dish)
        #expect(store.madeDishes[idea.id] == nil)
        #expect(store.madeDishes[otherIdea.id] == other)
    }

    @Test func aRememberedDishDeletedOnAnotherPhoneIsForgotten() async {
        let dish = UUID()
        let idea = DinnerRequest(requestedByMemberID: asker, title: "Chili")
        let store = ideas({ [idea] }, update: { _, _ in throw PostgrestError(code: "P0002", message: "no meal") })
        #expect(!(await store.linkDish(dish, to: idea.id)))
        #expect(store.madeDishes[idea.id] == nil, "a retry makes a new dish instead of being refused forever")
    }

    @Test func aFailedLinkOfflineKeepsItsOwnMessageAndTheDish() async {
        let dish = UUID()
        let idea = DinnerRequest(requestedByMemberID: asker, title: "Chili")
        let store = ideas({ throw URLError(.notConnectedToInternet) },
                          update: { _, _ in throw URLError(.notConnectedToInternet) })
        #expect(!(await store.linkDish(dish, to: idea.id)))
        #expect(store.madeDishes[idea.id] == dish)
        #expect(store.errorMessage == IdeasStore.message(for: .update, code: nil))
    }
}

@MainActor
struct DishThatDidntLoadTests {
    private let dish = LibraryMeal.fixture(name: "Chili")

    @Test func ideasReloadTheLibraryWhenItNeverLoaded() {
        #expect(RequestBoard.needsLibraryReload([], library: [], hasLoaded: false))
    }

    @Test func ideasReloadTheLibraryWhenAnIdeasDishIsMissing() {
        let idea = DinnerRequest(requestedByMemberID: UUID(), mealID: dish.id)
        #expect(RequestBoard.needsLibraryReload([idea], library: [], hasLoaded: true))
        #expect(!RequestBoard.needsLibraryReload([idea], library: [dish], hasLoaded: true))
    }

    @Test func ideasWithNoDishNeedNoReload() {
        let idea = DinnerRequest(requestedByMemberID: UUID(), title: "Crab legs")
        #expect(!RequestBoard.needsLibraryReload([idea], library: [], hasLoaded: true))
    }

    /// The reload after making it fails: the dish exists, the library doesn't show it, and loading again finds it.
    @Test func aFailedReloadAfterMakingTheDishCanBeRecovered() async throws {
        let failing = Mutex(false)
        let made = LibraryMeal.fixture(name: "Chili")
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(
            meals: { _ in
                if failing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
                return [made]
            },
            create: { _, _ in made.id }
        ))
        failing.withLock { $0 = true }
        let id = await store.create(MealDraft(newNamed: "Chili"))
        #expect(id == made.id)
        #expect(store.meal(made.id) == nil)
        let idea = DinnerRequest(requestedByMemberID: UUID(), mealID: made.id)
        #expect(RequestBoard.needsLibraryReload([idea], library: store.meals, hasLoaded: store.hasLoaded))
        failing.withLock { $0 = false }
        await store.load(members: [])
        #expect(store.meal(made.id) != nil)
        #expect(!RequestBoard.needsLibraryReload([idea], library: store.meals, hasLoaded: store.hasLoaded))
    }
}

@MainActor
struct UncheckedCountTests {
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)

    private func count(_ meals: [LibraryMeal], allergies: Bool = true) async -> Int {
        let rows = allergies ? [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)] : []
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(meals: { _ in meals }, allergies: { _ in rows }))
        await store.load(members: [nora])
        return store.uncheckedCount
    }

    @Test func countsOnlyDishesInRotation() async {
        #expect(await count([.fixture(name: "Chili"), .fixture(name: "Soup", status: .trial)]) == 2)
        #expect(await count([.fixture(name: "Old", status: .archived), .fixture(name: "Liver", status: .retired)]) == 0)
    }

    @Test func countsADishWithABareSide() async {
        let cornbread = LibraryMeal.fixture(name: "Cornbread", status: .archived)
        var chili = LibraryMeal.fixture(name: "Chili", ingredients: ["beans"])
        chili.sides = [.meal(cornbread.id)]
        #expect(await count([chili, cornbread]) == 1, "the archived side still goes with it; it isn't counted itself")
    }

    @Test func aDishWithIngredientsOrAFamilyWithNoAllergiesCountsNothing() async {
        #expect(await count([.fixture(name: "Mac", ingredients: ["milk"])]) == 0)
        #expect(await count([.fixture(name: "Chili")], allergies: false) == 0)
    }

    @Test func theFilterSaysSoEvenWithSomethingFlagged() throws {
        let one = try #require(LibraryText.uncheckedFilterNote(filter: .allergyFlags, unchecked: 1))
        #expect(one.contains("1 meal"))
        #expect(!one.contains("no ingredients"), "a side that can't be found has its ingredients; the dish says which it is")
        let some = try #require(LibraryText.uncheckedFilterNote(filter: .allergyFlags, unchecked: 5))
        #expect(some.contains("5 meals"))
        #expect(LibraryText.uncheckedFilterNote(filter: .allergyFlags, unchecked: 0) == nil)
        #expect(LibraryText.uncheckedFilterNote(filter: nil, unchecked: 5) == nil, "only on that filter")
        #expect(LibraryText.uncheckedFilterNote(filter: .favorites, unchecked: 5) == nil)
    }
}
