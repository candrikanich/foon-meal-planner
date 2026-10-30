import Foundation
import Supabase
import Synchronization
import Testing
@testable import Foon

struct NightClaimsTests {
    private let today = CalendarDay(year: 2037, month: 11, day: 3)
    private let ann = Member.fixture(firstName: "Ann", role: .planner, userID: UUID())
    private let ben = Member.fixture(firstName: "Ben", userID: UUID())
    private let nora = Member.fixture(firstName: "Nora", ageGroup: .kid)
    private let owen = Member.fixture(firstName: "Owen", ageGroup: .kid, userID: UUID())
    private let tot: Member = {
        var tot = Member.fixture(firstName: "Tot", ageGroup: .kid)
        tot.eatsSeparately = true
        return tot
    }()
    private var family: [Member] { [ann, ben, nora, owen, tot] }

    private func night(_ days: Int = 2, meal: UUID? = UUID(), pick: QuickPick? = nil, out: [UUID] = []) -> WeekNight {
        var attendance = Dictionary(uniqueKeysWithValues: family.map { ($0.id, true) })
        for id in out { attendance[id] = false }
        return WeekNight(id: UUID(), date: today.adding(days: days), effort: .normal, dinnerTime: nil, mealID: meal,
                         mealName: meal == nil ? nil : "Chili", quickPick: pick, locked: false, attendance: attendance)
    }

    private func claim(_ night: WeekNight, by member: Member, entered: UUID? = nil) -> NightClaim {
        NightClaim(nightID: night.id, memberID: member.id, enteredByMemberID: entered ?? member.id, date: night.date,
                   nightMealID: night.mealID, nightQuickPick: night.quickPick,
                   memberIsOut: night.attendance[member.id] == false)
    }

    private func standing(_ claim: NightClaim, _ night: WeekNight, away: [AwayDates] = [], members: [Member]? = nil)
        -> NightClaims.Standing? {
        NightClaims.standing(of: claim, on: night, members: members ?? family, away: away, today: today)
    }

    private func can(_ member: Member, _ night: WeekNight, claims: [NightClaim] = [], log: DinnerLog? = nil,
                     away: [AwayDates] = []) -> Bool {
        NightClaims.canClaim(member, night: night, claims: claims, log: log, members: family, away: away, today: today)
    }

    private func log(_ night: WeekNight, cook: UUID?, meal: UUID? = UUID(), pick: QuickPick? = nil) -> DinnerLog {
        DinnerLog(id: UUID(), nightID: night.id, date: night.date, mealID: meal, mealName: meal == nil ? nil : "Chili",
                  quickPick: pick, cookedByMemberID: cook)
    }

    // MARK: - What each change to a night does

    @Test func aDifferentDishOrAnEmptyNightLeavesThePromise() {
        var changing = night()
        let promise = claim(changing, by: ben)
        #expect(standing(promise, changing) == .cooking)
        changing.mealID = UUID()
        #expect(standing(promise, changing) == .cooking, "Swap, Build, Fill, Shuffle")
        changing.stashItemID = UUID()
        #expect(standing(promise, changing) == .cooking, "from the freezer")
        changing.stashItemID = nil
        changing.mealID = nil
        changing.mealName = nil
        #expect(standing(promise, changing) == .cooking, "cleared: they still said they'd cook")
    }

    @Test func aQuickPickPutsItOnHoldAndBackToADishBringsItBack() {
        var changing = night()
        let promise = claim(changing, by: ben)
        changing.mealID = nil
        changing.quickPick = .takeout
        #expect(standing(promise, changing) == .onHold(.quickPick(.takeout)))
        #expect(NightClaims.cookLine(night: changing, claims: [promise], log: nil, members: family, me: nil, away: [],
                                     today: today) == nil, "the card doesn't say Ben's cooking takeout")
        changing.quickPick = nil
        changing.mealID = UUID()
        #expect(standing(promise, changing) == .cooking)
    }

    @Test func theNightDoubledIntoLeftoversIsOnHold() {
        var later = night()
        let promise = claim(later, by: ben)
        later.mealID = nil
        later.quickPick = .leftovers
        later.leftoversFrom = UUID()
        #expect(standing(promise, later) == .onHold(.quickPick(.leftovers)))
    }

    @Test func beingMarkedOutPutsItOnHoldAndLetsSomeoneElseTakeTheNight() {
        let out = night(out: [ben.id])
        let promise = claim(out, by: ben)
        #expect(standing(promise, out) == .onHold(.out))
        #expect(NightClaims.cookLine(night: out, claims: [promise], log: nil, members: family, me: nil, away: [],
                                     today: today) == nil, "the card doesn't say someone who's out is cooking")
        #expect(can(ann, out, claims: [promise]))
        let home = night()
        #expect(!can(ann, home, claims: [claim(home, by: ben)]), "while they're home, it's theirs")
    }

    @Test func awayDatesMeanItDoesntCount() {
        let held = night()
        let away = [AwayDates(from: held.date, to: held.date)]
        #expect(standing(claim(held, by: ben), held, away: away) == nil)
        #expect(!can(ann, held, away: away))
    }

    @Test func tonightKeepsADinnerItAlreadyHasInsideAwayDates() {
        let tonight = night(0)
        let away = [AwayDates(from: today, to: today)]
        #expect(standing(claim(tonight, by: ben), tonight, away: away) == .cooking, "tonight still reads as itself")
        let cleared = night(0, meal: nil)
        #expect(standing(claim(cleared, by: ben), cleared, away: away) == nil, "but swapped off, it reads away")
    }

    @Test func someoneGoneOrWhoNowEatsSeparatelyDoesntCount() {
        let held = night()
        var gone = ben
        gone.status = .removed
        #expect(standing(claim(held, by: gone), held, members: [ann, gone]) == nil)
        #expect(standing(claim(held, by: ben), held, members: [ann]) == nil, "not on the family list")
        var separate = ben
        separate.eatsSeparately = true
        #expect(standing(claim(held, by: separate), held, members: [ann, separate]) == nil)
    }

    // MARK: - Who's offered

    @Test func anyoneHomeCanOfferOnANightStillAhead() {
        #expect(can(ann, night()))
        #expect(can(ben, night()), "a non-planner")
        #expect(can(nora, night()), "a kid")
        #expect(can(ann, night(0)), "tonight")
        #expect(can(ann, night(meal: nil)), "an empty night")
    }

    @Test func aNightIsntOfferedWhenTheresNothingToPromise() {
        #expect(!can(ann, night(-1)), "last night, by the household's day")
        #expect(!can(ann, night(pick: .takeout)), "a quick pick")
        #expect(!can(tot, night()), "someone who eats separately")
        #expect(!can(ben, night(out: [ben.id])), "someone who's out")
        let logged = night(0)
        #expect(!can(ann, logged, log: log(logged, cook: nil)), "a logged dinner")
    }

    @Test func aNightWithACookIsTaken() {
        let held = night()
        let claims = [claim(held, by: ben)]
        #expect(!can(ann, held, claims: claims))
        #expect(!can(ben, held, claims: claims), "including by them: it's already said")
    }

    @Test func passThePhoneOffersYouThenProfilesWithNoAccount() {
        let offered = NightClaims.whoCanClaim(me: ben, night: night(), claims: [], log: nil, members: family, away: [], today: today)
        #expect(offered.map(\.id) == [ben.id, nora.id], "not Ann or Owen, who have accounts; not Tot, who eats separately")
    }

    @Test func releasingMatchesTheServer() {
        let held = night()
        #expect(NightClaims.canRelease(claim(held, by: ben), me: ben, canPlan: false, members: family), "their own")
        #expect(!NightClaims.canRelease(claim(held, by: ben), me: owen, canPlan: false, members: family), "not a kid's to end")
        #expect(NightClaims.canRelease(claim(held, by: ben), me: ann, canPlan: true, members: family), "a planner")
        #expect(NightClaims.canRelease(claim(held, by: nora), me: owen, canPlan: false, members: family), "shared phone")
    }

    // MARK: - What the card says

    @Test func aLogSaysWhatHappenedNotThePromise() {
        let tonight = night(0)
        let promise = claim(tonight, by: ben)
        func line(_ log: DinnerLog?) -> DayCardModel.Cook? {
            NightClaims.cookLine(night: tonight, claims: [promise], log: log, members: family, me: ben.id, away: [], today: today)
        }
        #expect(line(nil)?.memberID == ben.id)
        #expect(line(nil)?.tense == .willCook)
        #expect(line(nil)?.isYou == true)
        #expect(line(log(tonight, cook: ann.id))?.memberID == ann.id, "someone corrected who cooked")
        #expect(line(log(tonight, cook: ann.id))?.tense == .cooked)
        #expect(line(log(tonight, cook: nil)) == nil, "someone cleared it")
        #expect(line(log(tonight, cook: ben.id, meal: nil, pick: .takeout)) == nil, "We had something else: takeout")
    }

    @Test func aNightGoneByWithNoLogSaysNothing() {
        let past = night(-1)
        #expect(NightClaims.cookLine(night: past, claims: [claim(past, by: ben)], log: nil, members: family, me: nil,
                                     away: [], today: today) == nil)
    }

    @Test func theWordsCarryTheDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let thursday = CalendarDay(year: 2037, month: 11, day: 5)
        #expect(ClaimText.offer(today, today: today, calendar: calendar) == "I'll cook tonight")
        #expect(ClaimText.offer(today.adding(days: 1, calendar: calendar), today: today, calendar: calendar) == "I'll cook tomorrow")
        #expect(ClaimText.offer(thursday, today: today, calendar: calendar) == "I'll cook Thursday")
        #expect(ClaimText.willCook("Ben", thursday, today: today, calendar: calendar) == "Ben will cook Thursday")
        #expect(ClaimText.willCook("Ben", thursday.adding(days: 7, calendar: calendar), today: today, calendar: calendar)
                == "Ben will cook Thursday, Nov 12", "a week off, it says which Thursday")
    }

    @Test func theCardReadsItToVoiceOver() {
        var model = DayCardModel(date: today, effort: .normal, slot: .empty, attendance: [], badges: [], isLocked: false)
        model.cook = DayCardModel.Cook(member: ben, isYou: false, tense: .willCook)
        model.jobs = [DayCardModel.JobLine(title: "Do the dishes", firstName: "Nora")]
        let summary = DayCardText.accessibilitySummary(model, today: today)
        #expect(summary.contains("Ben is cooking"))
        #expect(summary.contains("Do the dishes: Nora"))
    }

    // MARK: - The planner's note

    private func news(_ claims: [NightClaim], me: Member? = nil, canPlan: Bool = true, logged: Set<UUID> = [],
                      away: [AwayDates] = [], dismissed: Set<UUID> = []) -> [NightClaim] {
        NightClaims.news(claims: claims, me: (me ?? ann).id, canPlan: canPlan, members: family, logged: logged, away: away,
                         today: today, dismissed: dismissed)
    }

    @Test func plannersHearOfSomeoneElsesOffer() {
        let promise = claim(night(), by: ben)
        #expect(news([promise]) == [promise])
        #expect(news([promise], me: owen, canPlan: false).isEmpty, "a planner's note, not a member's")
    }

    @Test func notTheirOwnOrWhatTheyEnteredPassingThePhone() {
        #expect(news([claim(night(), by: ann)]).isEmpty, "their own")
        #expect(news([claim(night(), by: nora, entered: ann.id)]).isEmpty, "they handed Nora the phone")
        let otherPhone = claim(night(), by: nora, entered: ben.id)
        #expect(news([otherPhone]) == [otherPhone], "on Ben's phone, they hear of it")
    }

    @Test func onlyWhatStillStands() {
        let promise = claim(night(), by: ben)
        #expect(news([promise], dismissed: [promise.id]).isEmpty, "dismissed on this device")
        #expect(news([promise], logged: [promise.nightID]).isEmpty, "logged already")
        #expect(news([claim(night(-1), by: ben)]).isEmpty, "gone by")
        #expect(news([claim(night(pick: .takeout), by: ben)]).isEmpty, "on hold: a quick pick")
        #expect(news([claim(night(out: [ben.id]), by: ben)]).isEmpty, "on hold: out")
        #expect(news([promise], away: [AwayDates(from: promise.date, to: promise.date)]).isEmpty, "away")
    }

    @Test func soonestFirst() {
        let later = claim(night(5), by: ben), sooner = claim(night(1), by: owen)
        #expect(news([later, sooner]) == [sooner, later])
    }

    @Test func aClaimDecodesWithItsNight() throws {
        let night = UUID(), ben = UUID(), id = UUID()
        let json = """
            {"id": "\(id)", "night_id": "\(night)", "member_id": "\(ben)", "entered_by_member_id": null,
             "plan_nights": {"date": "2037-11-05", "meal_id": null, "quick_pick": "takeout",
                             "night_attendance": [{"member_id": "\(UUID())", "expected": true},
                                                  {"member_id": "\(ben)", "expected": false}]}}
            """
        let claim = try JSONDecoder().decode(NightClaim.self, from: Data(json.utf8))
        #expect(claim.date == CalendarDay(year: 2037, month: 11, day: 5))
        #expect(claim.nightQuickPick == .takeout)
        #expect(claim.memberIsOut)
    }
}

private func refusal(_ code: String) -> PostgrestError {
    PostgrestError(code: code, message: "refused")
}

@MainActor
struct NightClaimsStoreTests {
    private let noon = DinnerPrompts.calendar(for: HouseholdSettings())
        .date(from: DateComponents(year: 2037, month: 11, day: 3, hour: 12))!

    private func store(_ client: DinnerClient) -> DinnerStore {
        DinnerStore(householdID: UUID(), client: client, now: { self.noon })
    }

    @Test func offeringSavesThenReadsItBack() async {
        let saved = Mutex<[(UUID, UUID)]>([])
        let night = UUID(), ben = UUID()
        var client = DinnerClient.preview
        client.claimNight = { nightID, memberID in saved.withLock { $0.append((nightID, memberID)) } }
        client.claims = { _, _ in
            saved.withLock { $0.isEmpty } ? [] : [NightClaim(nightID: night, memberID: ben, date: CalendarDay(year: 2037, month: 11, day: 5))]
        }
        let store = store(client)
        #expect(await store.claim(nightID: night, memberID: ben))
        #expect(saved.withLock { $0.map(\.0) } == [night])
        #expect(store.claims.map(\.memberID) == [ben], "the card shows it")
        #expect(store.claimMessage == nil)
    }

    /// Two phones: the second is told clearly and shown who has it, rather than overwriting or a connection error.
    @Test func someoneElseGotThereFirst() async {
        let night = UUID(), ann = UUID()
        var client = DinnerClient.preview
        client.claimNight = { _, _ in throw refusal("FD005") }
        client.claims = { _, _ in [NightClaim(nightID: night, memberID: ann, date: CalendarDay(year: 2037, month: 11, day: 5))] }
        let store = store(client)
        #expect(await store.claim(nightID: night, memberID: UUID()) == false)
        #expect(store.claimMessage == "Someone else just said they'd cook that night.")
        #expect(store.claims.map(\.memberID) == [ann], "and the card now shows who")
    }

    @Test func eachRefusalHasItsOwnWords() async {
        let cases = [("FD006", "That dinner has already happened, so its cook is set on the log."),
                     ("FD007", "The family's away that night, so nobody's cooking."),
                     ("FD008", "They eat separately, so they aren't asked to cook."),
                     ("FD009", "That night's a quick pick now, so there's nothing to cook."),
                     ("FD010", "They're down as out that night. A planner can change who's home."),
                     ("42501", "You can offer for yourself, or for someone without their own account.")]
        for (code, words) in cases {
            var client = DinnerClient.preview
            client.claimNight = { _, _ in throw refusal(code) }
            let store = store(client)
            await store.claim(nightID: UUID(), memberID: UUID())
            #expect(store.claimMessage == words, "\(code)")
        }
    }

    @Test func notReachingTheServerSaysThat() async {
        var client = DinnerClient.preview
        client.claimNight = { _, _ in throw URLError(.notConnectedToInternet) }
        let store = store(client)
        await store.claim(nightID: UUID(), memberID: UUID())
        #expect(store.claimMessage == "Couldn't save that. Check your connection and try again.")
    }

    @Test func anAwayRefusalAsksForTheDates() async {
        var client = DinnerClient.preview
        client.claimNight = { _, _ in throw refusal("FD007") }
        let store = store(client)
        await store.claim(nightID: UUID(), memberID: UUID())
        #expect(store.claimAwayRefusals == 1, "this phone hasn't heard about the dates")
    }

    @Test func takingBackIsByTheClaimAndHasItsOwnRefusal() async {
        let released = Mutex<[UUID]>([])
        let claim = NightClaim(nightID: UUID(), memberID: UUID(), date: CalendarDay(year: 2037, month: 11, day: 5))
        var client = DinnerClient.preview
        client.releaseClaim = { id in released.withLock { $0.append(id) } }
        let store = store(client)
        #expect(await store.release(claim))
        #expect(released.withLock { $0 } == [claim.id])

        var refusing = DinnerClient.preview
        refusing.releaseClaim = { _ in throw refusal("42501") }
        let other = self.store(refusing)
        #expect(await other.release(claim) == false)
        #expect(other.claimMessage == "Only they or a planner can take that back.")
    }

    @Test func theFirstResponderStillGetsAskedWhenAClaimFilledInTheCook() {
        let calendar = DinnerPrompts.calendar(for: HouseholdSettings())
        let me = UUID()
        let tonight = WeekNight(id: UUID(), date: CalendarDay(year: 2037, month: 11, day: 3), effort: .normal, dinnerTime: "18:00",
                                mealID: UUID(), mealName: "Chili", quickPick: nil, locked: false, attendance: [me: true])
        let log = DinnerLog(id: UUID(), nightID: tonight.id, date: tonight.date, mealID: tonight.mealID, mealName: "Chili",
                            quickPick: nil, cookedByMemberID: UUID(), confirmedByMemberID: me)
        let evening = calendar.date(from: DateComponents(year: 2037, month: 11, day: 3, hour: 19, minute: 30))!
        #expect(DinnerPrompts.extras(nights: [tonight], logs: [log], me: me, defaultDinnerTime: "18:00", now: evening,
                                     calendar: calendar).map(\.night.id) == [tonight.id])
    }
}
