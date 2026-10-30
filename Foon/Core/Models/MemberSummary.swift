import Foundation

/// How a member reads on Family and on their profile.
extension Member {
    var ageTitle: String {
        ageGroup == .adult ? String(localized: "Adult") : String(localized: "Kid")
    }

    var roleTitle: String {
        role == .planner ? String(localized: "Planner") : String(localized: "Member")
    }

    /// Their return date is their first night home (`member_usually_home`), so from that day on they're Home, whether or
    /// not anyone has changed the status. `today` is the household's day.
    func statusTitle(today: CalendarDay) -> String {
        guard status == .away else { return String(localized: "Home") }
        guard let day = awayUntil else { return String(localized: "Away") }
        guard day > today else { return String(localized: "Home") }
        let date = day.date().formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "Away until \(date)", comment: "Member status: a short date such as Nov 4")
    }

    /// "Home every night", or the nights they're usually out.
    var scheduleTitle: String {
        let out = WeekMath.weekdays.filter { usuallyAway.contains($0.iso) }
        if out.isEmpty { return String(localized: "Home every night", comment: "A member's usual schedule") }
        if out.count == WeekMath.weekdays.count { return String(localized: "Out every night", comment: "A member's usual schedule") }
        let days = out.map { $0.shortName() }.joined(separator: ", ")
        return String(localized: "Out \(days)", comment: "A member's usual schedule: short weekday names")
    }
}

extension MemberAllergies {
    /// The standard allergens in their usual order, then what a parent typed.
    var displayNames: [String] {
        Allergen.allCases.filter(allergens.contains).map(\.displayName.localizedCapitalized) + customTexts
    }
}
