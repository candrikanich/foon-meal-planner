import Foundation

extension MemberDraft {
    /// Once their return date has come they're home, so that's what the editor starts from, by the household's day.
    /// Away with no date stays away until someone says otherwise.
    func settlingReturn(today: CalendarDay) -> MemberDraft {
        guard status == .away, let awayUntil, awayUntil <= today else { return self }
        var settled = self
        settled.status = .active
        settled.awayUntil = nil
        return settled
    }
}

/// How a member reads on Family and on their profile.
extension Member {
    /// Their return date is their first night home (`member_usually_home`), so from that day on they're home, whether or
    /// not anyone has changed the status. `today` is the household's day.
    func isAway(today: CalendarDay) -> Bool {
        guard status == .away else { return false }
        return awayUntil.map { $0 > today } ?? true
    }

    var ageTitle: String {
        ageGroup == .adult ? String(localized: "Adult") : String(localized: "Kid")
    }

    var roleTitle: String {
        role == .planner ? String(localized: "Planner") : String(localized: "Member")
    }

    func statusTitle(today: CalendarDay) -> String {
        guard isAway(today: today) else { return String(localized: "Home") }
        guard let day = awayUntil else { return String(localized: "Away") }
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
