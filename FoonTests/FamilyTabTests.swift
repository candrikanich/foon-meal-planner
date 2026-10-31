import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

@MainActor
struct RhythmTests {
    nonisolated private static let refused = PostgrestError(code: "42501", message: "refused")

    private func keys(_ changes: RhythmChanges) throws -> Set<String> {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changes)) as? [String: Any]
        return Set(try #require(json).keys)
    }

    private func store(_ settings: HouseholdSettings, client change: (inout HouseholdClient) -> Void = { _ in }) -> HouseholdStore {
        let household = Household(id: Household.sample.id, name: "The Smiths", owner: .previewUser, settings: settings)
        var client = HouseholdClient.fake(myHousehold: { household }, members: { _ in Member.sampleFamily })
        change(&client)
        return HouseholdStore(userID: .previewUser, client: client)
    }

    @Test func onlyWhatChangedIsSent() throws {
        let old = HouseholdSettings()
        var new = old
        new.dinnerTime = "17:30"
        new.notificationPreset = .light
        #expect(try keys(RhythmChanges(from: old, to: new)) == ["dinner_time", "notification_preset"])
        #expect(try keys(RhythmChanges(from: old, to: old)).isEmpty)
        #expect(RhythmChanges(from: old, to: old).isEmpty)
        #expect(!RhythmChanges(from: old, to: new).isEmpty)
    }

    @Test(arguments: [
        (\HouseholdSettings.planningDay, "planning_day"), (\HouseholdSettings.weekStart, "week_start"),
        (\HouseholdSettings.newDishesPerWeek, "new_dishes_per_week"), (\HouseholdSettings.takeoutNights, "takeout_nights"),
        (\HouseholdSettings.leftoverNights, "leftover_nights"), (\HouseholdSettings.repeatWindowDays, "repeat_window_days")
    ] as [(WritableKeyPath<HouseholdSettings, Int> & Sendable, String)])
    func eachNumberGoesToItsOwnKey(key: WritableKeyPath<HouseholdSettings, Int> & Sendable, name: String) throws {
        let old = HouseholdSettings()
        var new = old
        new[keyPath: key] = 3
        let changes = RhythmChanges(from: old, to: new)
        #expect(try keys(changes) == [name])
        #expect(changes.applied(to: old) == new, "it comes back out as the same field")
    }

    @Test func savingOnAStalePhoneKeepsWhatAnotherPlannerChanged() async {
        // This phone opened the screen with a 6:00 dinner. Another planner has since moved it, and the store has heard.
        let opened = HouseholdSettings()
        var current = opened
        current.timeZone = "America/Chicago"  // With none, the first load fills it in with a whole save of its own.
        current.dinnerTime = "17:30"
        current.foodRules = [FoodRule(avoid: .meat, nights: .everyNight)]
        var draft = opened
        draft.notificationPreset = .engaged
        let sent = Mutex<[RhythmChanges]>([])
        let whole = Mutex(0)
        let store = store(current) { client in
            client.updateRhythm = { _, changes in sent.withLock { $0.append(changes) } }
            client.updateSettings = { _, _ in whole.withLock { $0 += 1 } }
        }
        await store.load()

        #expect(await store.updateRhythm(RhythmChanges(from: opened, to: draft)))

        #expect(sent.withLock { $0 } == [RhythmChanges(from: opened, to: draft)])
        #expect(whole.withLock { $0 } == 0, "never the whole settings")
        let saved = store.household?.planningSettings
        #expect(saved?.notificationPreset == .engaged)
        #expect(saved?.dinnerTime == "17:30", "the other planner's dinner time stays, on the server and on screen")
        #expect(saved?.foodRules == current.foodRules)
    }

    @Test func nothingChangedSkipsTheServer() async {
        let calls = Mutex(0)
        let store = store(HouseholdSettings()) { client in
            client.updateRhythm = { _, _ in calls.withLock { $0 += 1 } }
        }
        await store.load()
        #expect(await store.updateRhythm(RhythmChanges(from: HouseholdSettings(), to: HouseholdSettings())))
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func aRefusalSaysWhoCanAndADroppedConnectionDoesNot() async {
        var draft = HouseholdSettings()
        draft.dinnerTime = "19:00"
        let changes = RhythmChanges(from: HouseholdSettings(), to: draft)

        let refused = store(HouseholdSettings()) { $0.updateRhythm = { _, _ in throw Self.refused } }
        await refused.load()
        #expect(await refused.updateRhythm(changes) == false)
        #expect(refused.errorMessage == "Only planners can change the household's rhythm.")
        #expect(refused.household?.planningSettings.dinnerTime == "18:00")

        let offline = store(HouseholdSettings()) { $0.updateRhythm = { _, _ in throw URLError(.notConnectedToInternet) } }
        await offline.load()
        #expect(await offline.updateRhythm(changes) == false)
        #expect(offline.errorMessage == "Couldn't save the settings. Check your connection and try again.")
    }

    @Test func aReloadThatStartedBeforeTheSaveCantPutTheOldTimeBack() async {
        let (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
        let (gate, gateSignal) = AsyncStream.makeStream(of: Void.self)
        let household = Household.sample
        let fetches = Mutex(0)
        let client: HouseholdClient = {
            var client = HouseholdClient.fake(
                myHousehold: {
                    if fetches.withLock({ $0 += 1; return $0 }) == 2 {
                        parkedSignal.yield()
                        for await _ in gate { break }
                    }
                    return household
                },
                members: { _ in Member.sampleFamily }
            )
            client.updateRhythm = { _, _ in }
            return client
        }()
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        var draft = HouseholdSettings()
        draft.dinnerTime = "19:00"

        let older = Task { await store.refreshQuietly() }
        for await _ in parked { break }
        #expect(await store.updateRhythm(RhythmChanges(from: HouseholdSettings(), to: draft)))
        gateSignal.yield()
        await older.value
        gateSignal.finish()
        parkedSignal.finish()

        #expect(store.household?.planningSettings.dinnerTime == "19:00")
    }

    // MARK: - The week start

    @Test func theWeekStartIsHeldWhileAPlanIsRunningOrWaiting() {
        let today = CalendarDay(year: 2026, month: 10, day: 28)
        #expect(WeekStartCheck.of(latestWeek: nil, today: today) == .free)
        #expect(WeekStartCheck.of(latestWeek: today.adding(days: -3), today: today) == .lockedThrough(today.adding(days: 3)))
        #expect(WeekStartCheck.of(latestWeek: today.adding(days: -6), today: today) == .lockedThrough(today),
                "its last night is tonight")
        #expect(WeekStartCheck.of(latestWeek: today.adding(days: -7), today: today) == .free, "it ended last night")
        #expect(WeekStartCheck.of(latestWeek: today.adding(days: 4), today: today) == .lockedThrough(today.adding(days: 10)),
                "next week's plan counts")
    }

    @Test func thePlanEndingIsTheHouseholdsDayNotThePhones() async {
        // At no moment do these two zones share a date, so whichever the device is in, it's not always Pago Pago's day.
        var settings = HouseholdSettings()
        settings.timeZone = "Pacific/Pago_Pago"
        let lastNight = settings.today()
        let store = store(settings) { client in
            client.latestWeekStart = { _ in lastNight.adding(days: -6) }
        }
        await store.load()
        #expect(await store.weekStartCheck() == .lockedThrough(lastNight))
    }

    @Test func aPlanStartedSinceTheScreenOpenedStopsTheChange() async {
        var draft = HouseholdSettings()
        draft.weekStart = 3
        draft.dinnerTime = "19:00"
        let sent = Mutex(0)
        let store = store(HouseholdSettings()) { client in
            client.latestWeekStart = { _ in CalendarDay(Date()) }
            client.updateRhythm = { _, _ in sent.withLock { $0 += 1 } }
        }
        await store.load()
        #expect(await store.updateRhythm(RhythmChanges(from: HouseholdSettings(), to: draft)) == false)
        #expect(sent.withLock { $0 } == 0)
        #expect(store.errorMessage == "The week start can't change while a plan is running. Nothing was saved.")
        #expect(store.household?.planningSettings.weekStart == 7)
    }

    @Test func notKnowingAboutThePlansStopsTheChangeToo() async {
        var draft = HouseholdSettings()
        draft.weekStart = 3
        let sent = Mutex(0)
        let store = store(HouseholdSettings()) { client in
            client.latestWeekStart = { _ in throw URLError(.notConnectedToInternet) }
            client.updateRhythm = { _, _ in sent.withLock { $0 += 1 } }
        }
        await store.load()
        #expect(await store.weekStartCheck() == .unknown)
        #expect(await store.updateRhythm(RhythmChanges(from: HouseholdSettings(), to: draft)) == false)
        #expect(sent.withLock { $0 } == 0)
    }

    @Test func otherFieldsSaveWhileAPlanIsRunning() async {
        var draft = HouseholdSettings()
        draft.takeoutNights = 2
        let store = store(HouseholdSettings()) { client in
            client.latestWeekStart = { _ in CalendarDay(Date()) }
        }
        await store.load()
        #expect(await store.updateRhythm(RhythmChanges(from: HouseholdSettings(), to: draft)))
        #expect(store.household?.planningSettings.takeoutNights == 2)
    }

    @Test func aFreeWeekStartSaves() async {
        var draft = HouseholdSettings()
        draft.weekStart = 3
        let store = store(HouseholdSettings())
        await store.load()
        #expect(await store.updateRhythm(RhythmChanges(from: HouseholdSettings(), to: draft)))
        #expect(store.household?.planningSettings.weekStart == 3)
    }
}

@MainActor
struct MemberSummaryTests {
    private let today = CalendarDay(year: 2026, month: 10, day: 30)

    @Test func statusGoesByTheReturnDateOnTheHouseholdsDay() {
        #expect(Member.fixture().statusTitle(today: today) == "Home")
        #expect(Member.fixture(status: .away).statusTitle(today: today) == "Away", "no return date")
        let back = CalendarDay(year: 2026, month: 11, day: 4)
        let date = back.date().formatted(.dateTime.month(.abbreviated).day())
        #expect(Member.fixture(status: .away, awayUntil: back).statusTitle(today: today) == "Away until \(date)")
        #expect(Member.fixture(status: .away, awayUntil: today).statusTitle(today: today) == "Home",
                "the return date is their first night home, as on the server")
        #expect(Member.fixture(status: .away, awayUntil: today.adding(days: -9)).statusTitle(today: today) == "Home",
                "never \"Away until\" a date that's gone")
    }

    @Test func scheduleSaysWhichNightsTheyreOut() {
        var member = Member.fixture()
        #expect(member.scheduleTitle == "Home every night")
        member.attendanceDefaults = AttendanceDefaults(usuallyAway: [3, 1])
        let monday = WeekMath.Weekday(iso: 1).shortName()
        let wednesday = WeekMath.Weekday(iso: 3).shortName()
        #expect(member.scheduleTitle == "Out \(monday), \(wednesday)")
        member.attendanceDefaults = AttendanceDefaults(usuallyAway: Set(1...7))
        #expect(member.scheduleTitle == "Out every night")
    }

    @Test func allergyNamesListStandardOnesThenWhatAParentTyped() {
        let allergies = MemberAllergies(memberID: UUID(), firstName: "Nora", allergens: [.sesame, .milk], customTexts: ["kiwi"])
        #expect(allergies.displayNames == ["Milk", "Sesame", "kiwi"])
    }

    @Test func cookCreditCountsReadPlainly() {
        let one = CookCredit.Tally(memberID: UUID(), dinners: 1, thanks: 1)
        #expect((one.dinnersTitle, one.thanksTitle) == ("1 dinner", "1 thank-you"))
        let more = CookCredit.Tally(memberID: UUID(), dinners: 3, thanks: 2)
        #expect((more.dinnersTitle, more.thanksTitle) == ("3 dinners", "2 thank-yous"))
    }
}

/// What the UI offers each kind of person, which must match `members_guard_write` and `is_household_planner`
/// (supabase/tests/database/37_family_tab.test.sql proves the server's side).
@MainActor
struct FamilyPermissionTests {
    private let ownerID = UUID()
    private let parentID = UUID()
    private let plannerID = UUID()
    private let kidID = UUID()

    private var family: [Member] {
        [
            .fixture(firstName: "Ann", guardian: true, role: .planner, userID: ownerID),
            .fixture(firstName: "Ben", guardian: true, userID: parentID),
            .fixture(firstName: "Grace", role: .planner, userID: plannerID),
            .fixture(firstName: "Nora", ageGroup: .kid, userID: kidID),
            .fixture(firstName: "Owen", ageGroup: .kid)
        ]
    }

    private func store(as userID: UUID) async -> HouseholdStore {
        let household = Household(id: Household.sample.id, name: "The Smiths", owner: ownerID)
        let family = family
        let store = HouseholdStore(userID: userID, client: .fake(myHousehold: { household }, members: { _ in family }))
        await store.load()
        return store
    }

    private func member(_ store: HouseholdStore, _ name: String) -> Member {
        store.members.first { $0.firstName == name }!
    }

    @Test func aKidChangesOnlyTheirOwnSchedule() async {
        let store = await store(as: kidID)
        let own = store.editScope(for: member(store, "Nora"))
        #expect(own.schedule)
        #expect(!own.name && !own.planning && !own.identity)
        #expect(store.editScope(for: member(store, "Owen")) == .none)
        #expect(store.editScope(for: member(store, "Ann")) == .none)
        #expect(!store.canManagePeople, "so no allergy editing")
        #expect(!LibraryStore.canEdit(me: store.me, isOwner: false), "and no rhythm")
    }

    @Test func aPlannerWhoIsntAParentChangesTheRhythmButNotOtherPeople() async {
        let store = await store(as: plannerID)
        #expect(store.editScope(for: member(store, "Grace")).schedule)
        #expect(store.editScope(for: member(store, "Owen")) == .none)
        #expect(!store.canManagePeople)
        #expect(LibraryStore.canEdit(me: store.me, isOwner: false))
    }

    @Test func aParentWhoIsntTheOwnerOverridesSchedulesButNotTheOwnersStatus() async {
        let store = await store(as: parentID)
        #expect(store.canManagePeople)
        #expect(store.editScope(for: member(store, "Owen")) == .everything)
        let owner = store.editScope(for: member(store, "Ann"))
        #expect(owner.schedule)
        #expect(!owner.planning, "status and role stay the owner's")
        #expect(!LibraryStore.canEdit(me: store.me, isOwner: false), "not a planner, so no rhythm")
    }

    @Test func theOwnerDoesItAll() async {
        let store = await store(as: ownerID)
        #expect(store.canManagePeople)
        #expect(store.editScope(for: member(store, "Ann")) == .ownProfileAsOwner)
        #expect(store.editScope(for: member(store, "Nora")) == .everything)
        #expect(LibraryStore.canEdit(me: store.me, isOwner: true))
    }

    @Test func aDroppedConnectionOnAProfileEditIsntARefusal() async {
        let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let store = HouseholdStore(userID: .previewUser, client: .fake(
            myHousehold: { .sample }, members: { _ in [nora] },
            updateMember: { _, _ in throw URLError(.notConnectedToInternet) }
        ))
        await store.load()
        var draft = MemberDraft(nora)
        draft.usuallyAway = [1]
        #expect(await store.save(draft, editing: nora) == false)
        #expect(store.errorMessage == "Couldn't save. Pull to refresh in case someone else changed this, then try again.")
    }
}

struct TasteProfileTests {
    private let nora = UUID()
    private let tacos = LibraryMeal.fixture(name: "Tacos")
    private let chili = LibraryMeal.fixture(name: "Chili")
    private let soup = LibraryMeal.fixture(name: "Soup", status: .retired)
    private let oldFish = LibraryMeal.fixture(name: "Old fish", status: .archived)
    private let day = CalendarDay(year: 2026, month: 10, day: 1)

    private func verdict(_ meal: LibraryMeal, _ kind: ReactionKind, member: UUID? = nil) -> MealVerdict {
        MealVerdict(mealID: meal.id, memberID: member ?? nora, kind: kind, reactedOn: day)
    }

    private func profile(_ verdicts: [MealVerdict], notes: [ServingNote] = []) -> TasteProfile {
        TasteProfile(memberID: nora, verdicts: verdicts, notes: notes, meals: [tacos, chili, soup, oldFish])
    }

    @Test func favoritesAndDislikesAreTheirsAlone() {
        let profile = profile([
            verdict(tacos, .favorite), verdict(chili, .favorite), verdict(soup, .notForMe),
            verdict(soup, .favorite, member: UUID()), verdict(tacos, .notForMe, member: UUID())
        ])
        #expect(profile.favorites.map(\.name) == ["Chili", "Tacos"], "by name, and not someone else's")
        #expect(profile.ratherSkip.map(\.name) == ["Soup"], "a retired dish is still what they think of it")
    }

    @Test func aPlainGoodOrASnoozeIsNeither() {
        let profile = profile([verdict(tacos, .good), verdict(chili, .tiredOfIt)])
        #expect(profile.isEmpty)
    }

    @Test func dishesLeftTheLibraryAreLeftOut() {
        let gone = UUID()
        let profile = profile(
            [verdict(oldFish, .favorite), MealVerdict(mealID: gone, memberID: nora, kind: .favorite, reactedOn: day)],
            notes: [ServingNote(mealID: oldFish.id, memberID: nora, note: "no bones")]
        )
        #expect(profile.isEmpty)
    }

    @Test func servingNotesAreTheirs() {
        let profile = profile([], notes: [
            ServingNote(mealID: tacos.id, memberID: nora, note: "keep everything separate"),
            ServingNote(mealID: chili.id, memberID: nora, note: "no beans"),
            ServingNote(mealID: tacos.id, memberID: UUID(), note: "extra hot")
        ])
        #expect(profile.notes.map(\.dish) == ["Chili", "Tacos"])
        #expect(profile.notes.map(\.note) == ["no beans", "keep everything separate"])
        #expect(!profile.isEmpty)
    }
}

@MainActor
struct AllergyEditorTests {
    private enum Call: Equatable {
        case consent(String)
        case set(UUID, [Allergen], [String])
    }

    private final class Calls: Sendable {
        private let calls = Mutex<[Call]>([])
        var all: [Call] { calls.withLock { $0 } }
        func add(_ call: Call) { calls.withLock { $0.append(call) } }
    }

    private let nora = UUID()
    private let household = Household.sample.id

    private func model(rows: @escaping @Sendable () throws -> [AllergyRow], consent: (@Sendable () throws -> Void)? = nil,
                       set: (@Sendable () throws -> Void)? = nil, calls: Calls) -> AllergyEditorModel {
        AllergyEditorModel(memberID: nora, householdID: household, household: .fake(
            grantAllergyConsent: { _, version in
                try consent?()
                calls.add(.consent(version))
            },
            setAllergies: { member, allergens, custom in
                try set?()
                calls.add(.set(member, allergens, custom))
            }
        ), library: .fake(allergies: { _ in try rows() }))
    }

    private var milkAndKiwi: [AllergyRow] {
        [
            AllergyRow(memberID: nora, allergen: .milk, customText: nil),
            AllergyRow(memberID: nora, allergen: .custom, customText: "kiwi"),
            AllergyRow(memberID: UUID(), allergen: .peanuts, customText: nil)
        ]
    }

    @Test func opensOnThisPersonsAllergiesOnly() async {
        let rows = milkAndKiwi
        let model = model(rows: { rows }, calls: Calls())
        await model.load()
        #expect(model.answer.allergens == [.milk])
        #expect(model.answer.otherText == "kiwi")
        #expect(!model.canSave, "nothing's changed yet")
        #expect(model.needsConsent)
    }

    @Test func aFailedLoadCanNeverSaveAsNoAllergies() async {
        let calls = Calls()
        let model = model(rows: { throw URLError(.notConnectedToInternet) }, calls: calls)
        await model.load()
        #expect(model.phase == .failed)
        model.answer = OnboardingModel.Answer(allergens: [.eggs])
        #expect(!model.canSave)
        #expect(await model.save() == nil)
        #expect(calls.all.isEmpty)
    }

    @Test func addingAgreesToTheOneSentenceFirst() async throws {
        let calls = Calls()
        let model = model(rows: { [] }, calls: calls)
        await model.load()
        #expect(!model.needsConsent, "an empty answer asks for nothing")
        model.answer.allergens = [.eggs, .milk]
        model.answer.otherText = "kiwi, mango"
        #expect(model.needsConsent)

        let saved = try #require(await model.save())

        #expect(calls.all == [
            .consent(AllergyConsent.textVersion), .set(nora, [.milk, .eggs], ["kiwi", "mango"])
        ])
        #expect(saved == AllergyChoice(allergens: [.milk, .eggs], custom: ["kiwi", "mango"]))
    }

    @Test func noConsentNoAllergies() async {
        let calls = Calls()
        let model = model(rows: { [] }, consent: { throw PostgrestError(code: "42501", message: "refused") }, calls: calls)
        await model.load()
        model.answer.allergens = [.eggs]
        #expect(await model.save() == nil)
        #expect(calls.all.isEmpty, "the allergies never went out")
        #expect(model.errorMessage == "Only parents can change allergies.")
    }

    @Test func aDroppedConnectionIsntARefusal() async {
        let model = model(rows: { [] }, set: { throw URLError(.notConnectedToInternet) }, calls: Calls())
        await model.load()
        model.answer.allergens = [.eggs]
        #expect(await model.save() == nil)
        #expect(model.errorMessage == "Couldn't save the allergies. Check your connection and try again.")
    }

    @Test func takingTheLastOneAwaySavesAndAgreesToNothing() async throws {
        let calls = Calls()
        let rows = [AllergyRow(memberID: nora, allergen: .milk, customText: nil)]
        let model = model(rows: { rows }, calls: calls)
        await model.load()
        model.answer.allergens = []
        #expect(model.canSave)
        #expect(!model.needsConsent)

        let saved = try #require(await model.save())

        #expect(calls.all == [.set(nora, [], [])], "onboarding's save skips an empty answer; this can't")
        #expect(saved.isEmpty)
    }

    @Test func anAllergyAnotherParentAddedWhileThisWasOpenStays() async throws {
        let calls = Calls()
        let nora = nora
        let reads = Mutex(0)
        let model = model(rows: {
            let read = reads.withLock { $0 += 1; return $0 }
            var rows = [AllergyRow(memberID: nora, allergen: .milk, customText: nil)]
            if read > 1 {
                rows.append(AllergyRow(memberID: nora, allergen: .peanuts, customText: nil))
                rows.append(AllergyRow(memberID: nora, allergen: .custom, customText: "mango"))
            }
            return rows
        }, calls: calls)
        await model.load()
        model.answer.allergens = [.eggs]  // Took milk away, added eggs.

        let saved = try #require(await model.save())

        #expect(calls.all.last == .set(nora, [.eggs, .peanuts], ["mango"]))
        #expect(saved == AllergyChoice(allergens: [.eggs, .peanuts], custom: ["mango"]))
    }

    @Test func clearingTheScreenLeavesAnotherParentsAddition() async throws {
        let calls = Calls()
        let nora = nora
        let reads = Mutex(0)
        let model = model(rows: {
            let read = reads.withLock { $0 += 1; return $0 }
            return read == 1 ? [AllergyRow(memberID: nora, allergen: .milk, customText: nil)]
                : [AllergyRow(memberID: nora, allergen: .milk, customText: nil),
                   AllergyRow(memberID: nora, allergen: .peanuts, customText: nil)]
        }, calls: calls)
        await model.load()
        model.answer.allergens = []

        _ = try #require(await model.save())

        #expect(calls.all == [.set(nora, [.peanuts], [])], "no consent: this parent didn't see the sentence")
    }

    @Test func notBeingAbleToReadTheListBeforeSavingSavesNothing() async {
        let calls = Calls()
        let reads = Mutex(0)
        let model = model(rows: {
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw URLError(.notConnectedToInternet) }
            return []
        }, calls: calls)
        await model.load()
        model.answer.allergens = [.eggs]
        #expect(await model.save() == nil)
        #expect(calls.all.isEmpty)
    }

    @Test func anOlderLoadFinishingLastIsIgnored() async {
        let (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
        let (gate, gateSignal) = AsyncStream.makeStream(of: Void.self)
        let nora = nora
        let reads = Mutex(0)
        let model = AllergyEditorModel(memberID: nora, householdID: household, household: .fake(), library: .fake(allergies: { _ in
            if reads.withLock({ $0 += 1; return $0 }) == 1 {
                parkedSignal.yield()
                for await _ in gate { break }
                return [AllergyRow(memberID: nora, allergen: .milk, customText: nil)]
            }
            return [AllergyRow(memberID: nora, allergen: .eggs, customText: nil)]
        }))

        let older = Task { await model.load() }
        for await _ in parked { break }
        await model.load()
        gateSignal.yield()
        await older.value
        gateSignal.finish()
        parkedSignal.finish()

        #expect(model.answer.allergens == [.eggs])
    }
}

@MainActor
struct LibraryShowsSavedAllergiesTests {
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let household = Household.sample.id

    @Test func theSaveShowsEvenIfTheReloadFails() async {
        let nora = nora
        let reads = Mutex(0)
        let store = LibraryStore(householdID: household, client: .fake(allergies: { _ in
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw URLError(.notConnectedToInternet) }
            return [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)]
        }))
        await store.load(members: [nora])
        await store.showAllergies(AllergyChoice(allergens: [.eggs], custom: ["kiwi"]), for: nora, members: [nora])
        #expect(store.allergies == [MemberAllergies(memberID: nora.id, firstName: "Nora", allergens: [.eggs], customTexts: ["kiwi"])])
    }

    @Test func takingAllOfThemAwayRemovesTheEntry() async {
        let nora = nora
        let reads = Mutex(0)
        let store = LibraryStore(householdID: household, client: .fake(allergies: { _ in
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw URLError(.notConnectedToInternet) }
            return [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)]
        }))
        await store.load(members: [nora])
        await store.showAllergies(AllergyChoice(), for: nora, members: [nora])
        #expect(store.allergies.isEmpty)
    }

    @Test func aLoadFromBeforeTheSaveCantBringTheOldOnesBack() async {
        let (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
        let (gate, gateSignal) = AsyncStream.makeStream(of: Void.self)
        let nora = nora
        let reads = Mutex(0)
        let store = LibraryStore(householdID: household, client: .fake(allergies: { _ in
            if reads.withLock({ $0 += 1; return $0 }) == 1 {
                parkedSignal.yield()
                for await _ in gate { break }
                return [AllergyRow(memberID: nora.id, allergen: .milk, customText: nil)]
            }
            return [AllergyRow(memberID: nora.id, allergen: .eggs, customText: nil)]
        }))

        let older = Task { await store.load(members: [nora]) }
        for await _ in parked { break }
        await store.showAllergies(AllergyChoice(allergens: [.eggs]), for: nora, members: [nora])
        gateSignal.yield()
        await older.value
        gateSignal.finish()
        parkedSignal.finish()

        #expect(store.allergies.first?.allergens == [.eggs])
    }
}
