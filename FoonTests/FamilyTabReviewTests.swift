import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

/// A family phone that's been open a while: what someone else did has to reach it, and must not be undone by it.
@MainActor
struct OtherPhonesAllergyTests {
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let peanutButter = LibraryMeal.fixture(name: "Peanut noodles", ingredients: ["peanut butter", "noodles"])

    private func library(reads rows: @escaping @Sendable (Int) throws -> [AllergyRow]) -> LibraryStore {
        let reads = Mutex(0)
        let meal = peanutButter
        return LibraryStore(householdID: Household.sample.id, client: .fake(
            meals: { _ in [meal] },
            allergies: { _ in try rows(reads.withLock { $0 += 1; return $0 }) }
        ))
    }

    @Test func aParentsNewAllergyReachesTheCardAndLibraryOnForeground() async {
        let nora = nora
        let store = library { read in
            read == 1 ? [] : [AllergyRow(memberID: nora.id, allergen: .peanuts, customText: nil)]
        }
        await store.load(members: [nora])
        #expect(store.allergies.isEmpty)

        // What This Week does when it comes back, with no visit to Library.
        await store.refreshReactions()

        #expect(store.allergies == [MemberAllergies(memberID: nora.id, firstName: "Nora", allergens: [.peanuts])])
        #expect(store.visibleEntries.first?.flags.map(\.summary) == ["Contains peanuts (Nora)"])
        let night = WeekNight(id: UUID(), date: CalendarDay(year: 2026, month: 11, day: 2), effort: .normal, dinnerTime: nil,
                              mealID: peanutButter.id, mealName: peanutButter.name, quickPick: nil, locked: false,
                              attendance: [nora.id: true])
        let card = WeekStore.planCard(for: night, nights: [night], members: [nora], library: store.meals,
                                      allergies: store.allergies, settings: HouseholdSettings(),
                                      today: night.date, minuteNow: 0)
        #expect(card.badges.contains(.allergy("Contains peanuts (Nora)")), "the card Build's dish lands on is flagged")
    }

    @Test func aParentTakingOneAwayReachesThisPhoneToo() async {
        let nora = nora
        let store = library { read in
            read == 1 ? [AllergyRow(memberID: nora.id, allergen: .peanuts, customText: nil)] : []
        }
        await store.load(members: [nora])
        await store.refreshReactions()
        #expect(store.allergies.isEmpty)
    }

    @Test func aFailedAllergyReadKeepsTheFlagsAndStillRefreshesTheRest() async {
        let nora = nora
        let meal = peanutButter
        let reads = Mutex(0)
        let verdict = MealVerdict(mealID: meal.id, memberID: nora.id, kind: .favorite,
                                  reactedOn: CalendarDay(year: 2026, month: 10, day: 1))
        var client = LibraryClient.fake(meals: { _ in [meal] }, allergies: { _ in
            if reads.withLock({ $0 += 1; return $0 }) > 1 { throw URLError(.notConnectedToInternet) }
            return [AllergyRow(memberID: nora.id, allergen: .peanuts, customText: nil)]
        })
        client.verdicts = { _ in [verdict] }
        let store = LibraryStore(householdID: Household.sample.id, client: client)
        await store.load(members: [nora])
        await store.refreshReactions()
        #expect(store.allergies.first?.allergens == [.peanuts], "offline never reads as no allergies")
        #expect(store.reactions.verdicts == [verdict])
    }

    @Test func aRefreshFromBeforeASaveCantBringTheOldOnesBack() async {
        let (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
        let (gate, gateSignal) = AsyncStream.makeStream(of: Void.self)
        let nora = nora
        let reads = Mutex(0)
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(allergies: { _ in
            let read = reads.withLock { $0 += 1; return $0 }
            if read == 2 {
                parkedSignal.yield()
                for await _ in gate { break }
                return []
            }
            return read == 1 ? [] : [AllergyRow(memberID: nora.id, allergen: .eggs, customText: nil)]
        }))
        await store.load(members: [nora])

        let older = Task { await store.refreshReactions() }
        for await _ in parked { break }
        await store.showAllergies(AllergyChoice(allergens: [.eggs]), for: nora, members: [nora])
        gateSignal.yield()
        await older.value
        gateSignal.finish()
        parkedSignal.finish()

        #expect(store.allergies.first?.allergens == [.eggs])
    }

    @Test func aFailedFullLoadIsKnownEvenAfterAGoodOne() async {
        let reads = Mutex(0)
        let store = LibraryStore(householdID: Household.sample.id, client: .fake(allergies: { _ in
            if reads.withLock({ $0 += 1; return $0 }) == 2 { throw URLError(.notConnectedToInternet) }
            return []
        }))
        await store.load(members: [])
        #expect(!store.lastLoadFailed)
        await store.load(members: [])
        #expect(store.lastLoadFailed, "the profile says its allergies may be old")
        #expect(store.hasLoaded)
        await store.load(members: [])
        #expect(!store.lastLoadFailed)
    }
}

@MainActor
struct RhythmEditModelTests {
    private func household(dinner: String) -> Household {
        var settings = HouseholdSettings()
        settings.timeZone = "America/Chicago"
        settings.dinnerTime = dinner
        return Household(id: Household.sample.id, name: "The Smiths", owner: .previewUser, settings: settings)
    }

    /// Serves 18:00 the first time and 17:30 after that: Mom moved dinner while Dad had the screen open.
    private func store(sent: @escaping @Sendable (RhythmChanges) -> Void = { _ in }) -> HouseholdStore {
        let first = household(dinner: "18:00")
        let later = household(dinner: "17:30")
        let fetches = Mutex(0)
        var client = HouseholdClient.fake(myHousehold: {
            fetches.withLock { $0 += 1; return $0 } == 1 ? first : later
        }, members: { _ in Member.sampleFamily })
        client.updateRhythm = { _, changes in sent(changes) }
        return HouseholdStore(userID: .previewUser, client: client)
    }

    @Test func aRefreshUnderneathIsNotAnEdit() async {
        let store = store()
        await store.load()
        let model = RhythmEditModel(store: store)
        await store.refreshQuietly()
        #expect(store.household?.planningSettings.dinnerTime == "17:30")
        #expect(model.changes.isEmpty, "Save stays off with no edits")
    }

    @Test func savingAfterARefreshDoesntWriteTheOldTimeBack() async {
        let sent = Mutex<[RhythmChanges]>([])
        let store = store { changes in sent.withLock { $0.append(changes) } }
        await store.load()
        let model = RhythmEditModel(store: store)
        await store.refreshQuietly()
        model.draft.notificationPreset = .light

        #expect(await model.save())

        var expected = RhythmChanges(from: HouseholdSettings(), to: HouseholdSettings())
        expected.notificationPreset = .light
        #expect(sent.withLock { $0 } == [expected])
        #expect(store.household?.planningSettings.dinnerTime == "17:30")
        #expect(store.household?.planningSettings.notificationPreset == .light)
    }

    @Test func aFailedCheckDoesntBlameARunningPlan() async {
        var client = HouseholdClient.fake(myHousehold: { .sample }, members: { _ in Member.sampleFamily })
        client.latestWeekStart = { _ in throw URLError(.notConnectedToInternet) }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        var changes = RhythmChanges(from: HouseholdSettings(), to: HouseholdSettings())
        changes.weekStart = 3
        #expect(await store.updateRhythm(changes) == false)
        #expect(store.errorMessage == "Foon couldn't check your plan, so nothing was saved. Check your connection and try again.")
    }

    @Test func aMissingTimeZoneIsSavedAlone() async {
        let saved = Mutex<[String]>([])
        let whole = Mutex(0)
        var client = HouseholdClient.fake(myHousehold: { .sample }, members: { _ in Member.sampleFamily },
                                          updateSettings: { _, _ in whole.withLock { $0 += 1 } })
        client.saveTimeZone = { _, zone in saved.withLock { $0.append(zone) } }
        let store = HouseholdStore(userID: .previewUser, client: client, deviceTimeZone: { "America/Denver" })
        await store.load()
        #expect(saved.withLock { $0 } == ["America/Denver"])
        #expect(whole.withLock { $0 } == 0, "a load never carries the rest of the settings along")
        #expect(store.household?.planningSettings.timeZone == "America/Denver")
    }
}

@MainActor
struct StaleMemberEditorTests {
    private let kidID = UUID()

    /// The store holds `current`, as a refresh brought it in; the sheet opened on `opened`.
    private func store(current: Member, as userID: UUID = .previewUser,
                       sent: @escaping @Sendable (MemberChanges) -> Void) async -> HouseholdStore {
        let store = HouseholdStore(userID: userID, client: .fake(
            myHousehold: { .sample }, members: { _ in [current] },
            updateMember: { _, changes in
                sent(changes)
                return current.applying(changes)
            }
        ))
        await store.load()
        return store
    }

    @Test func changingAnAvatarLeavesAPatternAnotherParentJustSet() async {
        let opened = Member.fixture(firstName: "Owen", avatar: "🦊", ageGroup: .kid)
        var current = opened
        let pattern = AwayPattern(from: CalendarDay(year: 2026, month: 11, day: 6))
        current.attendanceDefaults = AttendanceDefaults(usuallyAway: [2], awayPattern: pattern)
        let sent = Mutex<[MemberChanges]>([])
        let store = await store(current: current) { changes in sent.withLock { $0.append(changes) } }
        var draft = MemberDraft(opened)
        draft.avatar = "🐻"

        #expect(await store.save(draft, editing: opened))

        var expected = MemberChanges()
        expected.avatar = .some("🐻")
        #expect(sent.withLock { $0 } == [expected], "no schedule, and no away_pattern: null")
        #expect(store.members.first?.awayPattern == pattern)
        #expect(store.members.first?.usuallyAway == [2])
    }

    @Test func aKidChangingAnAvatarDoesntSendTheStatusAParentJustSet() async {
        let kid = kidID
        let opened = Member.fixture(firstName: "Nora", ageGroup: .kid, userID: kid)
        var current = opened
        current.status = .away
        let sent = Mutex<[MemberChanges]>([])
        let store = await store(current: current, as: kid) { changes in sent.withLock { $0.append(changes) } }
        var draft = MemberDraft(opened)
        draft.avatar = "🐢"

        #expect(await store.save(draft, editing: opened))

        #expect(sent.withLock { $0 }.first?.status == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func aReloadFromBeforeTheSaveCantPutTheOldProfileBack() async {
        let (parked, parkedSignal) = AsyncStream.makeStream(of: Void.self)
        let (gate, gateSignal) = AsyncStream.makeStream(of: Void.self)
        let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
        let fetches = Mutex(0)
        let store = HouseholdStore(userID: .previewUser, client: .fake(
            myHousehold: {
                if fetches.withLock({ $0 += 1; return $0 }) == 2 {
                    parkedSignal.yield()
                    for await _ in gate { break }
                }
                return .sample
            },
            members: { _ in [nora] },
            updateMember: { _, changes in nora.applying(changes) }
        ))
        await store.load()
        var draft = MemberDraft(nora)
        draft.avatar = "🐢"

        let older = Task { await store.refreshQuietly() }
        for await _ in parked { break }
        #expect(await store.save(draft, editing: nora))
        gateSignal.yield()
        await older.value
        gateSignal.finish()
        parkedSignal.finish()

        #expect(store.members.first?.avatar == "🐢")
    }

    @Test func refusalsSayOnlyWhatTheCodeKnows() async {
        func message(_ code: String) async -> String? {
            let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
            let store = HouseholdStore(userID: .previewUser, client: .fake(
                myHousehold: { .sample }, members: { _ in [nora] },
                updateMember: { _, _ in throw PostgrestError(code: code, message: "refused") }
            ))
            await store.load()
            var draft = MemberDraft(nora)
            draft.usuallyAway = [1]
            _ = await store.save(draft, editing: nora)
            return store.errorMessage
        }
        #expect(await message("42501") == "That change isn't allowed. A parent, or the household's owner, can make it.")
        #expect(await message("PGRST116") == "Couldn't find that profile, or you no longer have access to it. Pull to refresh.")
    }
}

struct PassedReturnDateTests {
    private let today = CalendarDay(year: 2026, month: 10, day: 30)

    @Test func awayEndsOnTheReturnDate() {
        #expect(Member.fixture(status: .away).isAway(today: today))
        #expect(Member.fixture(status: .away, awayUntil: today.adding(days: 1)).isAway(today: today))
        #expect(!Member.fixture(status: .away, awayUntil: today).isAway(today: today))
        #expect(!Member.fixture(status: .away, awayUntil: today.adding(days: -3)).isAway(today: today))
        #expect(!Member.fixture().isAway(today: today))
    }

    @Test func someoneBackCountsTowardWhatTheFamilyWants() {
        let ann = Member.fixture(firstName: "Ann")
        let owen = Member.fixture(firstName: "Owen", status: .away, awayUntil: today.adding(days: -3))
        let rita = Member.fixture(firstName: "Rita", status: .removed)
        let request = DinnerRequest(requestedByMemberID: ann.id, mealID: UUID(), plusOnes: [owen.id, rita.id])

        let wanted = RequestBoard.wanted([request], weekStart: today, today: today, members: [ann, owen, rita])

        #expect(wanted.first?.wanters == [ann.id, owen.id], "home by the household's day; a removed member still doesn't count")
    }

    @Test func someoneStillAwayDoesntCount() {
        let ann = Member.fixture(firstName: "Ann")
        let owen = Member.fixture(firstName: "Owen", status: .away, awayUntil: today.adding(days: 3))
        let request = DinnerRequest(requestedByMemberID: ann.id, mealID: UUID(), plusOnes: [owen.id])
        #expect(RequestBoard.wanted([request], weekStart: today, today: today, members: [ann, owen]).isEmpty)
    }

    @Test func theEditorOpensOnHomeOnceTheDateHasPassed() {
        var draft = MemberDraft(Member.fixture(status: .away, awayUntil: today.adding(days: -1)))
        draft = draft.settlingReturn(today: today)
        #expect(draft.status == .active)
        #expect(draft.awayUntil == nil)

        let stillAway = MemberDraft(Member.fixture(status: .away, awayUntil: today.adding(days: 1)))
        #expect(stillAway.settlingReturn(today: today) == stillAway)
        let noDate = MemberDraft(Member.fixture(status: .away))
        #expect(noDate.settlingReturn(today: today) == noDate, "away with no date stays away until someone says")
    }
}

@MainActor
struct AllergyCaseAndMergeTests {
    private let nora = UUID()

    @Test func kiwiAndKiwiAreOneAllergy() {
        let answer = OnboardingModel.Answer(otherText: "kiwi, Kiwi, KIWI, mango")
        #expect(AllergyChoice(answer).custom.count == 2)
        #expect(AllergyChoice(answer) == AllergyChoice(custom: ["Kiwi", "Mango"]), "capitals alone aren't a change")
    }

    @Test func rowsThatAlreadyDifferByCaseCollapseOnSave() async throws {
        let nora = nora
        let sent = Mutex<[[String]]>([])
        let model = AllergyEditorModel(
            memberID: nora, householdID: Household.sample.id,
            household: .fake(setAllergies: { _, _, custom in sent.withLock { $0.append(custom) } }),
            library: .fake(allergies: { _ in [
                AllergyRow(memberID: nora, allergen: .custom, customText: "kiwi"),
                AllergyRow(memberID: nora, allergen: .custom, customText: "Kiwi")
            ] })
        )
        await model.load()
        model.answer.allergens = [.eggs]
        _ = try #require(await model.save())
        #expect(sent.withLock { $0 }.first?.count == 1)
    }

    @Test func recasingAnotherParentsEntryDoesntDuplicateIt() {
        let old = AllergyChoice(custom: ["kiwi"])
        let edit = AllergyChoice(custom: ["kiwi", "MANGO"])
        let current = AllergyChoice(custom: ["Kiwi", "mango"])
        #expect(edit.merging(editFrom: old, onto: current).custom.count == 2)
    }

    @Test func removingOneCatchesItWhateverTheCapitalsNowAre() {
        let old = AllergyChoice(custom: ["kiwi"])
        let edit = AllergyChoice()
        let current = AllergyChoice(custom: ["Kiwi"])
        #expect(edit.merging(editFrom: old, onto: current).custom.isEmpty)
    }

    @Test func aRemovalAnotherParentMadeWhileThisWasOpenStays() {
        // This screen opened with milk and peanuts. Another parent took peanuts away. This parent adds eggs.
        let old = AllergyChoice(allergens: [.milk, .peanuts])
        let edit = AllergyChoice(allergens: [.milk, .peanuts, .eggs])
        let current = AllergyChoice(allergens: [.milk])
        #expect(edit.merging(editFrom: old, onto: current).allergens == [.milk, .eggs])
    }
}
