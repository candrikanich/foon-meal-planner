import Foundation
import Supabase
import Testing
@testable import Foon

struct DinnerJobsTests {
    private let sunday = CalendarDay(year: 2037, month: 11, day: 1)
    private let family: [Member] = (0..<4).map { .fixture(firstName: "Person \($0)", userID: UUID()) }
    private var everyone: Set<UUID> { Set(family.map(\.id)) }
    private let both = DinnerJobSettings(jobs: [.setTable, .dishes])
    private let oneJob = DinnerJobSettings(jobs: [.dishes])

    private func week(from start: CalendarDay? = nil, home: (Int) -> Set<UUID>) -> [WeekNight] {
        let start = start ?? sunday
        return (0..<7).map { index in
            let here = home(index)
            return WeekNight(id: UUID(), date: start.adding(days: index), effort: .normal, dinnerTime: nil, mealID: UUID(),
                             mealName: "Chili", quickPick: nil, locked: false,
                             attendance: Dictionary(uniqueKeysWithValues: family.map { ($0.id, here.contains($0.id)) }))
        }
    }

    private func assign(_ nights: [WeekNight], _ settings: DinnerJobSettings? = nil, members: [Member]? = nil,
                        cooks: [UUID: UUID] = [:], away: [AwayDates] = []) -> [UUID: [DinnerJobs.Assignment]] {
        DinnerJobs.assign(nights: nights, settings: settings ?? both, members: members ?? family, cooks: cooks, away: away,
                          today: sunday)
    }

    private func turns(_ assigned: [UUID: [DinnerJobs.Assignment]]) -> [UUID: Int] {
        assigned.values.flatMap { $0 }.reduce(into: [:]) { $0[$1.memberID, default: 0] += 1 }
    }

    @Test func offUntilAPlannerPicksAJob() {
        #expect(assign(week { _ in everyone }, DinnerJobSettings()).isEmpty)
        #expect(HouseholdSettings().dinnerJobs.jobs.isEmpty, "off by default")
    }

    @Test func aRotationIsFair() {
        let counts = turns(assign(week { _ in everyone }))
        // Fourteen jobs among four people.
        #expect(counts.values.sorted() == [3, 3, 4, 4])
    }

    @Test func fairAcrossJobsWhenThereAreMoreJobsThanCanSplitEvenly() {
        let three = Set(family.prefix(3).map(\.id))
        let nights = week { _ in three }
        let assigned = assign(nights)
        var counts = Dictionary(uniqueKeysWithValues: three.map { ($0, 0) })
        for night in nights {
            for job in assigned[night.id] ?? [] { counts[job.memberID, default: 0] += 1 }
            #expect((counts.values.max() ?? 0) - (counts.values.min() ?? 0) <= 1, "even all week, not just by Saturday")
        }
    }

    /// "Do the dishes" can't be a job that never shows just because it's last.
    @Test func withTooFewPeopleADifferentJobDropsEachNight() {
        let two = Set(family.prefix(2).map(\.id))
        let nights = week { _ in two }
        let assigned = assign(nights, DinnerJobSettings(jobs: [.setTable, .clearTable, .dishes]))
        let counts = assigned.values.flatMap { $0 }.reduce(into: [DinnerJob: Int]()) { $0[$1.job, default: 0] += 1 }
        #expect(counts.count == 3, "every job turns up")
        #expect((counts.values.max() ?? 0) - (counts.values.min() ?? 0) <= 1, "evenly")
        for night in nights {
            let jobs = assigned[night.id]?.map(\.job) ?? []
            #expect(jobs == DinnerJob.allCases.filter(jobs.contains), "shown in the usual order")
        }
    }

    private func forWeek(_ nights: [WeekNight], claims: [NightClaim] = [], today: CalendarDay) -> [UUID: [DinnerJobs.Assignment]] {
        DinnerJobs.forWeek(nights: nights, settings: both, members: family, claims: claims, away: [], today: today)
    }

    /// Ben offered Sunday. Sunday goes by, and whoever answers who cooked: Monday on read the same as they did on Sunday.
    @Test func aPromisedNightGoingByDoesntReshuffleTheWeek() {
        let nights = week { _ in everyone }
        let claims = [NightClaim(nightID: nights[0].id, memberID: family[1].id, date: nights[0].date)]
        let onSunday = forWeek(nights, claims: claims, today: nights[0].date)
        let onWednesday = forWeek(nights, claims: claims, today: nights[3].date)
        #expect(onSunday == onWednesday)
        #expect(!(onSunday[nights[0].id] ?? []).map(\.memberID).contains(family[1].id), "and Sunday's cook had it off")
    }

    /// A week across two months: logs before the 1st aren't loaded, and it makes no difference, since logs aren't read.
    @Test func aWeekAcrossTwoMonthsReadsTheSame() {
        let start = CalendarDay(year: 2037, month: 10, day: 28)
        let nights = week(from: start) { _ in everyone }
        let claims = [NightClaim(nightID: nights[1].id, memberID: family[2].id, date: nights[1].date)]
        let inOctober = forWeek(nights, claims: claims, today: nights[1].date)
        let inNovember = forWeek(nights, claims: claims, today: nights[5].date)
        #expect(inOctober == inNovember)
    }

    @Test func aClaimOnHoldDoesntGiveTheNightOff() {
        var nights = week { _ in everyone }
        nights[0].attendance[family[1].id] = false
        let claims = [NightClaim(nightID: nights[0].id, memberID: family[1].id, date: nights[0].date)]
        #expect(NightClaims.cooks(nights: nights, claims: claims, members: family, away: [], today: sunday).isEmpty)
    }

    @Test func eachJobGoesRoundToo() {
        let assigned = assign(week { _ in everyone })
        let dishes = assigned.values.flatMap { $0 }.filter { $0.job == .dishes }
        let counts = dishes.reduce(into: [UUID: Int]()) { $0[$1.memberID, default: 0] += 1 }
        #expect(counts.count == 4, "nobody's stuck with the same one")
        #expect((counts.values.max() ?? 0) - (counts.values.min() ?? 0) <= 1)
    }

    @Test func itsTheSameOnEveryPhone() {
        let nights = week { _ in everyone }
        #expect(assign(nights) == assign(nights.reversed(), members: family.reversed()),
                "whatever order they load in")
    }

    @Test func whoStartsMovesOnEachWeek() {
        var totals: [UUID: Int] = [:]
        var starters: Set<UUID> = []
        for offset in 0..<4 {
            let nights = week(from: sunday.adding(days: 7 * offset)) { _ in everyone }
            let assigned = assign(nights, oneJob)
            starters.insert(assigned[nights[0].id]?.first?.memberID ?? UUID())
            totals.merge(turns(assigned), uniquingKeysWith: +)
        }
        #expect(starters.count == 4)
        #expect(totals.values.sorted() == [7, 7, 7, 7], "seven dinners a week, four weeks, four people")
    }

    @Test func onlyWhosHome() {
        let only = family[2].id
        let assigned = assign(week { _ in [only] }, oneJob)
        #expect(Set(assigned.values.flatMap { $0 }.map(\.memberID)) == [only])
    }

    @Test func comingBackTheyTakeATurnAndTheRestStayEven() {
        let regular = Set(family.prefix(3).map(\.id)), rare = family[3].id
        // Out until Friday, on a seven-night week.
        let nights = week { $0 < 5 ? regular : everyone }
        let assigned = assign(nights, oneJob)
        let friday = assigned[nights[5].id]?.first?.memberID
        #expect(friday == rare, "they've done least, so it's their turn")
        let counts = turns(assigned)
        let regulars = regular.map { counts[$0, default: 0] }
        #expect((regulars.max() ?? 0) - (regulars.min() ?? 0) <= 1, "the people who were home stay even")
    }

    @Test func theCookGetsTheNightOff() {
        let cook = family[0].id
        let nights = week { _ in everyone }
        let assigned = assign(nights, cooks: Dictionary(uniqueKeysWithValues: nights.map { ($0.id, cook) }))
        #expect(!assigned.values.flatMap { $0 }.map(\.memberID).contains(cook))
    }

    @Test func nobodyGetsTwoInANightAndAJobWithNobodyLeftDoesntShow() {
        let two = Set(family.prefix(2).map(\.id))
        let nights = week { _ in two }
        let three = DinnerJobSettings(jobs: [.setTable, .clearTable, .dishes])
        let assigned = assign(nights, three)
        #expect(assigned[nights[0].id]?.count == 2)
        #expect(Set(assigned[nights[0].id]?.map(\.memberID) ?? []).count == 2)
    }

    @Test func aPlannerLeavesSomeoneOutAndEatingSeparatelyNeverCounts() {
        var members = family
        members[1].eatsSeparately = true
        let settings = DinnerJobSettings(jobs: [.dishes], leftOut: [family[2].id])
        let done = Set(assign(week { _ in everyone }, settings, members: members).values.flatMap { $0 }.map(\.memberID))
        #expect(done == [family[0].id, family[3].id])
    }

    @Test func someoneRemovedIsntInTheRotation() {
        var members = family
        members[3].status = .removed
        #expect(!DinnerJobs.rotation(members: members, settings: both).contains(family[3].id))
    }

    @Test func noJobsOnAwayOrUnplannedNights() {
        var nights = week { _ in everyone }
        nights[1].mealID = nil
        nights[1].quickPick = .eatOut
        nights[2].mealID = nil
        nights[2].quickPick = .fendForYourselves
        nights[3].mealID = nil
        nights[3].mealName = nil
        nights[4].mealID = nil
        nights[4].quickPick = .leftovers
        let away = [AwayDates(from: nights[5].date, to: nights[5].date)]
        nights[5].mealID = nil
        nights[5].mealName = nil
        let assigned = assign(nights, away: away)
        #expect(assigned[nights[1].id] == nil, "eating out")
        #expect(assigned[nights[2].id] == nil, "fending for yourselves")
        #expect(assigned[nights[3].id] == nil, "nothing planned yet")
        #expect(assigned[nights[4].id] != nil, "leftovers still need a table")
        #expect(assigned[nights[5].id] == nil, "away")
    }

    @Test func awayNightsDontUseUpTurns() {
        let plain = week { _ in everyone }
        var withAway = plain
        withAway[1].mealID = nil
        withAway[1].mealName = nil
        let assigned = assign(withAway, oneJob, away: [AwayDates(from: withAway[1].date, to: withAway[1].date)])
        let baseline = assign(plain, oneJob)
        #expect(assigned[withAway[2].id]?.first?.memberID == baseline[plain[1].id]?.first?.memberID,
                "the next night picks up the turn")
    }

    @Test func cardsShowNightsAheadOnly() {
        let nights = week { _ in everyone }
        let assigned = assign(nights, oneJob)
        let past = DinnerJobs.lines(for: nights[0], in: assigned, members: family, today: nights[1].date)
        let tonight = DinnerJobs.lines(for: nights[1], in: assigned, members: family, today: nights[1].date)
        #expect(past.isEmpty)
        #expect(tonight.map(\.title) == [DinnerJob.dishes.title])
    }

    @Test func settingsDecodeLenientlyAndAreNeverSavedWithOtherSettings() throws {
        let json = #"{"dinner_jobs": {"jobs": ["dishes", "walk_the_dog"], "left_out": ["00000000-0000-0000-0000-000000000001", "nope"]}}"#
        let settings = try JSONDecoder().decode(HouseholdSettings.self, from: Data(json.utf8))
        #expect(settings.dinnerJobs.jobs == [.dishes], "a job from a newer app is ignored")
        #expect(settings.dinnerJobs.leftOut.count == 1)

        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(saved?["dinner_jobs"] == nil, "a stale copy saved with other settings can't undo a planner's choice")

        let bad = try JSONDecoder().decode(HouseholdSettings.self, from: Data(#"{"dinner_jobs": 3}"#.utf8))
        #expect(bad.dinnerJobs.jobs.isEmpty, "a bad value costs nothing else")
    }
}

@MainActor
struct DinnerJobsStoreTests {
    @Test func aSettingsSaveKeepsWhatTheServerSaidAboutJobs() async {
        var settings = HouseholdSettings()
        settings.dinnerJobs = DinnerJobSettings(jobs: [.dishes])
        var household = Household.sample
        household.settings = settings
        let store = HouseholdStore.preview(household: household)
        await store.load()
        await store.updateSettings(HouseholdSettings())
        #expect(store.household?.planningSettings.dinnerJobs.jobs == [.dishes])
    }

    @Test func aPlannerRefusedHearsWhy() async {
        var client = HouseholdClient.preview()
        client.setDinnerJob = { _, _, _ in throw PostgrestError(code: "42501", message: "refused") }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        #expect(await store.setDinnerJob(.dishes, isOn: true) == false)
        #expect(store.errorMessage == "Only planners can change dinner jobs.")
    }

    @Test func itShowsWhatTheServerSendsBack() async {
        var client = HouseholdClient.preview()
        client.setDinnerJob = { _, _, _ in DinnerJobSettings(jobs: [.dishes, .setTable]) }
        let store = HouseholdStore(userID: .previewUser, client: client)
        await store.load()
        #expect(await store.setDinnerJob(.dishes, isOn: true))
        #expect(store.household?.planningSettings.dinnerJobs.jobs == [.dishes, .setTable],
                "including what another planner added")
    }
}
