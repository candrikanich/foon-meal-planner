import Foundation
import Observation

/// This week (or next) for the planner: start it, toggle who's home, and cycle each night's effort.
/// Changes show at once. Writes to one night go out in order; if one fails, the week reloads from the server.
@Observable @MainActor
final class WeekStore {
    private(set) var week: Week?
    private(set) var start: CalendarDay?
    private(set) var isLoading = false
    private(set) var isStarting = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var showingNextWeek = false

    let householdID: UUID
    private let client: WeekClient
    private let today: () -> CalendarDay
    /// A fresh seed per build or shuffle; tests pin it so drafts are predictable.
    private let seed: () -> UInt64
    /// The last write queued per night, so the next one waits for it.
    private var lastWrite: [UUID: Task<Void, Never>] = [:]
    private(set) var isBuilding = false

    init(householdID: UUID, client: WeekClient, today: @escaping () -> CalendarDay = { CalendarDay(Date()) },
         seed: @escaping () -> UInt64 = { UInt64.random(in: .min ... .max) }) {
        self.householdID = householdID
        self.client = client
        self.today = today
        self.seed = seed
    }

    var todayDay: CalendarDay { today() }

    func load(settings: HouseholdSettings) async {
        let thisWeek = WeekMath.start(of: today(), weekStart: settings.weekStart)
        let start = showingNextWeek ? thisWeek.adding(days: 7) : thisWeek
        if start != self.start { week = nil }
        self.start = start
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await client.week(householdID, start)
            guard start == self.start else { return }
            week = loaded
            hasLoaded = true
            errorMessage = nil
        } catch {
            // A load cancelled by a newer one (the week switched, the view went away) isn't a failure.
            guard start == self.start, !Self.isCancellation(error) else { return }
            errorMessage = String(localized: "Couldn't load the week. Check your connection and try again.")
        }
    }

    func startWeek() async {
        guard let start, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let created = try await client.create(householdID, start)
            guard start == self.start else { return }
            week = created
            errorMessage = nil
        } catch {
            guard start == self.start else { return }
            errorMessage = String(localized: "Couldn't start the week. Check your connection and try again.")
        }
    }

    /// Someone added to the family after the week was made has no nights yet; reopening the week
    /// (`create_week`) fills them in from their usual schedule. Planners only.
    func fillInMissing(members: [Member]) async {
        guard let week, !isStarting else { return }
        let everyone = members.filter { $0.status != .removed }.map(\.id)
        let missing = week.nights.contains { night in everyone.contains { night.attendance[$0] == nil } }
        guard missing else { return }
        let start = week.start
        do {
            let filled = try await client.create(householdID, start)
            guard start == self.start else { return }
            self.week = filled
        } catch {
            // Not urgent: they'll be filled in next time the week opens.
        }
    }

    func toggleAttendance(nightID: UUID, memberID: UUID) async {
        guard let index = nightIndex(nightID), let current = week?.nights[index].attendance[memberID] else { return }
        week?.nights[index].attendance[memberID] = !current
        await send(nightID: nightID, failure: String(localized: "Couldn't change who's home. Check your connection and try again.")) {
            [client] in try await client.setExpected(nightID, memberID, !current)
        }
    }

    func cycleEffort(nightID: UUID) async {
        guard let index = nightIndex(nightID), let current = week?.nights[index].effort else { return }
        await setEffort(current.next, nightID: nightID)
    }

    func setEffort(_ effort: NightEffort, nightID: UUID) async {
        guard let index = nightIndex(nightID), week?.nights[index].effort != effort else { return }
        week?.nights[index].effort = effort
        await send(nightID: nightID, failure: String(localized: "Couldn't change the night. Check your connection and try again.")) {
            [client] in try await client.setEffort(nightID, effort)
        }
    }

    func toggleLock(nightID: UUID) async {
        guard let index = nightIndex(nightID), let current = week?.nights[index].locked else { return }
        week?.nights[index].locked = !current
        await send(nightID: nightID, failure: String(localized: "Couldn't change the night. Check your connection and try again.")) {
            [client] in try await client.setLocked(nightID, !current)
        }
    }

    var layout: WeekLayout? {
        week.map { WeekLayout(nights: $0.nights, today: today()) }
    }

    // MARK: - Build my week

    /// Starts the week if needed, then drafts every night that isn't kept (locked, event, or past).
    /// The context is fetched inside, after the building flag is up, so taps during the library load are ignored.
    func buildWeek(_ context: () async -> PlanningContext?) async {
        await planning(context) { context in
            if week == nil { await startWeek() }
            guard let week else { return }
            let inputs = context.inputs(for: week, today: today())
            await apply(BuildMyWeek.draft(inputs, seed: seed()), inputs: inputs)
        }
    }

    /// Drafts only the empty nights: what the planner already chose stays.
    func fillRemaining(_ context: () async -> PlanningContext?) async {
        await planning(context) { context in
            guard let week else { return }
            var inputs = context.inputs(for: week, today: today())
            for index in inputs.nights.indices
            where inputs.nights[index].mealID != nil || inputs.nights[index].quickPick != nil {
                inputs.nights[index].locked = true
            }
            await apply(BuildMyWeek.draft(inputs, seed: seed()), inputs: inputs)
        }
    }

    /// Re-rolls one night, or picks for an empty one. Locked, event, past, and quick-pick nights stay as they are.
    func shuffle(nightID: UUID, _ context: () async -> PlanningContext?) async {
        await planning(context) { context in
            guard let week else { return }
            let inputs = context.inputs(for: week, today: today())
            guard let plan = BuildMyWeek.shuffle(night: nightID, inputs: inputs, seed: seed()) else { return }
            await apply([plan], inputs: inputs)
        }
    }

    /// One build at a time, and only from a library that loaded with meals in it: drafting from nothing would
    /// find nothing for every night.
    private func planning(_ context: () async -> PlanningContext?,
                          _ work: (PlanningContext) async -> Void) async {
        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }
        guard let context = await context() else {
            errorMessage = String(localized: "Couldn't load your library. Check your connection and try again.")
            return
        }
        guard context.meals.contains(where: \.status.isInRotation) else {
            errorMessage = String(localized: "Add some meals to your library first, then Foon can plan the week.")
            return
        }
        await work(context)
    }

    /// Shows the picks at once and saves them together; if the save fails, shows what the server has.
    /// Writes only nights that were open going in (not locked, event, or past) and that got a pick: a draft
    /// that finds nothing never clears a night that already has dinner.
    private func apply(_ plans: [NightPlan], inputs: PlanningInputs) async {
        guard let planID = week?.planID else { return }
        let kept = Set(inputs.nights.filter { $0.locked || $0.effort == .event || $0.date < inputs.today }.map(\.id))
        let updates = plans.filter { !kept.contains($0.nightID) && $0.pick != nil }.map { plan in
            NightUpdate(nightID: plan.nightID, mealID: plan.pick?.mealID, quickPick: plan.pick?.quickPick,
                        reason: plan.reason?.text)
        }
        guard !updates.isEmpty else { return }
        let names = Dictionary(inputs.meals.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for update in updates {
            guard let index = nightIndex(update.nightID) else { continue }
            week?.nights[index].mealID = update.mealID
            week?.nights[index].mealName = update.mealID.flatMap { names[$0] }
            week?.nights[index].quickPick = update.quickPick
            week?.nights[index].reason = update.reason
        }
        do {
            try await client.setNights(planID, updates)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Couldn't save the plan. Check your connection and try again.")
            await reload()
        }
    }

    /// One DayCard per night, with attendance in the family's order.
    func cards(members: [Member], sides: (UUID) -> [String] = { _ in [] }) -> [DayCardModel] {
        (week?.nights ?? []).map { Self.card(for: $0, members: members, sides: sides) }
    }

    /// A night's card. Badges are worked out by the caller, who knows the meal and the family's allergies.
    static func card(for night: WeekNight, members: [Member], sides: (UUID) -> [String] = { _ in [] },
                     badges: (UUID, Set<UUID>) -> [DayCardModel.Badge] = { _, _ in [] }) -> DayCardModel {
        let home = Set(night.attendance.filter(\.value).keys)
        return DayCardModel(
            date: night.date,
            effort: night.effort,
            slot: slot(for: night, sides: night.mealID.map(sides) ?? []),
            attendance: members.compactMap { member in
                night.attendance[member.id].map {
                    DayCardModel.Attendee(memberID: member.id, firstName: member.firstName, avatar: member.avatar,
                                          isHome: $0)
                }
            },
            badges: night.mealID.map { badges($0, home) } ?? [],
            isLocked: night.locked
        )
    }

    static func slot(for night: WeekNight, sides: [String]) -> DayCardModel.Slot {
        if let mealName = night.mealName {
            return .meal(name: mealName, photoURL: nil, reason: night.reason, sides: sides)
        }
        if let quickPick = night.quickPick { return .quickPick(quickPick) }
        return .empty
    }

    func night(_ date: CalendarDay) -> WeekNight? {
        week?.nights.first { $0.date == date }
    }

    // MARK: - Private

    /// Queues a write behind the night's previous one, so rapid taps reach the server in the order made.
    private func send(nightID: UUID, failure: String, _ write: @escaping @Sendable () async throws -> Void) async {
        let previous = lastWrite[nightID]
        let task = Task {
            await previous?.value
            do {
                try await write()
            } catch {
                errorMessage = failure
                await reload()
            }
        }
        lastWrite[nightID] = task
        await task.value
    }

    /// After a refused write, show what the server has rather than guessing which tap to undo.
    private func reload() async {
        guard let start else { return }
        if let loaded = try? await client.week(householdID, start), start == self.start { week = loaded }
    }

    private func nightIndex(_ id: UUID) -> Int? {
        week?.nights.firstIndex { $0.id == id }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// What Build my week needs from the rest of the app: the library, its history, settings, and the family.
struct PlanningContext {
    let meals: [LibraryMeal]
    let history: [MealHistory]
    let settings: HouseholdSettings
    let members: [Member]
    /// Dated requests (M2); empty until requests exist.
    var requests: [DatedRequest] = []

    func inputs(for week: Week, today: CalendarDay) -> PlanningInputs {
        PlanningInputs(
            nights: week.nights.map(PlanningNight.init),
            meals: meals,
            history: history,
            settings: settings,
            memberNames: Dictionary(members.map { ($0.id, $0.firstName) }, uniquingKeysWith: { first, _ in first }),
            requests: requests,
            today: max(today, week.start)
        )
    }
}
