import Foundation

/// A delete that changed nothing: row-level security refuses it silently for someone who's no longer a parent, and it
/// looks the same when another device already deleted it.
enum AttendanceTemplateError: Error, Equatable {
    case notDeleted
}

/// Everyone's usual schedule saved under a name ("School year", "Baseball season"), from `attendance_templates`.
struct AttendanceTemplate: Decodable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var schedules: [UUID: AttendanceDefaults]

    private enum CodingKeys: String, CodingKey {
        case id, name, schedules
    }

    init(id: UUID, name: String, schedules: [UUID: AttendanceDefaults]) {
        (self.id, self.name, self.schedules) = (id, name, schedules)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let raw = try container.decode([String: AttendanceDefaults].self, forKey: .schedules)
        schedules = Dictionary(raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                               uniquingKeysWith: { first, _ in first })
    }

    /// Trimmed if it fits the database's 1 to 40 characters.
    static func validatedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...40).contains(name.unicodeScalars.count) ? name : nil
    }

    /// The saved schedule a name would replace, whatever the capitals (the database's rule).
    static func existing(named raw: String, in templates: [AttendanceTemplate]) -> AttendanceTemplate? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return templates.first { $0.name.lowercased() == name }
    }

    /// Switching to it would change nothing. Someone added since it was saved keeps their own schedule either way.
    func isInUse(by members: [Member]) -> Bool {
        let covered = members.filter { $0.status != .removed && schedules[$0.id] != nil }
        return !covered.isEmpty && covered.allSatisfy { schedules[$0.id]?.usuallyAway == $0.usuallyAway }
    }

    /// "Owen out Mon, Tue · Grace out Fri", in family order.
    func summary(members: [Member]) -> String {
        let out = members.compactMap { member -> String? in
            guard member.status != .removed, let away = schedules[member.id]?.usuallyAway, !away.isEmpty else { return nil }
            let days = WeekMath.weekdays.filter { away.contains($0.iso) }.map { $0.shortName() }.joined(separator: ", ")
            return String(localized: "\(member.firstName) out \(days)", comment: "Saved schedule: a name, then weekdays")
        }
        return out.isEmpty ? String(localized: "Everyone home every night") : out.joined(separator: " · ")
    }
}
