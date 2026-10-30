import Foundation

/// Build my week (docs/spec.md → Build my week algorithm): a pure `(inputs, seed) -> draft`.
/// The same inputs and seed always give the same draft, on every device and whatever order the library
/// arrives in, so tests can pin exact results.
///
/// Steps, in order:
/// 1. **Keep** pinned nights, event nights, and nights before `today` as they are, then land dated requests
///    on their nights, then standing traditions on their weekdays, then someday requests several people want on
///    the first night they're all home (all saved locked).
/// 2. **Food-rule nights** draw next, before anything else spends the few dishes they can have.
/// 3. **Special slots:** takeout on the busiest nights, trial dishes on full-attendance nights, then leftover
///    nights, each after a big-batch meal when one fits. Kept nights, past ones too, count toward each setting.
/// 4. **Fill** the rest, rushed nights first and then in date order, with a weighted draw from dishes that
///    pass every filter. The season and what's already in the week only move the odds, after the filters.
enum BuildMyWeek {
    /// Scoring weights. A dish's weight is
    /// `recency × (1 + favorite × favoritesHome) × (1 + onHand × fractionOnHand) × (1 + like × likes)
    /// × inSeason × repeatInWeek^repeats`.
    enum Weight {
        /// Recency is days from last made to that night, capped: past three months a dish is simply "due",
        /// and an uncapped value would let one long-forgotten dish crowd out everything else. A dish never
        /// made counts as fully due.
        static let recencyCapDays = 90
        /// One favorite-er at the table triples the odds, two make it five times: the spec's "big boost",
        /// since cooking what someone home loves is the surest way to a happy table.
        static let favoritePerMemberHome = 2.0
        /// A dish with everything on hand has double the odds (half on hand, 1.5×): less to buy, less waste.
        static let onHand = 1.0
        /// A gentle nudge per thumbs-up, capped, so popular dishes lean ahead without taking over the week.
        static let likePerReaction = 0.1
        static let likeCap = 5
        /// Grill and cold dishes in summer, soups and slow cooker in winter: double the odds, the same lean as
        /// everything on hand, so the season shows without outvoting a favorite or a dish long overdue.
        static let inSeason = 2.0
        /// Halved for each dish of the same category already in the week. Never zero, so a family that mostly
        /// makes pasta still gets a full week. With the season boost, a second grill night is back to even odds.
        static let repeatInWeek = 0.5
    }

    /// Advance prep (thawing, marinating) is measured in hours before dinner.
    enum Prep {
        /// Roughly morning to dinner on the day itself: an 8-hour slow cooker works tonight, a thaw doesn't.
        static let hoursBeforeDinnerToday = 8
        /// A thaw-first dish with no longer prep step needs a day in the fridge.
        static let thawFirstLeadHours = 24
    }

    static func draft(_ inputs: PlanningInputs, seed: UInt64) -> [NightPlan] {
        let planner = Planner(inputs)
        var rng = SeededGenerator(seed: seed)
        var state = DraftState(planner: planner)
        state.landRequests()
        state.landTraditions()
        state.landWanted()
        state.fillFoodRuleNights(rng: &rng)
        state.placeTakeout()
        state.placeNewDishes(rng: &rng)
        state.placeLeftovers(rng: &rng)
        state.fillTheRest(rng: &rng)
        state.sayWhichTraditionsSatOut()
        return state.plans
    }

    /// Re-rolls one night from the week as saved, leaving every other night alone. Returns nil when the night
    /// stays as it is: it's kept (pinned, event, past, or a dated request), it holds a quick pick (changing a
    /// night's kind is Swap's job, #25), or nothing else fits.
    ///
    /// Never picks a meal already in the week, the night's own included, so the night actually changes.
    /// The slot keeps its kind: a trial dish draws trials first, and a big batch feeding tomorrow's leftovers
    /// draws another big batch or stays put.
    static func shuffle(night nightID: UUID, inputs: PlanningInputs, seed: UInt64) -> NightPlan? {
        let planner = Planner(inputs)
        guard let index = planner.nights.firstIndex(where: { $0.id == nightID }) else { return nil }
        let night = planner.nights[index]
        guard !planner.isKept(night), !planner.isRequested(night), night.quickPick == nil, !night.isNobodyHome
        else { return nil }
        let used = Set(planner.nights.compactMap(\.mealID))
        let current = night.mealID.flatMap { planner.mealsByID[$0] }
        let feedsLeftovers = current?.tags.contains(.leftovers) == true && planner.nights.indices.contains(index + 1)
            && planner.nights[index + 1].quickPick == .leftovers
            && planner.nights[index + 1].date.days(since: night.date) == 1
        let trialsElsewhere = planner.nights.filter { $0.id != nightID && planner.isTrial($0.mealID) }.count
        let budgetLeft = trialsElsewhere < inputs.settings.newDishesPerWeek
        let pools: [[LibraryMeal]] = if current?.status == .trial {
            [planner.trialMeals, planner.knownMeals]
        } else if current == nil || budgetLeft {
            [planner.knownMeals, planner.trialMeals]
        } else {
            [planner.knownMeals]
        }
        // What feeds tomorrow's leftovers is on tomorrow's table too, so tomorrow's food rule counts.
        let tomorrow = feedsLeftovers ? planner.nights[index + 1].date : nil
        var rng = SeededGenerator(seed: seed)
        // Pick for me on an empty night is the planner choosing, and a dish already needing what they don't have has
        // nothing to lose. Otherwise Shuffle won't trade a dish they can make for one they can't.
        let canTakeAny = current.map(planner.needsMissingEquipment) ?? true
        for allowingMissingEquipment in canTakeAny ? [false, true] : [false] {
            for pool in pools {
                let pool = tomorrow.map { day in pool.filter { !planner.breaksFoodRule($0, on: day) } } ?? pool
                guard let meal = planner.draw(for: night, from: pool, excluding: used, replacing: night.mealID,
                                              requiring: feedsLeftovers ? .leftovers : nil,
                                              allowingMissingEquipment: allowingMissingEquipment, rng: &rng)
                else { continue }
                return NightPlan(nightID: night.id, date: night.date, pick: .meal(meal.id),
                                 reason: feedsLeftovers ? .bigBatch : planner.reason(for: meal, on: night),
                                 isKept: false)
            }
        }
        return nil
    }
}

// MARK: - Swap suggestions

extension BuildMyWeek {
    /// A dish the swap sheet offers, with the chip saying why.
    struct Suggestion: Equatable, Sendable {
        let mealID: UUID
        let reason: PlanReason
    }

    /// Up to `count` different dishes for one night, drawn by the same filters and weights as a build: never a
    /// dish already in the week (the night's own included), trial dishes only while the week's budget has room.
    /// Unlike Shuffle, any night can be swapped, so kept nights get suggestions too. A night before today is
    /// logging what was eaten, so prep time and the repeat window don't apply to it. Each pick joins `used`, so it
    /// counts as a repeat for the next: three suggestions are three choices, not three pastas. Dishes usually using
    /// equipment the household doesn't have only come after everything else that fits, and the sheet says so. A dish that
    /// looks to break a food rule never comes: the sheet lists those apart, saying why, and the planner can pick one.
    static func suggestions(night nightID: UUID, inputs: PlanningInputs, seed: UInt64, count: Int = 3) -> [Suggestion] {
        let planner = Planner(inputs)
        guard let night = planner.nights.first(where: { $0.id == nightID }) else { return [] }
        var used = Set(planner.nights.compactMap(\.mealID))
        let trialsElsewhere = planner.nights.filter { $0.id != nightID && planner.isTrial($0.mealID) }.count
        let pool = trialsElsewhere < inputs.settings.newDishesPerWeek
            ? planner.knownMeals + planner.trialMeals : planner.knownMeals
        var rng = SeededGenerator(seed: seed)
        var picks: [Suggestion] = []
        let past = night.date < inputs.today
        while picks.count < count,
              let meal = planner.draw(for: night, from: pool, excluding: used, replacing: night.mealID,
                                      loggingPast: past, rng: &rng) {
            used.insert(meal.id)
            picks.append(Suggestion(mealID: meal.id, reason: planner.reason(for: meal, on: night)))
        }
        while picks.count < count,
              let meal = planner.draw(for: night, from: pool, excluding: used, replacing: night.mealID,
                                      allowingMissingEquipment: true, rng: &rng) {
            used.insert(meal.id)
            picks.append(Suggestion(mealID: meal.id, reason: planner.reason(for: meal, on: night)))
        }
        return picks
    }
}

// MARK: - Lookups and rules

private struct Planner {
    let inputs: PlanningInputs
    /// In date order; the draft comes back in this order.
    let nights: [PlanningNight]
    let historyByMeal: [UUID: MealHistory]
    let mealsByID: [UUID: LibraryMeal]
    /// In-rotation dishes out of trial, including ones never made: onboarding copies dishes the family
    /// already cooks, so no history doesn't mean new.
    let knownMeals: [LibraryMeal]
    /// Dishes on trial: what "new dishes per week" counts and caps.
    let trialMeals: [LibraryMeal]
    let traitsByMeal: [UUID: DishTraits]
    /// What each dish looks to have, of what the household's rules ask about. Empty without rules.
    let foodRuleHits: [UUID: Set<FoodRule.Avoid>]

    init(_ inputs: PlanningInputs) {
        self.inputs = inputs
        nights = inputs.nights.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        historyByMeal = Dictionary(inputs.history.map { ($0.mealID, $0) }, uniquingKeysWith: { first, _ in first })
        mealsByID = Dictionary(inputs.meals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A fixed order, so the same seed draws the same dish however the library was loaded.
        let rotation = inputs.meals.filter(\.status.isInRotation).sorted { $0.id.uuidString < $1.id.uuidString }
        knownMeals = rotation.filter { $0.status != .trial }
        trialMeals = rotation.filter { $0.status == .trial }
        traitsByMeal = mealsByID.mapValues { DishTraits(name: $0.name, tags: $0.tags) }
        let asked = Set(inputs.settings.foodRules.map(\.avoid))
        foodRuleHits = asked.isEmpty ? [:] : mealsByID.mapValues { meal in
            asked.filter { FoodRuleMatcher.looksLikeIt($0, meal: meal, library: inputs.meals) }
        }
    }

    func isKept(_ night: PlanningNight) -> Bool {
        night.locked || night.effort == .event || night.date < inputs.today
    }

    func isRequested(_ night: PlanningNight) -> Bool {
        inputs.requests.contains { $0.date == night.date && $0.mealID == night.mealID }
    }

    func isTrial(_ mealID: UUID?) -> Bool {
        mealID.flatMap { mealsByID[$0] }?.status == .trial
    }

    func hasTag(_ tag: MealTag, _ pick: NightPick?) -> Bool {
        pick?.mealID.flatMap { mealsByID[$0] }?.tags.contains(tag) ?? false
    }

    func name(of memberID: UUID) -> String? { inputs.memberNames[memberID] }

    // MARK: Filters

    /// Step 3 of the spec. Allergies are never a filter: they're flagged on the card, and the planner decides. A food rule
    /// is: a household that set one doesn't want the dish, and Nothing fits is better than a wrong dish. It's a guess from
    /// the name and ingredients, so the card says "looks like", and Swap lists what it held back.
    /// `allowingMissingEquipment` is for when the planner is choosing (Swap, Pick for me). A build never plans such a
    /// dish on its own: nobody chose it, so the night says Nothing fits, like one where everything's been disliked.
    func fits(_ meal: LibraryMeal, on night: PlanningNight, loggingPast: Bool = false,
              allowingMissingEquipment: Bool = false) -> Bool {
        guard meal.status.isInRotation, !inputs.snoozedMealIDs.contains(meal.id) else { return false }
        if loggingPast { return true }
        if breaksFoodRule(meal, on: night.date) { return false }
        if !allowingMissingEquipment, needsMissingEquipment(meal) { return false }
        if let lastMade = historyByMeal[meal.id]?.lastMade,
           night.date.days(since: lastMade) < inputs.settings.repeatWindowDays { return false }
        let notForMe = inputs.notForMe[meal.id] ?? [:]
        if night.home.contains(where: { (notForMe[$0] ?? 0) >= 1 }) { return false }
        if night.effort == .rushed, !meal.tags.contains(.quick) { return false }
        return hoursUntilDinner(on: night) >= leadHours(meal)
    }

    func breaksFoodRule(_ meal: LibraryMeal, on day: CalendarDay) -> Bool {
        guard let hits = foodRuleHits[meal.id], !hits.isEmpty else { return false }
        return inputs.settings.foodRules.contains { $0.applies(on: day) && hits.contains($0.avoid) }
    }

    /// A rule for some nights and not others: leftovers with no dish behind them could be from a night it didn't apply. A
    /// rule for every night has already kept such a dish out of the week.
    func hasOccasionalFoodRule(on day: CalendarDay) -> Bool {
        inputs.settings.foodRules.contains { $0.nights != .everyNight && $0.applies(on: day) }
    }

    func needsMissingEquipment(_ meal: LibraryMeal) -> Bool {
        traitsByMeal[meal.id]?.equipment.isDisjoint(with: inputs.settings.missingEquipment) == false
    }

    /// Time from this morning to that night's dinner: tonight leaves the day, each night after adds a full one.
    private func hoursUntilDinner(on night: PlanningNight) -> Int {
        24 * night.date.days(since: inputs.today) + BuildMyWeek.Prep.hoursBeforeDinnerToday
    }

    private func leadHours(_ meal: LibraryMeal) -> Int {
        let steps = meal.prepSteps.compactMap(\.leadHours).max() ?? 0
        return meal.tags.contains(.thawFirst) ? max(steps, BuildMyWeek.Prep.thawFirstLeadHours) : steps
    }

    // MARK: Scoring

    func weight(of meal: LibraryMeal, on night: PlanningNight) -> Double {
        let cap = BuildMyWeek.Weight.recencyCapDays
        let recency = Double(min(max(daysSinceMade(meal, on: night) ?? cap, 1), cap))
        let favorites = Double(favoritersHome(meal, on: night).count)
        let likes = Double(min(inputs.likes[meal.id] ?? 0, BuildMyWeek.Weight.likeCap))
        return recency
            * (1 + BuildMyWeek.Weight.favoritePerMemberHome * favorites)
            * (1 + BuildMyWeek.Weight.onHand * fractionOnHand(meal))
            * (1 + BuildMyWeek.Weight.likePerReaction * likes)
            * (traitsByMeal[meal.id]?.isInSeason(night.date.season) == true ? BuildMyWeek.Weight.inSeason : 1)
    }

    /// Dishes in each category among those already in the week, kept nights included.
    private func categoryCounts(in used: Set<UUID>) -> [DishCategory: Int] {
        used.reduce(into: [:]) { counts, mealID in
            for category in traitsByMeal[mealID]?.categories ?? [] { counts[category, default: 0] += 1 }
        }
    }

    /// A dish in two categories answers to the more repeated one, not both: Chicken Alfredo after a pasta night
    /// is one repeat.
    private func varietyFactor(of meal: LibraryMeal, counts: [DishCategory: Int]) -> Double {
        let repeats = traitsByMeal[meal.id]?.categories.map { counts[$0] ?? 0 }.max() ?? 0
        return pow(BuildMyWeek.Weight.repeatInWeek, Double(repeats))
    }

    /// A weighted draw among the pool's dishes that fit this night and aren't already in the week.
    /// `replacing` is the dish leaving this night: it can't be drawn again, but it isn't a repeat either.
    func draw(for night: PlanningNight, from pool: [LibraryMeal], excluding used: Set<UUID>,
              replacing: UUID? = nil, requiring tag: MealTag? = nil, loggingPast: Bool = false,
              allowingMissingEquipment: Bool = false, rng: inout SeededGenerator) -> LibraryMeal? {
        let candidates = pool.filter { meal in
            !used.contains(meal.id)
                && fits(meal, on: night, loggingPast: loggingPast, allowingMissingEquipment: allowingMissingEquipment)
                && (tag.map { meal.tags.contains($0) } ?? true)
        }
        let counts = categoryCounts(in: used.filter { $0 != replacing })
        let weights = candidates.map { weight(of: $0, on: night) * varietyFactor(of: $0, counts: counts) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var remaining = Double.random(in: 0..<total, using: &rng)
        for (meal, weight) in zip(candidates, weights) {
            if remaining < weight { return meal }
            remaining -= weight
        }
        return candidates.last
    }

    /// The single most telling reason for the chip, from most to least personal.
    func reason(for meal: LibraryMeal, on night: PlanningNight) -> PlanReason {
        if meal.status == .trial { return .somethingNew }
        let favoriters = favoritersHome(meal, on: night)
        if !favoriters.isEmpty {
            let names = favoriters.compactMap(name(of:)).sorted()
            return .favorite(name: names.first)
        }
        if night.effort == .rushed { return .quickForRushedNight }
        if fractionOnHand(meal) >= 0.5 { return .usesWhatsOnHand }
        let days = daysSinceMade(meal, on: night)
        if (days ?? 0) < 14, (inputs.likes[meal.id] ?? 0) >= 3 { return .familyLikesIt }
        if let days, days >= 1 { return .notHadIn(days: days) }
        return .dueForATurn
    }

    private func daysSinceMade(_ meal: LibraryMeal, on night: PlanningNight) -> Int? {
        historyByMeal[meal.id].map { night.date.days(since: $0.lastMade) }
    }

    private func favoritersHome(_ meal: LibraryMeal, on night: PlanningNight) -> [UUID] {
        night.home.filter { inputs.favorites[$0]?.contains(meal.id) ?? false }
    }

    private func fractionOnHand(_ meal: LibraryMeal) -> Double {
        guard !meal.ingredients.isEmpty else { return 0 }
        let onHand = meal.ingredients.filter { inputs.onHandItemIDs.contains($0.itemID) }.count
        return Double(onHand) / Double(meal.ingredients.count)
    }
}

// MARK: - The draft as it's built

private struct DraftState {
    let planner: Planner
    var plans: [NightPlan]
    var used: Set<UUID>
    /// Nights a tradition sat out for a food rule, and whose: the night says so, whatever it ends up holding.
    var traditionsSatOut: [Int: String?] = [:]

    init(planner: Planner) {
        self.planner = planner
        plans = planner.nights.map { night in
            let kept = planner.isKept(night)
            let pick: NightPick? = night.mealID.map(NightPick.meal) ?? night.quickPick.map(NightPick.quickPick)
            let reason: PlanReason? = !kept && night.isNobodyHome ? .nobodyHome : nil
            return NightPlan(nightID: night.id, date: night.date, pick: kept ? pick : nil, reason: reason, isKept: kept)
        }
        used = Set(plans.compactMap(\.pick?.mealID))
    }

    /// Nights still to fill. A night nobody's home stays empty: there's no dinner to plan.
    private var openIndices: [Int] {
        plans.indices.filter { !plans[$0].isKept && plans[$0].pick == nil && plans[$0].reason != .nobodyHome }
    }

    private func count(_ matches: (NightPick) -> Bool) -> Int {
        plans.compactMap(\.pick).filter(matches).count
    }

    private var trialBudgetLeft: Int {
        planner.inputs.settings.newDishesPerWeek - count { planner.isTrial($0.mealID) }
    }

    private mutating func fill(_ index: Int, with pick: NightPick, reason: PlanReason, kept: Bool = false) {
        plans[index].pick = pick
        plans[index].reason = reason
        plans[index].isKept = kept
        if let mealID = pick.mealID { used.insert(mealID) }
    }

    /// A request is the family asking out loud, so it skips the filters (a rushed night, someone home who
    /// doesn't love it); it still needs a dish in rotation and an open night, and never doubles a dish already
    /// in the week. First request for a night wins. Saved locked, like a tradition: the idea is marked planned on
    /// that night, so a Rebuild mustn't take the dish away.
    mutating func landRequests() {
        for request in planner.inputs.requests {
            guard let meal = planner.mealsByID[request.mealID], meal.status.isInRotation, !used.contains(meal.id),
                  let index = openIndices.first(where: { plans[$0].date == request.date }) else { continue }
            fill(index, with: .meal(meal.id), reason: .request(name: planner.name(of: request.requesterID)),
                 kept: true)
            plans[index].locks = true
        }
    }

    /// Someday requests with two or more me-toos (docs/spec.md → Inbox rules): most wanted first, each on the first
    /// open night everyone who wants it is home, saved locked. Like any request, it skips the filters; it still needs a
    /// dish in rotation that isn't already in the week. No such night, and it waits for another week. It has no date, so it
    /// takes a night a food rule doesn't apply to if there is one; if not, it lands like a dated request, and the card says.
    mutating func landWanted() {
        let ordered = planner.inputs.wanted.enumerated()
            .sorted { ($0.element.wanters.count, $1.offset) > ($1.element.wanters.count, $0.offset) }
            .map(\.element)
        for request in ordered {
            guard let meal = planner.mealsByID[request.mealID], meal.status.isInRotation, !used.contains(meal.id),
                  case let homes = openIndices.filter({ request.wanters.isSubset(of: planner.nights[$0].home) }),
                  let index = homes.first(where: { !planner.breaksFoodRule(meal, on: plans[$0].date) }) ?? homes.first
            else { continue }
            fill(index, with: .meal(meal.id), reason: .request(name: planner.name(of: request.requesterID)), kept: true)
            plans[index].locks = true
        }
    }

    /// Taco Tuesday lands on every open Tuesday, kept and saved locked. A dated request for that night wins, and
    /// a tradition meal no longer in rotation, or already in the week, is skipped. It also sits out a week when
    /// it's snoozed or someone home that night said "not for me" (the dislike rule); the repeat window, rushed
    /// nights, and prep time don't apply, since a weekly tradition is chosen on purpose. Nor does it land on a night a food
    /// rule looks to rule it out: nobody asked for it this week, so the night fills as usual and its chip says the
    /// tradition sat out. Quick picks count toward their settings like any other.
    mutating func landTraditions() {
        for tradition in planner.inputs.traditions {
            for index in openIndices where plans[index].date.isoWeekday == tradition.weekday {
                if let mealID = tradition.pick.mealID {
                    guard let meal = planner.mealsByID[mealID], meal.status.isInRotation, !used.contains(mealID),
                          !planner.inputs.snoozedMealIDs.contains(mealID) else { continue }
                    let notForMe = planner.inputs.notForMe[mealID] ?? [:]
                    if planner.nights[index].home.contains(where: { (notForMe[$0] ?? 0) >= 1 }) { continue }
                    if planner.breaksFoodRule(meal, on: plans[index].date) {
                        traditionsSatOut[index] = .some(tradition.name)
                        continue
                    }
                }
                fill(index, with: tradition.pick, reason: .tradition(name: tradition.name), kept: true)
                plans[index].locks = true
            }
        }
    }

    /// A night a rule applies to has fewer dishes to choose from, and a dish spent on Monday can leave Friday with nothing
    /// when Monday could have had anything. A rule for every night makes no night special, so it changes no order.
    /// Finding nothing leaves the night open: it can still take a special slot, and the fill says Nothing fits.
    mutating func fillFoodRuleNights(rng: inout SeededGenerator) {
        for index in openIndices where planner.hasOccasionalFoodRule(on: plans[index].date) {
            let night = planner.nights[index]
            guard let meal = planner.draw(for: night, from: planner.knownMeals, excluding: used, rng: &rng)
                ?? planner.draw(for: night, from: planner.trialMeals, excluding: used, rng: &rng) else { continue }
            fill(index, with: .meal(meal.id), reason: planner.reason(for: meal, on: night))
        }
    }

    /// Busiest = rushed first, then the most people home. Ties skip the first night, the shopping day, when
    /// the fridge is full; then the earliest night.
    mutating func placeTakeout() {
        let needed = planner.inputs.settings.takeoutNights - count { $0 == .quickPick(.takeout) }
        let firstDate = planner.nights.first?.date
        for _ in 0..<max(needed, 0) {
            let busiest = openIndices.min { lhs, rhs in
                let left = planner.nights[lhs], right = planner.nights[rhs]
                return (left.effort == .rushed ? 0 : 1, -left.home.count, left.date == firstDate ? 1 : 0, lhs)
                    < (right.effort == .rushed ? 0 : 1, -right.home.count, right.date == firstDate ? 1 : 0, rhs)
            }
            guard let busiest else { return }
            fill(busiest, with: .quickPick(.takeout), reason: .takeoutOnBusiestNight)
        }
    }

    /// Trial dishes go to full-attendance nights first so everyone gets to react; then nights with the most
    /// time and people.
    mutating func placeNewDishes(rng: inout SeededGenerator) {
        let effortRank: [NightEffort: Int] = [.full: 0, .normal: 1, .rushed: 2, .event: 3]
        let ordered = openIndices.sorted { lhs, rhs in
            let left = planner.nights[lhs], right = planner.nights[rhs]
            return (left.isFullAttendance ? 0 : 1, effortRank[left.effort] ?? 3, -left.home.count, lhs)
                < (right.isFullAttendance ? 0 : 1, effortRank[right.effort] ?? 3, -right.home.count, rhs)
        }
        for index in ordered where trialBudgetLeft > 0 {
            let night = planner.nights[index]
            guard let meal = planner.draw(for: night, from: planner.trialMeals, excluding: used, rng: &rng) else {
                continue
            }
            fill(index, with: .meal(meal.id), reason: .somethingNew)
        }
    }

    /// Leftovers land the night after a big-batch dish: one already in the week, or one drawn now. With no
    /// big batch that fits, it still becomes a leftovers night, on the most rushed night later in the week.
    mutating func placeLeftovers(rng: inout SeededGenerator) {
        let needed = planner.inputs.settings.leftoverNights - count { $0 == .quickPick(.leftovers) }
        for _ in 0..<max(needed, 0) {
            if let after = plans.indices.first(where: { planner.hasTag(.leftovers, plans[$0].pick)
                && isOpenNextNight($0) && !leftoversBreakRule(from: $0) }) {
                fill(after + 1, with: .quickPick(.leftovers), reason: .leftoversAfterBigBatch)
            } else if !placeBigBatchPair(rng: &rng) {
                guard let fallback = openIndices.filter({ !planner.hasOccasionalFoodRule(on: plans[$0].date) }).min(by: { lhs, rhs in
                    (planner.nights[lhs].effort == .rushed ? 0 : 1, lhs == 0 ? 1 : 0, -lhs)
                        < (planner.nights[rhs].effort == .rushed ? 0 : 1, rhs == 0 ? 1 : 0, -rhs)
                }) else { return }
                fill(fallback, with: .quickPick(.leftovers), reason: .leftoversNight)
            }
        }
    }

    /// Prefers a rushed night for the leftovers, since that's when reheating beats cooking. A trial dish can
    /// be the big batch only while the week's new-dish budget has room.
    private mutating func placeBigBatchPair(rng: inout SeededGenerator) -> Bool {
        let pairs = openIndices.filter(isOpenNextNight).sorted { lhs, rhs in
            (planner.nights[lhs + 1].effort == .rushed ? 0 : 1, lhs)
                < (planner.nights[rhs + 1].effort == .rushed ? 0 : 1, rhs)
        }
        let pools = trialBudgetLeft > 0 ? [planner.knownMeals, planner.trialMeals] : [planner.knownMeals]
        for index in pairs {
            for pool in pools {
                let pool = pool.filter { !planner.breaksFoodRule($0, on: plans[index + 1].date) }
                guard let meal = planner.draw(for: planner.nights[index], from: pool, excluding: used,
                                              requiring: .leftovers, rng: &rng) else { continue }
                fill(index, with: .meal(meal.id), reason: .bigBatch)
                fill(index + 1, with: .quickPick(.leftovers), reason: .leftoversAfterBigBatch)
                return true
            }
        }
        return false
    }

    /// Leftovers are the same dish, so the next night's food rule counts for it.
    private func leftoversBreakRule(from index: Int) -> Bool {
        guard let mealID = plans[index].pick?.mealID, let meal = planner.mealsByID[mealID],
              plans.indices.contains(index + 1) else { return false }
        return planner.breaksFoodRule(meal, on: plans[index + 1].date)
    }

    private func isOpenNextNight(_ index: Int) -> Bool {
        let next = index + 1
        return plans.indices.contains(next) && !plans[next].isKept && plans[next].pick == nil
            && plans[next].date.days(since: plans[index].date) == 1
    }

    /// Rushed nights go first: they have the fewest candidates, and filling in date order could spend the
    /// quick dishes on nights that didn't need them. A trial dish fills a night only when nothing else fits.
    mutating func fillTheRest(rng: inout SeededGenerator) {
        let rushedFirst = openIndices.sorted { lhs, rhs in
            (planner.nights[lhs].effort == .rushed ? 0 : 1, lhs) < (planner.nights[rhs].effort == .rushed ? 0 : 1, rhs)
        }
        for index in rushedFirst {
            let night = planner.nights[index]
            let meal = planner.draw(for: night, from: planner.knownMeals, excluding: used, rng: &rng)
                ?? planner.draw(for: night, from: planner.trialMeals, excluding: used, rng: &rng)
            if let meal {
                fill(index, with: .meal(meal.id), reason: planner.reason(for: meal, on: night))
            } else {
                plans[index].reason = .nothingFits
            }
        }
    }

    /// Nothing fits stays as it is: that's what the card has to offer on.
    mutating func sayWhichTraditionsSatOut() {
        for (index, name) in traditionsSatOut where plans[index].pick != nil && !plans[index].isKept {
            plans[index].reason = .traditionSatOut(name: name)
        }
    }
}
