import Foundation

extension TonightSnapshot.Night {
    /// A night as This Week shows it: away first, then the dish, then the quick pick, else nothing planned.
    init(_ night: WeekNight, awayDates: [AwayDates]) {
        if awayDates.contains(where: { $0.contains(night.date) }) {
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
        let nights = week.nights.map { TonightSnapshot.Night($0, awayDates: settings.awayDates) }
        let base = current ?? TonightSnapshot(householdID: householdID, timeZone: calendar.timeZone.identifier, nights: [])
        return base.merging(nights, householdID: householdID, timeZone: calendar.timeZone.identifier,
                            today: CalendarDay(now, calendar: calendar))
    }
}
