import Foundation

/// Build my week (docs/spec.md → Build my week algorithm): a pure `(inputs, seed) -> draft`.
/// The same inputs and seed always give the same draft, on every device and whatever order the library
/// arrives in, so tests can pin exact results.
///
/// Steps, in order:
/// 1. **Keep** pinned nights, event nights, and nights before `today` as they are, then land dated requests
///    on their nights. (Standing traditions, #31, will slot in here as another kind of kept night.)
/// 2. **Special slots:** takeout on the busiest nights, trial dishes on full-attendance nights, then leftover
///    nights, each after a big-batch meal when one fits. Kept nights, past ones too, count toward each setting.
/// 3. **Fill** the rest, rushed nights first and then in date order, with a weighted draw from dishes that
///    pass every filter.
enum BuildMyWeek {
    /// Scoring weights. A dish's weight is
    /// `recency × (1 + favorite × favoritesHome) × (1 + onHand × fractionOnHand) × (1 + like × likes)`.
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
        state.placeTakeout()
        state.placeNewDishes(rng: &rng)
        state.placeLeftovers(rng: &rng)
        state.fillTheRest(rng: &rng)
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
        guard !planner.isKept(night), !planner.isRequested(night), night.quickPick == nil else { return nil }
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
        var rng = SeededGenerator(seed: seed)
        for pool in pools {
            guard let meal = planner.draw(for: night, from: pool, excluding: used,
                                          requiring: feedsLeftovers ? .leftovers : nil, rng: &rng) else { continue }
            return NightPlan(nightID: night.id, date: night.date, pick: .meal(meal.id),
                             reason: feedsLeftovers ? .bigBatch : planner.reason(for: meal, on: night), isKept: false)
        }
        return nil
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

    init(_ inputs: PlanningInputs) {
        self.inputs = inputs
        nights = inputs.nights.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        historyByMeal = Dictionary(inputs.history.map { ($0.mealID, $0) }, uniquingKeysWith: { first, _ in first })
        mealsByID = Dictionary(inputs.meals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A fixed order, so the same seed draws the same dish however the library was loaded.
        let rotation = inputs.meals.filter(\.status.isInRotation).sorted { $0.id.uuidString < $1.id.uuidString }
        knownMeals = rotation.filter { $0.status != .trial }
        trialMeals = rotation.filter { $0.status == .trial }
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

    /// Step 3 of the spec. Allergies are never a filter: they're flagged on the card, and the planner decides.
    /// Grill dishes fit any night until a setting says otherwise.
    func fits(_ meal: LibraryMeal, on night: PlanningNight) -> Bool {
        guard meal.status.isInRotation, !inputs.snoozedMealIDs.contains(meal.id) else { return false }
        if let lastMade = historyByMeal[meal.id]?.lastMade,
           night.date.days(since: lastMade) < inputs.settings.repeatWindowDays { return false }
        let notForMe = inputs.notForMe[meal.id] ?? [:]
        if night.home.contains(where: { (notForMe[$0] ?? 0) >= 1 }) { return false }
        if night.effort == .rushed, !meal.tags.contains(.quick) { return false }
        return hoursUntilDinner(on: night) >= leadHours(meal)
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
    }

    /// A weighted draw among the pool's dishes that fit this night and aren't already in the week.
    func draw(for night: PlanningNight, from pool: [LibraryMeal], excluding used: Set<UUID>,
              requiring tag: MealTag? = nil, rng: inout SeededGenerator) -> LibraryMeal? {
        let candidates = pool.filter { meal in
            !used.contains(meal.id) && fits(meal, on: night) && (tag.map { meal.tags.contains($0) } ?? true)
        }
        let weights = candidates.map { weight(of: $0, on: night) }
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

    init(planner: Planner) {
        self.planner = planner
        plans = planner.nights.map { night in
            let kept = planner.isKept(night)
            let pick: NightPick? = night.mealID.map(NightPick.meal) ?? night.quickPick.map(NightPick.quickPick)
            return NightPlan(nightID: night.id, date: night.date, pick: kept ? pick : nil, reason: nil, isKept: kept)
        }
        used = Set(plans.compactMap(\.pick?.mealID))
    }

    private var openIndices: [Int] { plans.indices.filter { !plans[$0].isKept && plans[$0].pick == nil } }

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
    /// in the week. First request for a night wins.
    mutating func landRequests() {
        for request in planner.inputs.requests {
            guard let meal = planner.mealsByID[request.mealID], meal.status.isInRotation, !used.contains(meal.id),
                  let index = openIndices.first(where: { plans[$0].date == request.date }) else { continue }
            fill(index, with: .meal(meal.id), reason: .request(name: planner.name(of: request.requesterID)),
                 kept: true)
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
                && isOpenNextNight($0) }) {
                fill(after + 1, with: .quickPick(.leftovers), reason: .leftoversAfterBigBatch)
            } else if !placeBigBatchPair(rng: &rng) {
                guard let fallback = openIndices.min(by: { lhs, rhs in
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
                guard let meal = planner.draw(for: planner.nights[index], from: pool, excluding: used,
                                              requiring: .leftovers, rng: &rng) else { continue }
                fill(index, with: .meal(meal.id), reason: .bigBatch)
                fill(index + 1, with: .quickPick(.leftovers), reason: .leftoversAfterBigBatch)
                return true
            }
        }
        return false
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
}
