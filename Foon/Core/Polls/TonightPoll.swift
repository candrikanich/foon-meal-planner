import Foundation
import Supabase

/// A vote among who's home tonight (docs/spec.md → Tonight poll). It says what the family would like; a planner makes it dinner.
struct TonightPoll: Identifiable, Equatable, Sendable, Decodable {
    struct Option: Equatable, Sendable, Decodable {
        var quickPick: QuickPick? = nil
        var mealID: UUID? = nil
        var name: String? = nil
        var freezerItemID: UUID? = nil

        private enum CodingKeys: String, CodingKey {
            case quickPick = "quick_pick"
            case mealID = "meal_id"
            case name
            case freezerItemID = "freezer_item_id"
        }

        var title: String {
            if let quickPick { return DayCardText.quickPickLabel(quickPick) }
            return name ?? String(localized: "A dish", comment: "Poll option whose name couldn't be read")
        }
    }

    struct Vote: Equatable, Sendable, Decodable {
        let memberID: UUID
        let choice: Int

        private enum CodingKeys: String, CodingKey {
            case memberID = "member_id"
            case choice
        }
    }

    let id: UUID
    let nightID: UUID
    let startedBy: UUID?
    let options: [Option]
    let closesAt: Date
    var votes: [Vote]

    init(id: UUID = UUID(), nightID: UUID, startedBy: UUID? = nil, options: [Option], closesAt: Date, votes: [Vote] = []) {
        (self.id, self.nightID, self.startedBy, self.options, self.closesAt, self.votes) = (id, nightID, startedBy, options, closesAt, votes)
    }

    private enum CodingKeys: String, CodingKey {
        case id, options
        case nightID = "night_id"
        case startedBy = "started_by"
        case closesAt = "closes_at"
        case votes = "poll_votes"
    }

    func isOpen(at now: Date) -> Bool { closesAt > now }
}

/// One thing someone starting a poll can offer. The server reads each one itself, so a name can't be made up here.
enum PollChoice: Hashable, Sendable, Encodable, Identifiable {
    case quickPick(QuickPick)
    case meal(UUID)
    case freezer(UUID)

    var id: Self { self }

    private enum CodingKeys: String, CodingKey {
        case quickPick = "quick_pick"
        case mealID = "meal_id"
        case freezerItemID = "freezer_item_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quickPick(let pick): try container.encode(pick, forKey: .quickPick)
        case .meal(let id): try container.encode(id, forKey: .mealID)
        case .freezer(let id): try container.encode(id, forKey: .freezerItemID)
        }
    }
}

struct PollClient: Sendable {
    /// The night's latest poll, open or closed.
    var latest: @Sendable (_ nightID: UUID) async throws -> TonightPoll?
    var start: @Sendable (_ nightID: UUID, _ minutes: Int, _ choices: [PollChoice]) async throws -> Void
    var vote: @Sendable (_ pollID: UUID, _ memberID: UUID, _ option: Int) async throws -> Void
    var close: @Sendable (_ pollID: UUID) async throws -> Void
}

extension PollClient {
    private struct StartParams: Encodable {
        let target_night: UUID
        let minutes: Int
        let choices: [PollChoice]
    }

    private struct VoteParams: Encodable {
        let target_poll: UUID
        let target_member: UUID
        let option_index: Int
    }

    static func live(_ client: SupabaseClient) -> PollClient {
        PollClient(
            latest: { nightID in
                let polls: [TonightPoll] = try await client.from("polls")
                    .select("id, night_id, started_by, options, closes_at, poll_votes(member_id, choice)")
                    .eq("night_id", value: nightID)
                    .order("created_at", ascending: false)
                    .limit(1)
                    .execute()
                    .value
                return polls.first
            },
            start: { nightID, minutes, choices in
                try await client.rpc("start_tonight_poll",
                                     params: StartParams(target_night: nightID, minutes: minutes, choices: choices)).execute()
            },
            vote: { pollID, memberID, option in
                try await client.rpc("vote_in_poll",
                                     params: VoteParams(target_poll: pollID, target_member: memberID, option_index: option)).execute()
            },
            close: { pollID in
                try await client.rpc("close_poll", params: ["target_poll": pollID.uuidString]).execute()
            }
        )
    }

    static let preview = PollClient(latest: { _ in nil }, start: { _, _, _ in }, vote: { _, _, _ in }, close: { _ in })
}

/// Who votes, how it came out, and what's offered, kept pure.
enum PollRules {
    static let durations = [15, 30, 60]
    static let defaultDuration = 30
    static let optionLimit = 6

    /// Whoever's home, leaving out anyone who eats separately. No row means nobody's said they're out, as with allergy flags.
    static func voters(on night: WeekNight, members: [Member]) -> [Member] {
        members.filter { $0.status != .removed && !$0.eatsSeparately && night.attendance[$0.id] != false }
    }

    /// Who this phone can vote as: its own person, then anyone home that nobody has claimed, since the little ones have no phones.
    static func votesAs(voters: [Member], me: Member?) -> [Member] {
        let own = voters.filter { $0.id == me?.id }
        return own + voters.filter { $0.id != me?.id && $0.userID == nil }
    }

    /// Votes per option. Only voters count: someone who has since said they won't be home is out of this dinner.
    static func counts(_ poll: TonightPoll, voters: [Member]) -> [Int] {
        let counted = Set(voters.map(\.id))
        var counts = Array(repeating: 0, count: poll.options.count)
        for vote in poll.votes where counted.contains(vote.memberID) && counts.indices.contains(vote.choice) {
            counts[vote.choice] += 1
        }
        return counts
    }

    static func votedCount(_ poll: TonightPoll, voters: [Member]) -> Int {
        counts(poll, voters: voters).reduce(0, +)
    }

    /// The options with the most votes: one, or several on a tie. None when nobody voted.
    static func winners(_ poll: TonightPoll, voters: [Member]) -> [Int] {
        let counts = counts(poll, voters: voters)
        guard let top = counts.max(), top > 0 else { return [] }
        return counts.indices.filter { counts[$0] == top }
    }

    static func canClose(_ poll: TonightPoll, me: Member?, canPlan: Bool) -> Bool {
        canPlan || (me != nil && poll.startedBy == me?.id)
    }

    /// Whether the night already holds this option, so a planner isn't asked to do it twice.
    static func holds(_ night: WeekNight, _ option: TonightPoll.Option) -> Bool {
        if let pick = option.quickPick { return night.quickPick == pick }
        return option.mealID != nil && night.mealID == option.mealID
    }

    /// The Swap a winning option becomes. Nil when it can't be planned any more: the dish has left rotation or the freezer item's
    /// been used since the poll started.
    static func swapChoice(for option: TonightPoll.Option, library: [LibraryMeal], freezer: [FreezerItem],
                           today: CalendarDay) -> WeekStore.SwapChoice? {
        if let pick = option.quickPick { return .quickPick(pick) }
        if let itemID = option.freezerItemID {
            guard let item = freezer.first(where: { $0.id == itemID }), item.state == .in else { return nil }
            return .freezer(item, reason: FreezerStash.reason(madeOn: item.madeOn, today: today))
        }
        guard let id = option.mealID, let meal = library.first(where: { $0.id == id }), meal.status.isInRotation else { return nil }
        return .meal(id: id, name: meal.name)
    }

    /// Dishes tagged as backup dinners, unless something in them is marked out. An item nobody tracks counts as there: only keep-on-
    /// hand items have a stock state, and "out" is the only thing that rules out dinner, since low still makes one. The same
    /// skips as the freezer's offers: a dish already this week, a no from someone home, a snooze, or a food rule.
    static func backupDinners(library: [LibraryMeal], night: WeekNight, week: [WeekNight], stock: [UUID: StockState],
                              notForMe: [UUID: [UUID: Int]], snoozed: Set<UUID>, foodRules: [FoodRule]) -> [LibraryMeal] {
        let planned = Set(week.compactMap(\.mealID))
        let home = night.home
        return library
            .filter { meal in
                guard meal.tags.contains(.backup), meal.status.isInRotation, !planned.contains(meal.id), !snoozed.contains(meal.id) else {
                    return false
                }
                let dislikes = notForMe[meal.id] ?? [:]
                return !home.contains { (dislikes[$0] ?? 0) >= 1 }
                    && !meal.ingredients.contains { stock[$0.itemID] == .out }
                    && FoodRuleMatcher.broken(by: meal, on: night.date, rules: foodRules, library: library).isEmpty
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Two batches of chili are one choice on a vote, and the server takes a dish once. The oldest stays: offers come oldest first.
    static func oneOfEachDish(_ offers: [FreezerStash.Offer]) -> [FreezerStash.Offer] {
        var seen = Set<UUID>()
        return offers.filter { seen.insert($0.meal.id).inserted }
    }

    /// Whether the poll offers a dish this phone's library hasn't heard of: someone added it since the library loaded.
    static func hasUnknownDish(_ poll: TonightPoll, library: [LibraryMeal]) -> Bool {
        let known = Set(library.map(\.id))
        return poll.options.contains { option in option.mealID.map { !known.contains($0) } ?? false }
    }

    /// What's ticked to begin with: what's already in the house, then the two quick picks that need nothing, so it can start with one tap.
    static func startingChoices(freezer: [FreezerStash.Offer], backups: [LibraryMeal]) -> Set<PollChoice> {
        let inTheHouse: PollChoice? = freezer.first.map { .freezer($0.item.id) } ?? backups.first.map { .meal($0.id) }
        return Set([inTheHouse, .quickPick(.leftovers), .quickPick(.takeout)].compactMap { $0 })
    }
}
