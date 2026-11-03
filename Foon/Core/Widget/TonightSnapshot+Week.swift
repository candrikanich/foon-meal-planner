import Foundation

extension TonightSnapshot.Night {
    /// A night as This Week shows it: away first (by This Week's rule, so a dinner tonight or earlier stays itself), then
    /// the dish, then the quick pick, else nothing planned.
    init(_ night: WeekNight, awayDates: [AwayDates], today: CalendarDay) {
        if night.readsAway(in: awayDates, today: today) {
            self.init(date: night.date, isAway: true)
        } else if let name = night.mealName {
            self.init(date: night.date, title: name, isDish: true, dinnerTime: night.dinnerTime)
        } else if let pick = night.quickPick {
            self.init(date: night.date, title: DayCardText.quickPickLabel(pick), dinnerTime: night.dinnerTime)
        } else {
            self.init(date: night.date, dinnerTime: night.dinnerTime)
        }
    }
}

extension TonightSnapshot {
    /// The snapshot after This Week shows `week`: its nights replace theirs, keeping the other week this phone saw.
    static func updated(_ current: TonightSnapshot?, week: Week, householdID: UUID, settings: HouseholdSettings,
                        now: Date) -> TonightSnapshot {
        let calendar = settings.dayCalendar
        let today = CalendarDay(now, calendar: calendar)
        let nights = week.nights.map { TonightSnapshot.Night($0, awayDates: settings.awayDates, today: today) }
        let base = current ?? TonightSnapshot(householdID: householdID, timeZone: calendar.timeZone.identifier, nights: [])
        return base.merging(nights, householdID: householdID, timeZone: calendar.timeZone.identifier, today: today)
    }
}
