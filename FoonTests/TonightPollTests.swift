import Foundation
import Testing
@testable import Foon

@MainActor
struct TonightPollTests {
    private let household = UUID()
    private let today = CalendarDay(year: 2026, month: 11, day: 2)

    private func member(_ name: String, claimed: Bool = true, separately: Bool = false, status: MemberStatus = .active) -> Member {
        Member(id: UUID(), householdID: household, firstName: name, avatar: nil, ageGroup: .adult, guardian: false, role: .member,
               status: status, awayUntil: nil, userID: claimed ? UUID() : nil, attendanceDefaults: nil, separately: separately)
    }

    private func night(id: UUID = UUID(), attendance: [UUID: Bool] = [:], mealID: UUID? = nil, quickPick: QuickPick? = nil) -> WeekNight {
        WeekNight(id: id, date: today, effort: .normal, dinnerTime: nil, mealID: mealID, mealName: nil, quickPick: quickPick,
                  locked: false, attendance: attendance)
    }

    private func poll(votes: [TonightPoll.Vote] = [], startedBy: UUID? = nil) -> TonightPoll {
        TonightPoll(nightID: UUID(), startedBy: startedBy,
                    options: [.init(quickPick: .takeout), .init(quickPick: .leftovers), .init(mealID: UUID(), name: "Pizza")],
                    closesAt: Date(timeIntervalSince1970: 1000), votes: votes)
    }

    // MARK: - Who votes

    @Test func whoeverIsHomeVotes() {
        let (home, out, noRow, baby, gone) = (member("Ana"), member("Ben"), member("Cy"), member("Baby", separately: true),
                                              member("Dee", status: .removed))
        let night = night(attendance: [home.id: true, out.id: false, baby.id: true, gone.id: true])
        #expect(PollRules.voters(on: night, members: [home, out, noRow, baby, gone]).map(\.firstName) == ["Ana", "Cy"])
    }

    @Test func aPhoneVotesForItsOwnerAndAnyoneUnclaimed() {
        let (me, other, kid) = (member("Ana"), member("Ben"), member("Nora", claimed: false))
        #expect(PollRules.votesAs(voters: [other, kid, me], me: me).map(\.firstName) == ["Ana", "Nora"])
        // Out tonight themselves, they can still pass the phone to a kid who's home.
        #expect(PollRules.votesAs(voters: [other, kid], me: me).map(\.firstName) == ["Nora"])
        #expect(PollRules.votesAs(voters: [other], me: me).isEmpty)
    }

    // MARK: - How it came out

    @Test func theMostVotesWin() {
        let (a, b, c) = (member("A"), member("B"), member("C"))
        let poll = poll(votes: [.init(memberID: a.id, choice: 1), .init(memberID: b.id, choice: 1), .init(memberID: c.id, choice: 0)])
        #expect(PollRules.counts(poll, voters: [a, b, c]) == [1, 2, 0])
        #expect(PollRules.winners(poll, voters: [a, b, c]) == [1])
        #expect(PollRules.votedCount(poll, voters: [a, b, c]) == 3)
    }

    @Test func aTieNamesEveryWinner() {
        let (a, b) = (member("A"), member("B"))
        let poll = poll(votes: [.init(memberID: a.id, choice: 0), .init(memberID: b.id, choice: 2)])
        #expect(PollRules.winners(poll, voters: [a, b]) == [0, 2])
    }

    @Test func noVotesIsNoWinner() {
        #expect(PollRules.winners(poll(), voters: [member("A")]).isEmpty)
    }

    @Test func someoneWhoLeftNoLongerCounts() {
        let (a, b, gone) = (member("A"), member("B"), member("Gone"))
        let poll = poll(votes: [.init(memberID: a.id, choice: 0), .init(memberID: gone.id, choice: 1), .init(memberID: b.id, choice: 1)])
        #expect(PollRules.counts(poll, voters: [a]) == [1, 0, 0])
        #expect(PollRules.winners(poll, voters: [a]) == [0])
    }

    @Test func aChoiceOutOfRangeIsIgnored() {
        let a = member("A")
        #expect(PollRules.counts(poll(votes: [.init(memberID: a.id, choice: 9)]), voters: [a]) == [0, 0, 0])
    }

    @Test func openUntilItCloses() {
        let poll = poll()
        #expect(poll.isOpen(at: Date(timeIntervalSince1970: 999)))
        #expect(!poll.isOpen(at: Date(timeIntervalSince1970: 1000)))
    }

    @Test func whoCanEndIt() {
        let (me, other) = (member("Ana"), member("Ben"))
        #expect(PollRules.canClose(poll(startedBy: me.id), me: me, canPlan: false))
        #expect(!PollRules.canClose(poll(startedBy: other.id), me: me, canPlan: false))
        #expect(PollRules.canClose(poll(startedBy: other.id), me: me, canPlan: true))
        #expect(!PollRules.canClose(poll(startedBy: nil), me: nil, canPlan: false))
    }

    // MARK: - Making it dinner

    @Test func aWinnerBecomesASwap() {
        let meal = LibraryMeal.fixture(name: "Pizza")
        #expect(PollRules.swapChoice(for: .init(quickPick: .takeout), library: [], freezer: [], today: today) == .quickPick(.takeout))
        #expect(PollRules.swapChoice(for: .init(mealID: meal.id, name: "Old name"), library: [meal], freezer: [], today: today)
            == .meal(id: meal.id, name: "Pizza"))
    }

    @Test func aWinnerThatsGoneIsNotPlanned() {
        let retired = LibraryMeal.fixture(name: "Liver", status: .retired)
        #expect(PollRules.swapChoice(for: .init(mealID: retired.id), library: [retired], freezer: [], today: today) == nil)
        #expect(PollRules.swapChoice(for: .init(mealID: UUID()), library: [], freezer: [], today: today) == nil)
        let used = FreezerItem(id: UUID(), mealID: UUID(), mealName: "Chili", madeOn: today, state: .used)
        #expect(PollRules.swapChoice(for: .init(mealID: used.mealID, freezerItemID: used.id), library: [], freezer: [used], today: today) == nil)
    }

    @Test func aFreezerWinnerStaysTheFreezerItem() throws {
        let item = FreezerItem(id: UUID(), mealID: UUID(), mealName: "Chili", madeOn: today, state: .in)
        let choice = try #require(PollRules.swapChoice(for: .init(mealID: item.mealID, freezerItemID: item.id), library: [],
                                                       freezer: [item], today: today))
        guard case .freezer(let chosen, _) = choice else {
            Issue.record("expected the freezer item, not the dish")
            return
        }
        #expect(chosen == item)
    }

    @Test func aNightKnowsWhenItHoldsTheWinner() {
        let id = UUID()
        #expect(PollRules.holds(night(mealID: id), .init(mealID: id)))
        #expect(PollRules.holds(night(quickPick: .takeout), .init(quickPick: .takeout)))
        #expect(!PollRules.holds(night(quickPick: .takeout), .init(quickPick: .leftovers)))
        #expect(!PollRules.holds(night(), .init(mealID: nil)))
    }

    // MARK: - What's offered

    private func backups(_ library: [LibraryMeal], night: WeekNight? = nil, week: [WeekNight] = [], stock: [UUID: StockState] = [:],
                         notForMe: [UUID: [UUID: Int]] = [:], snoozed: Set<UUID> = []) -> [String] {
        PollRules.backupDinners(library: library, night: night ?? self.night(), week: week, stock: stock, notForMe: notForMe,
                                snoozed: snoozed, foodRules: []).map(\.name)
    }

    @Test func onlyBackupDinnersInRotation() {
        let library: [LibraryMeal] = [.fixture(name: "Pizza", tags: [.backup]), .fixture(name: "Tacos"),
                                      .fixture(name: "Mac", tags: [.backup], status: .archived),
                                      .fixture(name: "Nuggets", tags: [.backup], status: .retired)]
        #expect(backups(library) == ["Pizza"])
    }

    @Test func aBackupDinnerMarkedOutIsntOffered() {
        let pizza = LibraryMeal.fixture(name: "Pizza", tags: [.backup], ingredients: ["frozen pizza"])
        let item = pizza.ingredients[0].itemID
        #expect(backups([pizza], stock: [item: .out]).isEmpty)
        #expect(backups([pizza], stock: [item: .low]) == ["Pizza"], "low still makes dinner")
        #expect(backups([pizza], stock: [item: .in]) == ["Pizza"])
        #expect(backups([pizza]) == ["Pizza"], "an item nobody tracks counts as there")
    }

    @Test func backupDinnersSkipWhatTheFreezerSkips() {
        let pizza = LibraryMeal.fixture(name: "Pizza", tags: [.backup])
        let someone = UUID()
        #expect(backups([pizza], night: night(attendance: [someone: true]), notForMe: [pizza.id: [someone: 1]]).isEmpty)
        #expect(backups([pizza], night: night(attendance: [someone: false]), notForMe: [pizza.id: [someone: 1]]) == ["Pizza"])
        #expect(backups([pizza], snoozed: [pizza.id]).isEmpty)
        #expect(backups([pizza], week: [night(mealID: pizza.id)]).isEmpty)
    }

    @Test func startingChoicesCanStartRightAway() {
        let empty = PollRules.startingChoices(freezer: [], backups: [])
        #expect(empty == [.quickPick(.leftovers), .quickPick(.takeout)])
        let pizza = LibraryMeal.fixture(name: "Pizza", tags: [.backup])
        #expect(PollRules.startingChoices(freezer: [], backups: [pizza]).contains(.meal(pizza.id)))
        let item = FreezerItem(id: UUID(), mealID: pizza.id, mealName: "Pizza", madeOn: today, state: .in)
        let offer = FreezerStash.Offer(item: item, meal: pizza, flags: [])
        #expect(PollRules.startingChoices(freezer: [offer], backups: [pizza]).contains(.freezer(item.id)))
        #expect(!PollRules.startingChoices(freezer: [offer], backups: [pizza]).contains(.meal(pizza.id)))
    }

    @Test func twoBatchesOfOneDishAreOneChoice() {
        let chili = LibraryMeal.fixture(name: "Chili"), soup = LibraryMeal.fixture(name: "Soup")
        let offer = { (meal: LibraryMeal) in
            FreezerStash.Offer(item: FreezerItem(id: UUID(), mealID: meal.id, mealName: meal.name, madeOn: today, state: .in), meal: meal, flags: [])
        }
        let oldest = offer(chili)
        let kept = PollRules.oneOfEachDish([oldest, offer(soup), offer(chili)])
        #expect(kept.map(\.meal.name) == ["Chili", "Soup"])
        #expect(kept.first?.item.id == oldest.item.id)
    }

    @Test func aDishTheLibraryHasntHeardOfIsNoticed() {
        let pizza = LibraryMeal.fixture(name: "Pizza")
        let poll = { (options: [TonightPoll.Option]) in TonightPoll(nightID: UUID(), options: options, closesAt: .now) }
        #expect(PollRules.hasUnknownDish(poll([.init(mealID: UUID(), name: "New")]), library: [pizza]))
        #expect(!PollRules.hasUnknownDish(poll([.init(mealID: pizza.id, name: "Pizza"), .init(quickPick: .takeout)]), library: [pizza]))
    }

    // MARK: - Reading and writing

    @Test func decodesWhatTheServerSends() throws {
        let night = UUID(), voter = UUID(), meal = UUID(), item = UUID()
        let json = """
        {"id":"\(UUID())","night_id":"\(night)","started_by":null,"closes_at":"2026-11-02T22:00:00Z",
         "options":[{"quick_pick":"eat_out"},{"meal_id":"\(meal)","name":"Pizza"},{"meal_id":"\(meal)","name":"Chili","freezer_item_id":"\(item)"}],
         "poll_votes":[{"member_id":"\(voter)","choice":1}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let poll = try decoder.decode(TonightPoll.self, from: Data(json.utf8))
        #expect(poll.nightID == night)
        #expect(poll.options[0].quickPick == .eatOut)
        #expect(poll.options[1].title == "Pizza")
        #expect(poll.options[2].freezerItemID == item)
        #expect(poll.votes == [.init(memberID: voter, choice: 1)])
    }

    @Test func choicesEncodeAsTheServerReadsThem() throws {
        let id = UUID()
        func json(_ choice: PollChoice) throws -> String {
            String(decoding: try JSONEncoder().encode(choice), as: UTF8.self)
        }
        #expect(try json(.quickPick(.eatOut)) == #"{"quick_pick":"eat_out"}"#)
        #expect(try json(.meal(id)) == #"{"meal_id":"\#(id)"}"#)
        #expect(try json(.freezer(id)) == #"{"freezer_item_id":"\#(id)"}"#)
    }

    @Test func aRefusalSaysWhy() {
        #expect(PollStore.message(for: "FD020") != PollStore.message(for: nil))
        #expect(PollStore.message(for: "FD018") != PollStore.message(for: "FD019"))
    }

    @Test func aRefreshThatFailsKeepsThePoll() async {
        let night = UUID()
        let shown = TonightPoll(nightID: night, options: [.init(quickPick: .takeout)], closesAt: .distantFuture)
        let box = FailingBox()
        await box.set(.success(shown))
        let client = PollClient(latest: { _ in try await box.next() }, start: { _, _, _ in }, vote: { _, _, _ in }, close: { _ in })
        let store = PollStore(client: client)
        await store.load(nightID: night)
        #expect(store.poll(for: night) == shown)
        await box.set(.failure(URLError(.notConnectedToInternet)))
        await store.load(nightID: night)
        #expect(store.poll(for: night) == shown)
        #expect(store.poll(for: UUID()) == nil, "only for the night asked about")
    }

    @Test func aRefusedVoteSaysSoAndReloads() async {
        let night = UUID()
        let shown = TonightPoll(nightID: night, options: [.init(quickPick: .takeout)], closesAt: .distantFuture)
        let client = PollClient(latest: { _ in shown }, start: { _, _, _ in }, vote: { _, _, _ in throw URLError(.notConnectedToInternet) },
                                close: { _ in })
        let store = PollStore(client: client)
        await store.vote(shown, memberID: UUID(), option: 0)
        #expect(store.errorMessage == PollStore.message(for: nil))
        #expect(store.poll(for: night) == shown)
    }

    private actor FailingBox {
        private var result: Result<TonightPoll?, Error> = .success(nil)
        func set(_ result: Result<TonightPoll?, Error>) { self.result = result }
        func next() throws -> TonightPoll? { try result.get() }
    }
}
