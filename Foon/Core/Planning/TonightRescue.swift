import Foundation

/// Tonight rescue (docs/spec.md → Tonight rescue, #60): dinner fell through, so a few ideas from what's already in the
/// house, in the time there is. Pure and seeded, like Build my week: the same inputs and seed give the same ideas.
///
/// Four pools, in this order: leftovers from the last few days, the freezer, backup dinners, then quick library dishes
/// drawn by Build my week's own filters and weights. The first round takes one from each; the second, more backups and
/// then more dishes. Takeout, Freezer raid and Fend for yourselves fill any gap. Allergies are flagged, never a filter:
/// within a pool, unflagged ideas come first.
enum TonightRescue {
    static let minuteChoices = [20, 30, 45]
    static let defaultMinutes = 20
    /// Older than this, leftovers are a fridge cleanout question, not dinner.
    static let leftoversMaxAgeDays = 3

    /// Minutes for what's already cooked, which has no time of its own.
    enum Estimate {
        static let leftovers = 10
        static let freezer = 30
    }

    struct Idea: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Choosing it plans a plain Leftovers quick pick: the night names no dish (#157).
            case leftovers(mealID: UUID, name: String, cookedOn: CalendarDay)
            case freezer(FreezerItem)
            case backup(mealID: UUID)
            case quickDish(mealID: UUID)
            case quickPick(QuickPick)
        }

        let kind: Kind
        let title: String
        let why: String
        /// Nil for a quick pick, and for a backup dinner nobody has set a time on.
        let minutes: Int?
        let isEstimate: Bool
        let allergies: AllergyCheck
        let swapChoice: WeekStore.SwapChoice
        /// Why Build my week drew a quick dish. The AI wording reads it as words of its own, never `why`, which can
        /// name someone ("Nora's favorite").
        var reason: PlanReason? = nil
        /// A backup dinner whose ingredients are all marked in stock.
        var everythingIn = false

        var id: String {
            switch kind {
            case .leftovers(let mealID, _, let cookedOn): "leftovers-\(mealID)-\(cookedOn.isoString)"
            case .freezer(let item): "freezer-\(item.id)"
            case .backup(let mealID), .quickDish(let mealID): "meal-\(mealID)"
            case .quickPick(let pick): "pick-\(pick.rawValue)"
            }
        }

        var pollChoice: PollChoice {
            switch kind {
            case .leftovers: .quickPick(.leftovers)
            case .freezer(let item): .freezer(item.id)
            case .backup(let mealID), .quickDish(let mealID): .meal(mealID)
            case .quickPick(let pick): .quickPick(pick)
            }
        }

        var isFlagged: Bool { !allergies.flags.isEmpty }

        /// The library dish the night would hold. Leftovers are a quick pick, so they hold none.
        fileprivate var dishID: UUID? {
            switch kind {
            case .freezer(let item): item.mealID
            case .backup(let mealID), .quickDish(let mealID): mealID
            case .leftovers, .quickPick: nil
            }
        }

        /// Whether choosing it would leave tonight as it is.
        fileprivate func isAlready(_ night: WeekNight) -> Bool {
            switch kind {
            case .leftovers(let mealID, _, _): night.quickPick == .leftovers || night.mealID == mealID
            case .quickPick(let pick): night.quickPick == pick
            default: dishID == night.mealID
            }
        }
    }

    /// Exactly `count` ideas for tonight's night (`nightID`, in `week` and `planning.nights`), or none when the night
    /// isn't there. `planning` is what Build my week reads for this week (today, settings, reactions); its
    /// `onHandItemIDs` gain whatever `stock` has in or low. `allergies` are everyone's: who's home is worked out here.
    static func ideas(minutes: Int, nightID: UUID, week: [WeekNight], planning: PlanningInputs, freezer: [FreezerItem],
                      logs: [DinnerLog], stock: [UUID: StockState], allergies: [MemberAllergies], seed: UInt64,
                      count: Int = 3) -> [Idea] {
        guard let night = week.first(where: { $0.id == nightID }) else { return [] }
        let pools = Pools(minutes: minutes, night: night, week: week, planning: planning, stock: stock,
                          allergies: allergies)
        var rng = SeededGenerator(seed: seed)
        let frozen = pools.freezer(freezer)
        let inFreezer = Set(frozen.compactMap(\.dishID))
        let backups = pools.backups(excluding: inFreezer, rng: &rng)
        let dishes = pools.quickDishes(excluding: inFreezer, seed: seed, count: count)
        let freezerFits = minutes >= Estimate.freezer

        var picks = Picks(count: count, night: night)
        picks.addFirst(of: pools.leftovers(logs))
        if freezerFits { picks.addFirst(of: frozen) }
        picks.addFirst(of: backups)
        picks.addFirst(of: dishes)
        picks.add(backups)
        picks.add(dishes)
        if !freezerFits { picks.addFirst(of: frozen) }
        let hasFreezer = picks.ideas.contains { if case .freezer = $0.kind { true } else { false } }
        let fillers: [QuickPick] = [.takeout] + (hasFreezer ? [] : [.freezerRaid]) + [.fendForYourselves, .eatOut]
        picks.add(fillers.map(filler))
        return picks.ideas
    }

    /// Tonight, with nothing logged yet, not inside the away dates, and someone home. A night with no attendance rows
    /// hasn't been laid out, so it isn't nobody home.
    static func offers(night: WeekNight, logged: Bool, isAway: Bool, today: CalendarDay) -> Bool {
        night.date == today && !logged && !isAway && (night.attendance.isEmpty || !night.home.isEmpty)
    }

    // MARK: - What each idea says

    static func timeText(minutes: Int, isEstimate: Bool) -> String {
        isEstimate
            ? String(localized: "around \(minutes) min", comment: "Tonight rescue: an estimated time to dinner")
            : String(localized: "\(minutes) min", comment: "Tonight rescue: the dish's own time to dinner")
    }

    static func leftoversWhy(name: String, cookedOn: CalendarDay, today: CalendarDay,
                             calendar: Calendar = .current) -> String {
        let days = today.days(since: cookedOn)
        guard days > 1 else {
            return String(localized: "Leftover \(name) from yesterday",
                          comment: "Tonight rescue: leftovers, cooked yesterday")
        }
        let weekday = cookedOn.date(in: calendar).formatted(Date.FormatStyle(calendar: calendar).weekday(.wide))
        return String(localized: "Leftover \(name) from \(weekday) · \(days) days old",
                      comment: "Tonight rescue: leftovers: the dish, the day it was cooked, and how many days ago")
    }

    static func freezerWhy(madeOn: CalendarDay, today: CalendarDay) -> String {
        [FreezerStash.reason(madeOn: madeOn, today: today), timeText(minutes: Estimate.freezer, isEstimate: true)]
            .joined(separator: " · ")
    }

    static func backupWhy(minutes: Int?, everythingIn: Bool) -> String {
        let label = everythingIn
            ? String(localized: "Backup dinner, everything's in",
                     comment: "Tonight rescue: a backup dinner whose ingredients are all marked in stock")
            : String(localized: "Backup dinner", comment: "Tonight rescue: a dish tagged Backup dinner")
        let time = minutes.map { timeText(minutes: $0, isEstimate: false) }
            ?? String(localized: "time not set", comment: "Tonight rescue: a backup dinner with no cooking time")
        return [label, time].joined(separator: " · ")
    }

    static func dishWhy(_ reason: PlanReason, minutes: Int, isEstimate: Bool) -> String {
        [reason.text, timeText(minutes: minutes, isEstimate: isEstimate)].joined(separator: " · ")
    }

    static func fillerWhy(_ pick: QuickPick) -> String {
        switch pick {
        case .takeout: String(localized: "Nothing to cook", comment: "Tonight rescue: why Takeout")
        case .freezerRaid: String(localized: "Whatever's in the freezer", comment: "Tonight rescue: why Freezer raid")
        case .fendForYourselves: String(localized: "Everyone makes their own", comment: "Tonight rescue: why Fend")
        case .eatOut: String(localized: "Nobody cooks or cleans up", comment: "Tonight rescue: why Eat out")
        case .leftovers: String(localized: "Whatever's in the fridge", comment: "Tonight rescue: why Leftovers")
        }
    }

    private static func filler(_ pick: QuickPick) -> Idea {
        Idea(kind: .quickPick(pick), title: DayCardText.quickPickLabel(pick), why: fillerWhy(pick), minutes: nil,
             isEstimate: false, allergies: AllergyCheck(), swapChoice: .quickPick(pick))
    }

    /// Stable: within a pool, the order it had.
    fileprivate static func unflaggedFirst(_ ideas: [Idea]) -> [Idea] {
        ideas.filter { !$0.isFlagged } + ideas.filter(\.isFlagged)
    }
}

// MARK: - Picking

private struct Picks {
    let count: Int
    let night: WeekNight
    private(set) var ideas: [TonightRescue.Idea] = []

    private func accepts(_ idea: TonightRescue.Idea) -> Bool {
        ideas.count < count && !idea.isAlready(night)
            && !ideas.contains { $0.id == idea.id || ($0.dishID != nil && $0.dishID == idea.dishID) }
    }

    mutating func addFirst(of pool: [TonightRescue.Idea]) {
        if let idea = pool.first(where: accepts) { ideas.append(idea) }
    }

    mutating func add(_ pool: [TonightRescue.Idea]) {
        for idea in pool where accepts(idea) { ideas.append(idea) }
    }
}

// MARK: - The pools

private struct Pools {
    typealias Idea = TonightRescue.Idea

    let minutes: Int
    let night: WeekNight
    let week: [WeekNight]
    let planning: PlanningInputs
    let stock: [UUID: StockState]
    let allergies: [MemberAllergies]

    private var today: CalendarDay { planning.today }
    private var library: [LibraryMeal] { planning.meals }
    private var settings: HouseholdSettings { planning.settings }

    private func check(_ meal: LibraryMeal?) -> AllergyCheck {
        NightBadges.allergyCheck(dish: meal, library: library, allergies: allergies, home: night.allergyHome(allergies),
                                 lookup: .loaded)
    }

    /// The dislike rule and snoozes, as everywhere else: one "not for me" from someone home skips it.
    private func isSkipped(_ mealID: UUID) -> Bool {
        let dislikes = planning.notForMe[mealID] ?? [:]
        return planning.snoozedMealIDs.contains(mealID) || night.home.contains { (dislikes[$0] ?? 0) >= 1 }
    }

    private func breaksFoodRule(_ meal: LibraryMeal) -> Bool {
        !FoodRuleMatcher.broken(by: meal, on: night.date, rules: settings.foodRules, library: library).isEmpty
    }

    private func fits(_ meal: LibraryMeal) -> Bool? {
        StartCooking.minutes(for: meal).map { $0.minutes <= minutes }
    }

    /// No marinade or thaw to start: it's too late for one tonight.
    private func hasNothingAhead(_ meal: LibraryMeal) -> Bool {
        BuildMyWeek.leadHours(meal, settings: settings) == 0
    }

    /// Dinners in the last few days that left leftovers, oldest first, unless a later Leftovers dinner ate them. A dish
    /// the library no longer has still shows, its allergies unchecked; it can't break a food rule anyone can see.
    func leftovers(_ logs: [DinnerLog]) -> [Idea] {
        let meals = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let eaten = logs.filter { $0.quickPick == .leftovers }.map(\.date)
        let ideas = logs
            .filter { log in
                log.leftovers == true && (1...TonightRescue.leftoversMaxAgeDays).contains(today.days(since: log.date))
                    && !eaten.contains { $0 > log.date }
            }
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            .compactMap { log -> Idea? in
                guard let mealID = log.mealID, !isSkipped(mealID) else { return nil }
                let meal = meals[mealID]
                if let meal, breaksFoodRule(meal) { return nil }
                let name = meal?.name ?? log.mealName
                    ?? String(localized: "A dish", comment: "Leftovers whose dish name couldn't be read")
                return Idea(kind: .leftovers(mealID: mealID, name: name, cookedOn: log.date), title: name,
                            why: TonightRescue.leftoversWhy(name: name, cookedOn: log.date, today: today),
                            minutes: TonightRescue.Estimate.leftovers, isEstimate: true, allergies: check(meal),
                            swapChoice: .quickPick(.leftovers))
            }
        return TonightRescue.unflaggedFirst(ideas)
    }

    /// What Swap and the poll offer from the stash, one per dish, oldest first.
    func freezer(_ items: [FreezerItem]) -> [Idea] {
        let offers = PollRules.oneOfEachDish(
            FreezerStash.offers(items, on: night, week: week, library: library, notForMe: planning.notForMe,
                                snoozed: planning.snoozedMealIDs, allergies: allergies, today: today,
                                foodRules: settings.foodRules))
        return TonightRescue.unflaggedFirst(offers.map { offer in
            let reason = FreezerStash.reason(madeOn: offer.item.madeOn, today: today)
            return Idea(kind: .freezer(offer.item), title: offer.meal.name,
                        why: TonightRescue.freezerWhy(madeOn: offer.item.madeOn, today: today),
                        minutes: TonightRescue.Estimate.freezer, isEstimate: true,
                        allergies: AllergyCheck(flags: offer.flags, note: offer.uncheckedNote),
                        swapChoice: .freezer(offer.item, reason: reason))
        })
    }

    /// The poll's backup dinners within the time and with nothing to start ahead, timed ones first; one with no time
    /// set is kept, since it's a backup for a reason. Then never made, then least recently made; ties are a seeded
    /// shuffle.
    func backups(excluding inFreezer: Set<UUID>, rng: inout SeededGenerator) -> [Idea] {
        let lastMade = Dictionary(planning.history.map { ($0.mealID, $0.lastMade) }, uniquingKeysWith: { max($0, $1) })
        let meals = PollRules.backupDinners(library: library, night: night, week: week, stock: stock,
                                            notForMe: planning.notForMe, snoozed: planning.snoozedMealIDs,
                                            foodRules: settings.foodRules)
            .filter { !inFreezer.contains($0.id) && fits($0) != false && hasNothingAhead($0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .shuffled(using: &rng)
        let ranked = meals.enumerated().sorted { lhs, rhs in
            func key(_ entry: (offset: Int, element: LibraryMeal)) -> (Int, Int, Int) {
                let daysSince = lastMade[entry.element.id].map { today.days(since: $0) } ?? Int.max
                return (fits(entry.element) == nil ? 1 : 0, -daysSince, entry.offset)
            }
            return key(lhs) < key(rhs)
        }
        return TonightRescue.unflaggedFirst(ranked.map { backupIdea($0.element) })
    }

    private func backupIdea(_ meal: LibraryMeal) -> Idea {
        let time = StartCooking.minutes(for: meal)
        let everythingIn = !meal.ingredients.isEmpty
            && meal.ingredients.allSatisfy { stock[$0.itemID] == .in || stock[$0.itemID] == .low }
        return Idea(kind: .backup(mealID: meal.id), title: meal.name,
                    why: TonightRescue.backupWhy(minutes: time?.minutes, everythingIn: everythingIn),
                    minutes: time?.minutes, isEstimate: false, allergies: check(meal),
                    swapChoice: .meal(id: meal.id, name: meal.name), everythingIn: everythingIn)
    }

    /// Library dishes that can be on the table in time with nothing started ahead, drawn as Swap draws them. Trial
    /// dishes wait for a night with time to try them, and a dish with no time set can't promise it fits.
    func quickDishes(excluding inFreezer: Set<UUID>, seed: UInt64, count: Int) -> [Idea] {
        let eligible = library.filter { meal in
            meal.status == .active && !meal.tags.contains(.backup) && !inFreezer.contains(meal.id)
                && fits(meal) == true
                && hasNothingAhead(meal)
                && PollRules.isInStock(meal, stock: stock)
                && DishTraits(name: meal.name, tags: meal.tags).equipment.isDisjoint(with: settings.missingEquipment)
                && !breaksFoodRule(meal)
        }
        let byID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var inputs = planning
        inputs.meals = eligible
        inputs.onHandItemIDs.formUnion(stock.filter { $0.value != .out }.keys)
        // The time chosen is the limit tonight, so a rushed night's Quick-tag rule gives way to it.
        inputs.nights = planning.nights.map { planned in
            var planned = planned
            if planned.id == night.id, planned.effort == .rushed { planned.effort = .normal }
            return planned
        }
        let ideas = BuildMyWeek.suggestions(night: night.id, inputs: inputs, seed: seed, count: count)
            .compactMap { suggestion -> Idea? in
                guard let meal = byID[suggestion.mealID], let time = StartCooking.minutes(for: meal) else { return nil }
                return Idea(kind: .quickDish(mealID: meal.id), title: meal.name,
                            why: TonightRescue.dishWhy(suggestion.reason, minutes: time.minutes,
                                                       isEstimate: time.isEstimate),
                            minutes: time.minutes, isEstimate: time.isEstimate, allergies: check(meal),
                            swapChoice: .meal(id: meal.id, name: meal.name), reason: suggestion.reason)
            }
        return TonightRescue.unflaggedFirst(ideas)
    }
}
