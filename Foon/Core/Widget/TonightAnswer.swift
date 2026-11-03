import Foundation

/// Siri's answer to "What's for dinner?" (#62): tonight from the widget's snapshot, so it needs no network.
enum TonightAnswer {
    static func text(_ snapshot: TonightSnapshot?, now: Date) -> String {
        guard let snapshot else { return String(localized: "Open Foon to see the plan.") }
        let night = snapshot.night(on: CalendarDay(now, calendar: snapshot.calendar))
        if night?.isAway == true {
            return String(localized: "You're away tonight.", comment: "Siri: the household's away dates cover tonight")
        }
        guard let night, let title = night.title else {
            return String(localized: "Nothing's planned for tonight yet.", comment: "Siri: tonight has no dinner")
        }
        if let time = night.dinnerTimeText {
            return String(localized: "Tonight: \(title), at \(time).", comment: "Siri: tonight's dinner and its time")
        }
        return String(localized: "Tonight: \(title).", comment: "Siri: tonight's dinner")
    }
}
