import Foundation

// Foundation only: the after-dinner card (FoonDinner) reads the payload and identifiers too.

/// Where tapping a notification goes.
enum ReminderRoute: Equatable, Sendable {
    /// This Week, on the week that holds this day.
    case week(CalendarDay)
    case night(UUID, CalendarDay)
    case swap(UUID, CalendarDay)
    /// This Week's after-dinner cards. What a prompt scheduled before #122 carries.
    case dinnerCard
    /// This Week's after-dinner card for this person's night. The notification's reactions and Wasn't home answer it.
    case rate(night: UUID, member: UUID)
    /// This Week's check-in card. The lock screen's Home and Not home answer for this person on this night.
    case checkIn(night: UUID, member: UUID)
    /// The Lists tab: a server push about something added for tonight.
    case lists
    /// The Ideas tab: the server's digest of new dinner ideas.
    case ideas
    /// This Week's roundup of the week's dinners still to rate, for the week that starts that day.
    case roundup(CalendarDay)
}

/// What a notification carries so it can be answered with the app closed. Routes and times, and no more than that.
struct ReminderPayload: Equatable, Sendable {
    var route: ReminderRoute
    var dinnerAt: Date?

    init(route: ReminderRoute, dinnerAt: Date?) {
        self.route = route
        self.dinnerAt = dinnerAt
    }

    var userInfo: [String: String] {
        var info: [String: String] = [:]
        switch route {
        case .week(let day):
            info["route"] = "week"
            info["date"] = day.isoString
        case .night(let night, let day), .swap(let night, let day):
            info["route"] = "night"
            info["night"] = night.uuidString
            info["date"] = day.isoString
        case .dinnerCard:
            info["route"] = "dinner"
        case .rate(let night, let member):
            info["route"] = "rate"
            info["night"] = night.uuidString
            info["member"] = member.uuidString
        case .checkIn(let night, let member):
            info["route"] = "checkin"
            info["night"] = night.uuidString
            info["member"] = member.uuidString
        case .lists:
            info["route"] = "list"
        case .ideas:
            info["route"] = "ideas"
        case .roundup(let week):
            info["route"] = "roundup"
            info["date"] = week.isoString
        }
        if let dinnerAt { info["dinner"] = String(dinnerAt.timeIntervalSince1970) }
        return info
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo["route"] as? String else { return nil }
        let day = (userInfo["date"] as? String).flatMap { text -> CalendarDay? in
            let parts = text.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? CalendarDay(year: parts[0], month: parts[1], day: parts[2]) : nil
        }
        switch kind {
        case "week":
            guard let day else { return nil }
            route = .week(day)
        case "night":
            guard let day, let night = (userInfo["night"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            route = .night(night, day)
        case "dinner":
            route = .dinnerCard
        case "list":
            route = .lists
        case "ideas":
            route = .ideas
        case "roundup":
            guard let day else { return nil }
            route = .roundup(day)
        case "checkin", "rate":
            guard let night = (userInfo["night"] as? String).flatMap(UUID.init(uuidString:)),
                  let member = (userInfo["member"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            route = kind == "rate" ? .rate(night: night, member: member) : .checkIn(night: night, member: member)
        default:
            return nil
        }
        dinnerAt = (userInfo["dinner"] as? String).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }
}

/// Identifiers, all under one prefix so nothing here ever touches a cook-mode timer's (a bare UUID). What each kind's looks
/// like is in ReminderModels.
enum ReminderID {
    static let prefix = "foon.reminder."
    private static let followUpSuffix = ".again"

    static func followUp(of id: String) -> String { id + followUpSuffix }

    /// The reminder a follow-up follows.
    static func base(of id: String) -> String {
        id.hasSuffix(followUpSuffix) ? String(id.dropLast(followUpSuffix.count)) : id
    }

    static func isReminder(_ id: String) -> Bool { id.hasPrefix(prefix) }
}
