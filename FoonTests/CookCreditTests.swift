import Foundation
import Synchronization
import Testing
@testable import Foon

struct CookCreditTests {
    private let ann = UUID(), ben = UUID(), nora = UUID()
    private let today = CalendarDay(year: 2026, month: 11, day: 12)

    private func log(_ day: CalendarDay, cook: UUID?, meal: UUID? = UUID()) -> DinnerLog {
        DinnerLog(id: UUID(), nightID: UUID(), date: day, mealID: meal, mealName: "Chili", quickPick: meal == nil ? .takeout : nil,
                  cookedByMemberID: cook)
    }

    @Test func countsThisMonthsCooksWithTheirThanks() {
        let a1 = log(today.adding(days: -1), cook: ann), a2 = log(today.adding(days: -3), cook: ann)
        let b1 = log(today.adding(days: -2), cook: ben)
        let lastMonth = log(CalendarDay(year: 2026, month: 10, day: 30), cook: ben)
        let nobody = log(today.adding(days: -4), cook: nil)
        let takeout = log(today.adding(days: -5), cook: ann, meal: nil)
        let thanks = [ChefThanks(logID: b1.id, fromMemberID: nora), ChefThanks(logID: b1.id, fromMemberID: ann),
                      ChefThanks(logID: a1.id, fromMemberID: nora)]
        let tally = CookCredit.thisMonth(logs: [a1, a2, b1, lastMonth, nobody, takeout], thanks: thanks, today: today)
        #expect(Set(tally) == [CookCredit.Tally(memberID: ann, dinners: 2, thanks: 1),
                               CookCredit.Tally(memberID: ben, dinners: 1, thanks: 2)],
                "last month, no cook, and takeout don't count")
    }

    @Test func thanksCardsAreForCookedDishesWhileTheCardIsOpen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let yesterday = WeekNight(id: UUID(), date: today.adding(days: -1), effort: .normal, dinnerTime: "18:00",
                                  mealID: UUID(), mealName: "Chili", quickPick: nil, locked: false, attendance: [:])
        let cooked = DinnerLog(id: UUID(), nightID: yesterday.id, date: yesterday.date, mealID: yesterday.mealID,
                               mealName: "Chili", quickPick: nil, cookedByMemberID: ann, leftovers: false)
        let uncooked = DinnerLog(id: UUID(), nightID: yesterday.id, date: yesterday.date, mealID: yesterday.mealID,
                                 mealName: "Chili", quickPick: nil)
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 19, minute: 30))!
        #expect(CookCredit.recent(nights: [yesterday], logs: [cooked, uncooked], defaultDinnerTime: "18:00",
                                  now: morning, calendar: calendar) == [cooked])
        #expect(CookCredit.recent(nights: [yesterday], logs: [cooked], defaultDinnerTime: "18:00", now: evening,
                                  calendar: calendar).isEmpty, "gone by the next evening")
    }
}

struct CookCreditSettledTests {
    private let ann = UUID(), ben = UUID()
    private let today = CalendarDay(year: 2026, month: 11, day: 12)
    private var calendar: Calendar { DinnerPrompts.calendar(for: HouseholdSettings()) }
    private var morning: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9))! }

    private var night: WeekNight {
        WeekNight(id: nightID, date: today.adding(days: -1), effort: .normal, dinnerTime: "18:00", mealID: UUID(),
                  mealName: "Chili", quickPick: nil, locked: false, attendance: [:])
    }
    private let nightID = UUID()

    private func log(verified: Bool, leftovers: Bool?, cook: UUID) -> DinnerLog {
        DinnerLog(id: UUID(), nightID: nightID, date: today.adding(days: -1), mealID: UUID(), mealName: "Chili", quickPick: nil,
                  cookedByMemberID: cook, leftovers: leftovers, verified: verified)
    }

    private func recent(_ log: DinnerLog, me: UUID?) -> [DinnerLog] {
        CookCredit.recent(nights: [night], logs: [log], me: me, defaultDinnerTime: "18:00", now: morning, calendar: calendar)
    }

    /// A claim's default lands with the first tap. A thanks locks the cook, so nobody's offered one on a guess.
    @Test func nobodyElseCanThankUntilWhoCookedIsSettled() {
        #expect(recent(log(verified: true, leftovers: nil, cook: ann), me: ben).isEmpty, "the follow-up isn't answered")
        #expect(recent(log(verified: false, leftovers: nil, cook: ann), me: ben).isEmpty, "saved overnight, unconfirmed")
        #expect(recent(log(verified: false, leftovers: true, cook: ann), me: ben).isEmpty, "answered but unconfirmed")
        #expect(recent(log(verified: true, leftovers: false, cook: ann), me: ben).count == 1, "settled")
    }

    @Test func theCookSeesItFromTheStartSoTheyCanSayThatWasntMe() {
        #expect(recent(log(verified: false, leftovers: nil, cook: ann), me: ann).count == 1)
        #expect(recent(log(verified: true, leftovers: nil, cook: ann), me: ann).count == 1)
    }

    @Test func whoCanTakeOffACook() {
        let me = Member.fixture(firstName: "Ann", userID: UUID())
        let hasAccount = Member.fixture(firstName: "Ben", userID: UUID())
        let noAccount = Member.fixture(firstName: "Nora")
        let family = [me, hasAccount, noAccount]
        func can(_ cook: Member, canPlan: Bool = false, thanks: [ChefThanks] = []) -> Bool {
            CookCredit.canTakeOffCook(log(verified: true, leftovers: nil, cook: cook.id), thanks: thanks, me: me, canPlan: canPlan,
                                      members: family)
        }
        #expect(can(me), "themselves")
        #expect(can(noAccount), "a profile nobody has claimed")
        #expect(!can(hasAccount), "not someone else with an account")
        #expect(can(hasAccount, canPlan: true), "a planner can")
        #expect(!can(me, thanks: [ChefThanks(logID: UUID(), fromMemberID: UUID())]), "not once thanked: the server keeps them")
    }
}

@MainActor
struct CookCreditStoreTests {
    @Test func loadsFromTheStartOfTheMonthAndSendsThanks() async {
        let since = Mutex<[CalendarDay]>([])
        let thanked = Mutex<[UUID]>([])
        let log = DinnerLog(id: UUID(), nightID: UUID(), date: CalendarDay(year: 2026, month: 11, day: 11), mealID: UUID(),
                            mealName: "Chili", quickPick: nil, cookedByMemberID: UUID())
        var client = DinnerClient.preview
        client.logs = { _, day in since.withLock { $0.append(day) }; return [] }
        client.thanks = { _, day in since.withLock { $0.append(day) }; return [] }
        client.thankTheChef = { id in thanked.withLock { $0.append(id) } }
        let noon = DinnerPrompts.calendar(for: HouseholdSettings())
            .date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
        let store = DinnerStore(householdID: UUID(), client: client, now: { noon })
        await store.load(settings: HouseholdSettings())
        #expect(since.withLock { $0 } == [CalendarDay(year: 2026, month: 11, day: 1), CalendarDay(year: 2026, month: 11, day: 1)])
        #expect(await store.thankTheChef(log))
        #expect(thanked.withLock { $0 } == [log.id])
    }

    @Test func onTheFirstOfTheMonthLastNightStillLoads() async {
        let since = Mutex<CalendarDay?>(nil)
        var client = DinnerClient.preview
        client.logs = { _, day in since.withLock { $0 = day }; return [] }
        let first = DinnerPrompts.calendar(for: HouseholdSettings())
            .date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!
        let store = DinnerStore(householdID: UUID(), client: client, now: { first })
        await store.load(settings: HouseholdSettings())
        #expect(since.withLock { $0 } == CalendarDay(year: 2026, month: 10, day: 31))
    }
}

struct ThanksCopyTests {
    @Test func theCookNeverSeesZero() {
        #expect(ThanksChefCard.cookLine(thanks: 0, dish: "chili") == "Thanks for cooking the chili")
        #expect(ThanksChefCard.cookLine(thanks: 1, dish: "chili") == "Thanked once for the chili")
        #expect(ThanksChefCard.cookLine(thanks: 2, dish: "chili") == "Thanked twice for the chili")
        #expect(ThanksChefCard.cookLine(thanks: 4, dish: "chili") == "Thanked 4 times for the chili")
    }
}
