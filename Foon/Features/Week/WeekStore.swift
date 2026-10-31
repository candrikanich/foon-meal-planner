import Foundation
import Observation
import Supabase

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
    /// Injected in tests; otherwise today is worked out from `now` in the household's time zone.
    private let fixedToday: (() -> CalendarDay)?
    private let now: () -> Date
    /// The household's calendar, from the last load's settings: the server clears away nights by the same day.
    private var calendar = Calendar.current
    /// Bumped when the server refuses a dinner because the family is away: this device hasn't heard about the dates, so
    /// This Week reloads the household.
    private(set) var awayRefusals = 0
    /// A fresh seed per build or shuffle; tests pin it so drafts are predictable.
    private let seed: () -> UInt64
    /// The last write queued per night, so the next one waits for it.
    private var lastWrite: [UUID: Task<Void, Never>] = [:]
    /// Counts writes started, so a read begun before a tap isn't shown over it.
    private var writesStarted = 0
    private(set) var isBuilding = false
    /// Nights the last build couldn't fill (nothing passed the filters): This Week offers starter dishes for them.
    private(set) var unfillableNights: Set<UUID> = []
    /// The household's standing traditions, at most one per weekday.
    private(set) var traditions: [Tradition] = []
    /// False until traditions load: Build won't run without them, or it would quietly skip Taco Tuesday.
    private(set) var traditionsLoaded = false
    /// Request → night for each idea the last build placed, so only those nights mark an idea planned (not a tradition,
    /// a pick that happens to be the same dish, or another idea for it). A swap on the night drops it.
    private(set) var requestNights: [UUID: UUID] = [:]
    /// The household's away dates, as of the last load: those nights show as away and aren't planned.
    private(set) var awayDates: [AwayDates] = []

    init(householdID: UUID, client: WeekClient, today: (() -> CalendarDay)? = nil,
         seed: @escaping () -> UInt64 = { UInt64.random(in: .min ... .max) }, now: @escaping () -> Date = { .now }) {
        self.householdID = householdID
        self.client = client
        self.fixedToday = today
        self.now = now
        self.seed = seed
    }

    var todayDay: CalendarDay { today() }

    private func today() -> CalendarDay {
        fixedToday?() ?? CalendarDay(now(), calendar: calendar)
    }

    /// Every night left in the week showing is inside the away dates, so there's nothing to start or build.
    var isAwayForTheRestOfTheWeek: Bool {
        guard let start else { return false }
        let today = today()
        let left = (0..<7).map { start.adding(days: $0) }.filter { $0 >= today }
        return !left.isEmpty && left.allSatisfy { day in awayDates.contains { $0.contains(day) } }
    }

    func load(settings: HouseholdSettings) async {
        calendar = settings.dayCalendar
        let thisWeek = WeekMath.start(of: today(), weekStart: settings.weekStart)
        let start = showingNextWeek ? thisWeek.adding(days: 7) : thisWeek
        if start != self.start { week = nil }
        awayDates = settings.awayDates
        self.start = start
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedTraditions = client.traditions(householdID)
            async let loadedWeek = client.week(householdID, start)
            let (traditions, loaded) = try await (loadedTraditions, loadedWeek)
            guard start == self.start else { return }
            self.traditions = traditions
            traditionsLoaded = true
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
        week.map { WeekLayout(nights: $0.nights, today: today(), away: awayDates) }
    }

    /// Today as the store sees it (injected in tests), for labels that must agree with `layout`.
    var currentDay: CalendarDay { today() }

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
        guard traditionsLoaded else {
            errorMessage = String(localized: "Couldn't load your traditions. Pull to refresh, then try again.")
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
        defer {
            requestNights = Dictionary(plans.compactMap { plan -> (UUID, UUID)? in
                guard case .request = plan.reason, let mealID = plan.pick?.mealID,
                      let night = week?.nights.first(where: { $0.id == plan.nightID }), night.mealID == mealID,
                      let requestID = inputs.requests.first(where: { $0.mealID == mealID && $0.date == night.date })?
                          .requestID ?? inputs.wanted.first(where: { $0.mealID == mealID })?.requestID
                else { return nil }
                return (requestID, plan.nightID)
            }, uniquingKeysWith: { first, _ in first })
        }
        let kept = Set(inputs.nights.filter { $0.locked || $0.effort == .event || $0.date < inputs.today }.map(\.id))
        let drafted = Set(plans.map(\.nightID))
        unfillableNights = unfillableNights.subtracting(drafted)
            .union(plans.filter { $0.reason == .nothingFits }.map(\.nightID))
        let updates = plans.filter { !kept.contains($0.nightID) && $0.pick != nil }.map { plan in
            NightUpdate(nightID: plan.nightID, mealID: plan.pick?.mealID, quickPick: plan.pick?.quickPick,
                        reason: plan.reason?.text, locked: plan.locks ? true : nil)
        }
        guard !updates.isEmpty else { return }
        let names = Dictionary(inputs.meals.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let touchesLink = updates.contains { isLinked($0.nightID) }
        for update in updates {
            guard let index = nightIndex(update.nightID) else { continue }
            week?.nights[index].mealID = update.mealID
            week?.nights[index].mealName = update.mealID.flatMap { names[$0] }
            week?.nights[index].quickPick = update.quickPick
            week?.nights[index].reason = update.reason
            week?.nights[index].locked = update.locked == true
        }
        writesStarted += 1
        defer { writesStarted += 1 }
        do {
            try await client.setNights(planID, updates)
            errorMessage = nil
            // An unlocked half of a doubled pair or a freezer night: the server moved the other end.
            if touchesLink {
                noteListChanged()
                await settleThenReload()
            }
        } catch {
            errorMessage = message(for: error, otherwise: String(localized: "Couldn't save the plan. Check your connection and try again."))
            await reload()
        }
    }

    // MARK: - Swap

    /// What the swap sheet can put on a night.
    enum SwapChoice: Equatable, Sendable {
        case meal(id: UUID, name: String)
        case quickPick(QuickPick)
        /// Back to an empty night, open for Fill again.
        case empty
        /// A stash item, with the chip saying where it came from.
        case freezer(FreezerItem, reason: String)
    }

    /// The planner's own pick replaces the night and locks it, so a later Rebuild keeps it. Clearing unlocks.
    /// Returns whether it saved. Not while a build is saving: the two writes would race.
    @discardableResult
    func swap(nightID: UUID, to choice: SwapChoice) async -> Bool {
        guard !isBuilding, let index = nightIndex(nightID) else { return false }
        var update = NightUpdate(nightID: nightID)
        var mealName: String?
        var stashItem: UUID?
        var freezerWrite: (itemID: UUID, reason: String)?
        switch choice {
        case .meal(let id, let name):
            update.mealID = id
            mealName = name
        case .quickPick(let pick):
            update.quickPick = pick
        case .empty:
            break
        case .freezer(let item, let reason):
            update.mealID = item.mealID
            update.reason = reason
            mealName = item.mealName
            stashItem = item.id
            freezerWrite = (item.id, reason)
        }
        let lock = choice != .empty
        let saved = update
        let write = freezerWrite
        let linked = isLinked(nightID)
        let date = week?.nights[index].date ?? today()
        if lock { unfillableNights.remove(nightID) }
        week?.nights[index].mealID = update.mealID
        week?.nights[index].mealName = mealName
        week?.nights[index].quickPick = update.quickPick
        week?.nights[index].reason = update.reason
        week?.nights[index].locked = lock
        week?.nights[index].stashItemID = stashItem
        week?.nights[index].leftoversFrom = nil
        requestNights = requestNights.filter { $0.value != nightID }
        let succeeded = await send(nightID: nightID, failure: String(localized: "Couldn't swap the night. Check your connection and try again.")) {
            [client] in
            if let write {
                try await client.useFreezerItem(nightID, write.itemID, write.reason)
            } else {
                try await client.setNight(saved, lock)
            }
        }
        if succeeded, linked || (write != nil && date >= today()) { noteListChanged() }
        // The server just moved the night at the other end of a link; show what it did.
        if succeeded, linked { await settleThenReload() }
        return succeeded
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Double it

    /// Cooks twice as much on one night and plans the leftovers on a later one, locked as any planner's pick is. Sends what
    /// this device saw on both, so a stale phone is refused rather than overwriting someone's change.
    @discardableResult
    func doubleIt(nightID: UUID, leftoversNightID: UUID) async -> Bool {
        guard !isBuilding, let index = nightIndex(nightID), let laterIndex = nightIndex(leftoversNightID),
              let night = week?.nights[index], let later = week?.nights[laterIndex] else { return false }
        let request = DoubleItRequest(nightID: nightID, leftoversNightID: leftoversNightID, expectedMeal: night.mealID,
                                      expectedLeftoversMeal: later.mealID, expectedLeftoversPick: later.quickPick)
        week?.nights[index].locked = true
        week?.nights[laterIndex].mealID = nil
        week?.nights[laterIndex].mealName = nil
        week?.nights[laterIndex].quickPick = .leftovers
        week?.nights[laterIndex].reason = nil
        week?.nights[laterIndex].locked = true
        week?.nights[laterIndex].leftoversFrom = nightID
        unfillableNights.remove(leftoversNightID)
        requestNights = requestNights.filter { $0.value != leftoversNightID }
        let saved = await send(nightID: nightID, failure: String(localized: "Couldn't double the night. Check your connection and try again.")) {
            [client] in try await client.doubleIt(request)
        }
        if saved { noteListChanged() }
        return saved
    }

    /// From either night of the pair. What the leftovers night held before is only on the server, so the week reads back.
    @discardableResult
    func undoDouble(nightID: UUID) async -> Bool {
        guard !isBuilding, let night = week?.nights.first(where: { $0.id == nightID }) else { return false }
        let dish = night.leftoversFrom ?? nightID
        let saved = await send(nightID: dish, failure: String(localized: "Couldn't undo it. Check your connection and try again.")) {
            [client] in try await client.undoDouble(dish)
        }
        guard saved else { return false }
        noteListChanged()
        if !(await settleThenReload()) {
            errorMessage = String(localized: "It's undone, but the week didn't refresh. Pull down to see it.")
        }
        return true
    }

    // MARK: - Undo a change

    /// Nights with an undo on its way: the button waits, or a second tap would queue up and be refused after the first worked.
    private(set) var undoing: Set<UUID> = []

    /// Puts back what a night held before its last change. What it held comes from the server, which refuses if the night
    /// has moved since, so nothing's shown until the week reads back.
    @discardableResult
    func undoChange(_ change: PlanChange) async -> Bool {
        guard !isBuilding, !undoing.contains(change.nightID), nightIndex(change.nightID) != nil else { return false }
        undoing.insert(change.nightID)
        defer { undoing.remove(change.nightID) }
        let saved = await send(nightID: change.nightID, failure: String(localized: "Couldn't undo it. Check your connection and try again.")) {
            [client] in try await client.undoPlanChange(change.id)
        }
        guard saved else { return false }
        requestNights = requestNights.filter { $0.value != change.nightID }
        unfillableNights.remove(change.nightID)
        if !(await settleThenReload()) {
            errorMessage = String(localized: "It's undone, but the week didn't refresh. Pull down to see it.")
        }
        return true
    }

    /// An approved week whose list is behind a doubled or freezer night. The server keeps this; the store shows a change
    /// it just made before the next read.
    var listNeedsUpdating: Bool { week?.listStale == true }

    private func noteListChanged() {
        if week?.approvedAt != nil { week?.listStale = true }
    }

    /// Whether a change to this night moves another row on the server: its leftovers night, or a freezer item.
    private func isLinked(_ nightID: UUID) -> Bool {
        (week?.nights ?? []).contains { night in
            night.leftoversFrom == nightID
                || (night.id == nightID && (night.leftoversFrom != nil || night.stashItemID != nil))
        }
    }

    /// Reads the week again before something is built from it, so a list isn't written from what another planner changed.
    @discardableResult
    func refresh() async -> Bool {
        await settleThenReload()
    }

    /// Writes the list from the week as it is now. Without a fresh read it stops: these lines replace the week's own, and
    /// an old copy would quietly undo another planner's doubling.
    @discardableResult
    func approveLatest(_ build: (WeekLayout) -> [WeeklyList.Line]) async -> Bool {
        guard await refresh(), let layout else {
            errorMessage = String(localized: "Couldn't read the latest week, so the list wasn't updated. Check your connection and try again.")
            return false
        }
        return await approve(build(layout))
    }

    // MARK: - Approve

    /// Approves the week: its weekly list is written in one go, and the week is stamped approved.
    @discardableResult
    func approve(_ lines: [WeeklyList.Line]) async -> Bool {
        guard let planID = week?.planID, !isBuilding else { return false }
        do {
            try await client.approve(planID, lines)
            // The week may have switched while this was out; stamp only the one approved.
            if week?.planID == planID {
                week?.approvedAt = .now
                week?.listStale = false
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "Couldn't approve the week. Check your connection and try again.")
            return false
        }
    }

    // MARK: - Traditions

    func tradition(on weekday: Int) -> Tradition? {
        traditions.first { $0.weekday == weekday }
    }

    /// Sets a weekday's tradition (nil removes it). Nights already planned stay as they are until a rebuild.
    @discardableResult
    func setTradition(_ tradition: Tradition?, on weekday: Int) async -> Bool {
        do {
            try await client.setTradition(householdID, weekday, tradition)
            traditions = (traditions.filter { $0.weekday != weekday } + [tradition].compactMap { $0 })
                .sorted { $0.weekday < $1.weekday }
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "Couldn't save the tradition. Check your connection and try again.")
            return false
        }
    }

    /// One DayCard per night, with attendance in the family's order.
    func cards(members: [Member], sides: (UUID) -> [String] = { _ in [] }) -> [DayCardModel] {
        (week?.nights ?? []).map { Self.card(for: $0, members: members, sides: sides) }
    }

    /// A night's card. Badges are worked out by the caller, who knows the meal and the family's allergies.
    static func card(for night: WeekNight, members: [Member], sides: (UUID) -> [String] = { _ in [] },
                     badges: (UUID, Set<UUID>) -> [DayCardModel.Badge] = { _, _ in [] },
                     notes: (UUID, Set<UUID>) -> [String] = { _, _ in [] }, isAway: Bool = false,
                     leftoversDish: UUID? = nil, leftoversNote: String? = nil) -> DayCardModel {
        guard !isAway else {
            return DayCardModel(date: night.date, effort: night.effort, slot: .away, attendance: [], badges: [],
                                isLocked: false)
        }
        let home = night.home
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
            badges: (night.mealID ?? leftoversDish).map { badges($0, home) } ?? [],
            isLocked: night.locked,
            servingNotes: night.mealID.map { notes($0, home) } ?? [],
            leftoversNote: leftoversNote
        )
    }

    static func slot(for night: WeekNight, sides: [String]) -> DayCardModel.Slot {
        if let mealName = night.mealName {
            return .meal(name: mealName, photoURL: nil, reason: night.reason, sides: sides)
        }
        if let quickPick = night.quickPick { return .quickPick(quickPick) }
        return .empty
    }

    /// The card This Week shows: the night's dish, or the one its leftovers are from, with flags for whoever's home that
    /// night, or that they couldn't be checked if the library can't find it; what's doubled and where the leftovers are;
    /// nothing about cooking something already cooked.
    static func planCard(for night: WeekNight, nights: [WeekNight], members: [Member], library: [LibraryMeal],
                         allergies: [MemberAllergies], settings: HouseholdSettings, today: CalendarDay, minuteNow: Int,
                         sides: (UUID) -> [String] = { _ in [] }, notes: (UUID, Set<UUID>) -> [String] = { _, _ in [] },
                         isAway: Bool = false, lookup: LibraryLookup = .loaded) -> DayCardModel {
        let dish = night.mealID.flatMap { id in library.first { $0.id == id } }
            ?? DoubleIt.leftoversDish(on: night, nights: nights, library: library)
        let missing = dish == nil ? night.mealID ?? DoubleIt.missingLeftoversMeal(on: night, nights: nights, library: library) : nil
        let source = nights.first { $0.id == night.leftoversFrom }
        var model = card(for: night, members: members, sides: sides,
                         badges: { _, home in
                             guard let dish else {
                                 return NightBadges.allergyBadges(NightBadges.allergyCheck(
                                     dish: nil, library: library, allergies: allergies, home: home, lookup: lookup))
                             }
                             return NightBadges.badges(
                                 meal: dish, library: library, allergies: allergies, home: home, settings: settings,
                                 start: StartCooking.nudge(for: dish, on: night, settings: settings, today: today,
                                                           minuteNow: minuteNow),
                                 alreadyCooked: night.mealID == nil || night.stashItemID != nil,
                                 ruleDay: night.date >= today ? night.date : nil)
                         },
                         notes: notes, isAway: isAway, leftoversDish: dish?.id ?? missing,
                         leftoversNote: source.flatMap { DoubleIt.leftoversNote(from: $0) })
        if !isAway, let later = DoubleIt.leftoversNight(of: night, in: nights) {
            model.badges.append(.doubled(DoubleIt.doubledText(leftoversOn: later, today: today)))
        }
        return model
    }

    /// A night holds a dish this phone hasn't read, say one another phone just planned. Leftovers point at such a night too.
    static func holdsUnknownDish(_ nights: [WeekNight], library: [LibraryMeal]) -> Bool {
        nights.contains { night in
            night.mealID.map { id in !library.contains { $0.id == id } } ?? false
        }
    }

    func night(_ date: CalendarDay) -> WeekNight? {
        week?.nights.first { $0.date == date }
    }

    // MARK: - Private

    /// Queues a write behind the night's previous one, so rapid taps reach the server in the order made.
    /// Returns whether this write saved.
    @discardableResult
    private func send(nightID: UUID, failure: String, _ write: @escaping @Sendable () async throws -> Void) async -> Bool {
        writesStarted += 1
        let previous = lastWrite[nightID]
        let task = Task { () -> Bool in
            _ = await previous?.value
            do {
                try await write()
                errorMessage = nil
                return true
            } catch {
                errorMessage = message(for: error, otherwise: failure)
                await reload()
                return false
            }
        }
        lastWrite[nightID] = Task { _ = await task.value }
        return await task.value
    }

    /// After a refused write, show what the server has rather than guessing which tap to undo. Returns whether it read.
    @discardableResult
    private func reload() async -> Bool {
        guard let start, let loaded = try? await client.week(householdID, start) else { return false }
        if start == self.start { week = loaded }
        return true
    }

    /// A read after a write that went through: other taps may be on their way, so it waits for them, and goes again if
    /// another starts while it's waiting or reading. A few goes, then it leaves the screen as it is rather than undo a tap.
    /// Returns whether the screen now shows a fresh read.
    @discardableResult
    private func settleThenReload() async -> Bool {
        guard let start else { return false }
        for _ in 0..<3 {
            let started = writesStarted
            for write in Array(lastWrite.values) { await write.value }
            guard started == writesStarted else { continue }
            guard let loaded = try? await client.week(householdID, start) else { return false }
            guard started == writesStarted else { continue }
            if start == self.start { week = loaded }
            return true
        }
        return false
    }

    /// Refusals that have nothing to do with the connection get their own words.
    private func message(for error: any Error, otherwise: String) -> String {
        switch (error as? PostgrestError)?.code {
        case "22023":
            awayRefusals += 1
            return String(localized: "The family's away that night, so it can't take a dinner. Change the away dates in Family to plan it.")
        case "42501":
            return String(localized: "Only planners can change the plan.")
        case "FD001":
            return String(localized: "That night changed on another phone. Here's the latest; try again if you still want to.")
        case "FD002":
            return String(localized: "Someone already took that out of the freezer. Pick something else.")
        case "FD003":
            return String(localized: "That dish can't go on this night: it's been taken out of rotation, or it wasn't made yet.")
        case "FD012":
            return String(localized: "That night has changed since. Here's the latest; swap it if you still want to.")
        case "FD013":
            return String(localized: "Can't undo that one. Swap it instead.")
        default:
            return otherwise
        }
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
    /// Dated requests, landed on their nights.
    var requests: [DatedRequest] = []
    /// Someday requests several people want, on a night they're all home.
    var wanted: [WantedRequest] = []
    var traditions: [Tradition] = []
    /// The family's reactions: dislikes, snoozes, favorites, and likes (#42).
    var reactions = ReactionSummary()

    func inputs(for week: Week, today: CalendarDay) -> PlanningInputs {
        PlanningInputs(
            nights: week.nights.map { PlanningNight($0, isAway: $0.readsAway(in: settings.awayDates, today: today)) },
            meals: meals,
            history: history,
            settings: settings,
            memberNames: Dictionary(members.map { ($0.id, $0.firstName) }, uniquingKeysWith: { first, _ in first }),
            notForMe: reactions.notForMe,
            snoozedMealIDs: reactions.snoozed(today: today),
            favorites: reactions.favorites,
            likes: reactions.likes,
            requests: requests,
            wanted: wanted,
            traditions: traditions,
            today: max(today, week.start)
        )
    }
}
