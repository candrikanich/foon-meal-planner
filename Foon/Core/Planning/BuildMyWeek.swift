import Foundation

/// Build my week (docs/spec.md → Build my week algorithm): a pure `(inputs, seed) -> draft`.
/// The same inputs and seed always give the same draft, on every device, so tests can pin exact results.
///
/// Steps, in order:
/// 1. **Keep** pinned nights and event nights as they are, then land dated requests on their nights.
///    (Standing traditions, #31, will slot in here as another kind of kept night.)
/// 2. **Special slots:** takeout on the busiest nights, new dishes on full-attendance nights, then leftover
///    nights, each after a big-batch meal when one fits. Kept nights count toward each setting.
/// 3. **Fill** the rest in date order with a weighted draw from dishes that pass every filter.
enum BuildMyWeek {
    /// Scoring weights. A dish's weight is
    /// `recency × (1 + favorite × favoritesHome) × (1 + onHand × fractionOnHand) × (1 + like × likes)`.
    enum Weight {
        /// Recency is days since last made, capped: past three months a dish is simply "due", and an uncapped
        /// value would let one long-forgotten dish crowd out everything else.
        static let recencyCapDays = 90
        /// One favorite-er at the table triples the odds, two make it five times: the spec's "big boost",
        /// since cooking what someone home loves is the surest way to a happy table.
        static let favoritePerMemberHome = 2.0
        /// A dish with everything on hand has double the odds (half on hand, 1.5×): less to buy, less waste.
        static let onHand = 1.0
        /// A gentle nudge per thumbs-up, capped, so popular dishes lean ahead without taking over the week.
        static let likePerReaction = 0.1
        static let likeCap = 5
        /// Advance-prep steps at least this long (thawing overnight) can't be done for the first night.
        static let advancePrepLeadHours = 12
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

    /// Re-rolls one night, leaving every other night exactly as it is. Never repeats a meal used elsewhere
    /// in the week, and avoids the current pick so the night actually changes. Kept nights don't move, and a
    /// night with no alternative stays as it was.
    static func shuffle(night nightID: UUID, in draft: [NightPlan], inputs: PlanningInputs,
                        seed: UInt64) -> [NightPlan] {
        let planner = Planner(inputs)
        guard let index = draft.firstIndex(where: { $0.nightID == nightID }), !draft[index].isKept,
              let night = planner.nights.first(where: { $0.id == nightID }), !planner.isKept(night)
        else { return draft }
        let used = Set(draft.compactMap(\.pick?.mealID))
        var rng = SeededGenerator(seed: seed)
        // A new-dish slot stays a new-dish slot, so a shuffle doesn't quietly change the week's mix.
        let pools = draft[index].reason == .somethingNew
            ? [planner.newMeals, planner.knownMeals] : [planner.knownMeals, planner.newMeals]
        for pool in pools {
            if let meal = planner.draw(for: night, from: pool, excluding: used, rng: &rng) {
                var result = draft
                result[index].pick = .meal(meal.id)
                result[index].reason = planner.reason(for: meal, on: night)
                return result
            }
        }
        return draft
    }
}

// MARK: - Lookups and rules

private struct Planner {
    let inputs: PlanningInputs
    /// In date order; the draft comes back in this order.
    let nights: [PlanningNight]
    let historyByMeal: [UUID: MealHistory]
    let mealsByID: [UUID: LibraryMeal]
    /// Dishes the family knows: in rotation, made before, out of trial.
    let knownMeals: [LibraryMeal]
    /// Trials and dishes never made. Kept apart so "new dishes per week" means what it says.
    let newMeals: [LibraryMeal]

    init(_ inputs: PlanningInputs) {
        self.inputs = inputs
        nights = inputs.nights.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        let history = Dictionary(inputs.history.map { ($0.mealID, $0) }, uniquingKeysWith: { first, _ in first })
        historyByMeal = history
        mealsByID = Dictionary(inputs.meals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rotation = inputs.meals.filter(\.status.isInRotation)
        let isNew: (LibraryMeal) -> Bool = { $0.status == .trial || history[$0.id] == nil }
        knownMeals = rotation.filter { !isNew($0) }
        newMeals = rotation.filter(isNew)
    }

    var firstDate: CalendarDay? { nights.first?.date }

    func isKept(_ night: PlanningNight) -> Bool { night.locked || night.effort == .event }

    func isNew(_ mealID: UUID) -> Bool { newMeals.contains { $0.id == mealID } }

    func hasTag(_ tag: MealTag, _ pick: NightPick?) -> Bool {
        pick?.mealID.flatMap { mealsByID[$0] }?.tags.contains(tag) ?? false
    }

    func name(of memberID: UUID) -> String? { inputs.memberNames[memberID] }

    // MARK: Filters

    /// Step 3 of the spec. Allergies are never a filter: they're flagged on the card, and the planner decides.
    func fits(_ meal: LibraryMeal, on night: PlanningNight) -> Bool {
        guard meal.status.isInRotation, !inputs.snoozedMealIDs.contains(meal.id) else { return false }
        if let lastMade = historyByMeal[meal.id]?.lastMade,
           night.date.days(since: lastMade) < inputs.settings.repeatWindowDays { return false }
        let notForMe = inputs.notForMe[meal.id] ?? [:]
        if night.home.contains(where: { (notForMe[$0] ?? 0) >= 1 }) { return false }
        if night.effort == .rushed, !meal.tags.contains(.quick) { return false }
        // The first night is the shopping day: there's no time to thaw or marinate what was just bought.
        // Grill dishes fit any night until a setting says otherwise.
        if night.date == firstDate, needsAdvancePrep(meal) { return false }
        return true
    }

    private func needsAdvancePrep(_ meal: LibraryMeal) -> Bool {
        meal.tags.contains(.thawFirst)
            || meal.prepSteps.contains { ($0.leadHours ?? 0) >= BuildMyWeek.Weight.advancePrepLeadHours }
    }

    // MARK: Scoring

    func weight(of meal: LibraryMeal, on night: PlanningNight) -> Double {
        let recency = Double(min(max(daysSinceMade(meal) ?? .max, 1), BuildMyWeek.Weight.recencyCapDays))
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
        if isNew(meal.id) { return .somethingNew }
        let favoriters = favoritersHome(meal, on: night)
        if !favoriters.isEmpty {
            let names = favoriters.compactMap(name(of:)).sorted()
            return .favorite(name: names.first)
        }
        if night.effort == .rushed { return .quickForRushedNight }
        if fractionOnHand(meal) >= 0.5 { return .usesWhatsOnHand }
        let days = daysSinceMade(meal) ?? 0
        if days < 14, (inputs.likes[meal.id] ?? 0) >= 3 { return .familyLikesIt }
        return .notHadIn(days: days)
    }

    /// Measured from the start of the week, so a dish scores the same on every night of it.
    private func daysSinceMade(_ meal: LibraryMeal) -> Int? {
        historyByMeal[meal.id].map { (firstDate ?? $0.lastMade).days(since: $0.lastMade) }
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

    private mutating func fill(_ index: Int, with pick: NightPick, reason: PlanReason, kept: Bool = false) {
        plans[index].pick = pick
        plans[index].reason = reason
        plans[index].isKept = kept
        if let mealID = pick.mealID { used.insert(mealID) }
    }

    /// A request is the family asking out loud, so it skips the filters; it still needs a dish in rotation
    /// and an open night, and never doubles a dish already in the week. First request for a night wins.
    mutating func landRequests() {
        for request in planner.inputs.requests {
            guard let meal = planner.mealsByID[request.mealID], meal.status.isInRotation, !used.contains(meal.id),
                  let index = openIndices.first(where: { plans[$0].date == request.date }) else { continue }
            fill(index, with: .meal(meal.id), reason: .request(name: planner.name(of: request.requesterID)),
                 kept: true)
        }
    }

    /// Busiest = rushed first, then the most people home, then the earliest night.
    mutating func placeTakeout() {
        let needed = planner.inputs.settings.takeoutNights - count { $0 == .quickPick(.takeout) }
        for _ in 0..<max(needed, 0) {
            let busiest = openIndices.min { lhs, rhs in
                let left = planner.nights[lhs], right = planner.nights[rhs]
                return (left.effort == .rushed ? 0 : 1, -left.home.count, lhs)
                    < (right.effort == .rushed ? 0 : 1, -right.home.count, rhs)
            }
            guard let busiest else { return }
            fill(busiest, with: .quickPick(.takeout), reason: .takeoutOnBusiestNight)
        }
    }

    /// Full-attendance nights first so everyone gets to react; then nights with the most time and people.
    mutating func placeNewDishes(rng: inout SeededGenerator) {
        var needed = planner.inputs.settings.newDishesPerWeek - count { $0.mealID.map(planner.isNew) ?? false }
        let effortRank: [NightEffort: Int] = [.full: 0, .normal: 1, .rushed: 2, .event: 3]
        let ordered = openIndices.sorted { lhs, rhs in
            let left = planner.nights[lhs], right = planner.nights[rhs]
            return (left.isFullAttendance ? 0 : 1, effortRank[left.effort] ?? 3, -left.home.count, lhs)
                < (right.isFullAttendance ? 0 : 1, effortRank[right.effort] ?? 3, -right.home.count, rhs)
        }
        for index in ordered where needed > 0 {
            let night = planner.nights[index]
            guard let meal = planner.draw(for: night, from: planner.newMeals, excluding: used, rng: &rng) else {
                continue
            }
            fill(index, with: .meal(meal.id), reason: .somethingNew)
            needed -= 1
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

    /// Prefers a rushed night for the leftovers, since that's when reheating beats cooking.
    private mutating func placeBigBatchPair(rng: inout SeededGenerator) -> Bool {
        let open = Set(openIndices)
        let pairs = open.filter(isOpenNextNight).sorted { lhs, rhs in
            (planner.nights[lhs + 1].effort == .rushed ? 0 : 1, lhs)
                < (planner.nights[rhs + 1].effort == .rushed ? 0 : 1, rhs)
        }
        for index in pairs {
            let night = planner.nights[index]
            for pool in [planner.knownMeals, planner.newMeals] {
                guard let meal = planner.draw(for: night, from: pool, excluding: used, requiring: .leftovers,
                                              rng: &rng) else { continue }
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
    /// quick dishes on nights that didn't need them. Known dishes first; new ones only when nothing familiar
    /// fits, so a fresh library still fills the week.
    mutating func fillTheRest(rng: inout SeededGenerator) {
        let rushedFirst = openIndices.sorted { lhs, rhs in
            (planner.nights[lhs].effort == .rushed ? 0 : 1, lhs) < (planner.nights[rhs].effort == .rushed ? 0 : 1, rhs)
        }
        for index in rushedFirst {
            let night = planner.nights[index]
            let meal = planner.draw(for: night, from: planner.knownMeals, excluding: used, rng: &rng)
                ?? planner.draw(for: night, from: planner.newMeals, excluding: used, rng: &rng)
            if let meal {
                fill(index, with: .meal(meal.id), reason: planner.reason(for: meal, on: night))
            } else {
                plans[index].reason = .nothingFits
            }
        }
    }
}
