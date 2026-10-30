import Foundation
import Supabase

/// One dinner cooked ahead, from `freezer_stash`. Always a library dish, so its allergy flags and sides come with it.
struct FreezerItem: Identifiable, Equatable, Sendable, Decodable {
    enum State: String, Sendable {
        /// In the freezer, ready to offer.
        case `in`
        /// Eaten, or planned on a night (`plannedOn`).
        case used
        /// Tossed. Nothing's deleted; it's just no longer there.
        case archived
    }

    let id: UUID
    let mealID: UUID
    let mealName: String
    let madeOn: CalendarDay
    let state: State
    /// The night it's planned on, while one holds it.
    let plannedOn: CalendarDay?

    init(id: UUID, mealID: UUID, mealName: String, madeOn: CalendarDay, state: State, plannedOn: CalendarDay? = nil) {
        (self.id, self.mealID, self.mealName, self.madeOn, self.state, self.plannedOn) = (id, mealID, mealName, madeOn, state, plannedOn)
    }

    private struct MealName: Decodable { let name: String }
    private struct Night: Decodable { let date: CalendarDay }

    private enum CodingKeys: String, CodingKey {
        case id, state, meals
        case mealID = "meal_id"
        case madeOn = "made_on"
        case planNights = "plan_nights"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mealID = try container.decode(UUID.self, forKey: .mealID)
        madeOn = try container.decode(CalendarDay.self, forKey: .madeOn)
        mealName = try container.decode(MealName.self, forKey: .meals).name
        // A state from a newer app reads as gone: never offered, and the list still loads.
        state = State(rawValue: try container.decode(String.self, forKey: .state)) ?? .archived
        plannedOn = try container.decodeIfPresent([Night].self, forKey: .planNights)?.first?.date
    }
}

/// Reads and writes the freezer. The table takes no direct writes; every change goes through a function that locks the
/// item, so a phone with an old copy can't overwrite another's.
struct FreezerClient: Sendable {
    var items: @Sendable (_ householdID: UUID) async throws -> [FreezerItem]
    var add: @Sendable (_ householdID: UUID, _ mealID: UUID, _ madeOn: CalendarDay) async throws -> Void
    var setState: @Sendable (_ itemID: UUID, _ state: FreezerItem.State) async throws -> Void
}

extension FreezerClient {
    static func live(_ client: SupabaseClient) -> FreezerClient {
        FreezerClient(
            items: { householdID in
                try await client.from("freezer_stash")
                    .select("id, meal_id, made_on, state, meals(name), plan_nights(date)")
                    .eq("household_id", value: householdID)
                    .order("made_on")
                    .execute()
                    .value
            },
            add: { householdID, mealID, madeOn in
                try await client.rpc("add_to_freezer", params: [
                    "target_household": householdID.uuidString, "target_meal": mealID.uuidString,
                    "made": madeOn.isoString
                ]).execute()
            },
            setState: { itemID, state in
                try await client.rpc("set_freezer_item", params: [
                    "target_item": itemID.uuidString, "new_state": state.rawValue
                ]).execute()
            }
        )
    }
}

/// What's offered and what's said about the stash, kept pure. The swap sheet reads `offers` today; the tonight poll (#43)
/// reads the same function for tonight, so what it offers will be what Swap offers.
enum FreezerStash {
    /// An item that can go on a night, with the flags to show. Allergies are never a filter: they're flagged, and the
    /// planner decides.
    struct Offer: Equatable, Sendable {
        let item: FreezerItem
        let meal: LibraryMeal
        let flags: [AllergyFlag]
    }

    /// Oldest first, so nothing gets forgotten at the back. Offered: items still in the freezer, made by that night, of a
    /// dish in rotation and not already in the week. Someone home saying "not for me", or a snooze, skips it, as in Build
    /// my week; a past night is logging what was eaten, so they don't apply there. The repeat window, prep time, rushed
    /// nights and missing equipment don't apply either: it's already cooked.
    static func offers(_ items: [FreezerItem], on night: WeekNight, week: [WeekNight], library: [LibraryMeal],
                       notForMe: [UUID: [UUID: Int]], snoozed: Set<UUID>, allergies: [MemberAllergies],
                       today: CalendarDay) -> [Offer] {
        let meals = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let planned = Set(week.compactMap(\.mealID))
        let home = Set(night.attendance.filter(\.value).keys)
        let logging = night.date < today
        let athome = allergies.filter { home.contains($0.memberID) }
        return items
            .filter { $0.state == .in && $0.madeOn <= night.date && !planned.contains($0.mealID) }
            .sorted { ($0.madeOn, $0.id.uuidString) < ($1.madeOn, $1.id.uuidString) }
            .compactMap { item -> Offer? in
                guard let meal = meals[item.mealID], meal.status.isInRotation else { return nil }
                if !logging {
                    let dislikes = notForMe[meal.id] ?? [:]
                    if snoozed.contains(meal.id) || home.contains(where: { (dislikes[$0] ?? 0) >= 1 }) { return nil }
                }
                let flags = AllergyMatcher.flags(ingredients: ShoppingLines.lines(for: meal, library: library).map(\.name),
                                                 members: athome)
                return Offer(item: item, meal: meal, flags: flags)
            }
    }

    /// "Made Oct 3 · 3 weeks ago". A date ahead of today (a phone whose clock disagrees) gets no age rather than a wrong one.
    static func madeText(_ day: CalendarDay, today: CalendarDay, calendar: Calendar = .current) -> String {
        let date = DayCardText.dateLabel(for: day, calendar: calendar, relativeTo: today)
        guard let age = age(of: day, today: today) else {
            return String(localized: "Made \(date)", comment: "Freezer stash: the date a dish was made")
        }
        return String(localized: "Made \(date) · \(age)", comment: "Freezer stash: the date a dish was made, and how long ago")
    }

    /// The chip on a night planned from the stash.
    static func reason(madeOn: CalendarDay, today: CalendarDay, calendar: Calendar = .current) -> String {
        String(localized: "From the freezer, made \(DayCardText.dateLabel(for: madeOn, calendar: calendar, relativeTo: today))",
               comment: "Reason chip: a dish already cooked and frozen, and the date it was made")
    }

    /// Without the dish there's nothing to check allergies against, and no flag mustn't read as safe.
    static func allergyUnknownNote(for meal: LibraryMeal?, isLoading: Bool) -> String? {
        guard meal == nil, !isLoading else { return nil }
        return String(localized: "Couldn't check this one for allergies. Pull down to try again.")
    }

    /// Why an item on the list isn't being offered, when the dish is the reason.
    static func notOfferedNote(for meal: LibraryMeal?) -> String? {
        switch meal?.status {
        case .retired: String(localized: "The family voted this dish out, so Foon won't offer it.")
        case .archived: String(localized: "This dish is archived, so Foon won't offer it.")
        default: nil
        }
    }

    private static func age(of day: CalendarDay, today: CalendarDay) -> String? {
        let days = today.days(since: day)
        return switch days {
        case ..<0: nil
        case 0: String(localized: "today", comment: "Freezer stash: made today")
        case 1: String(localized: "yesterday", comment: "Freezer stash: made yesterday")
        case 2..<14: String(localized: "\(days) days ago", comment: "Freezer stash: how long ago")
        case 14..<60: String(localized: "\(days / 7) weeks ago", comment: "Freezer stash: how long ago")
        default: String(localized: "\(days / 30) months ago", comment: "Freezer stash: how long ago")
        }
    }
}
