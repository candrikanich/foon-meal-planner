import Foundation

struct Household: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var emoji: String?
    var owner: UUID?

    /// Trimmed name if it fits the database's 1–50 character rule.
    static func validatedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...50).contains(name.count) ? name : nil
    }
}

enum AgeGroup: String, Codable, CaseIterable, Sendable {
    case adult, kid
}

enum MemberRole: String, Codable, CaseIterable, Sendable {
    case planner, member
}

enum MemberStatus: String, Codable, Sendable {
    case active, away, removed
}

struct Member: Decodable, Equatable, Identifiable, Sendable {
    let id: UUID
    let householdID: UUID
    var firstName: String
    var avatar: String?
    var ageGroup: AgeGroup
    var guardian: Bool
    var role: MemberRole
    var status: MemberStatus
    var awayUntil: CalendarDay?
    var userID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, avatar, guardian, role, status
        case householdID = "household_id"
        case firstName = "first_name"
        case ageGroup = "age_group"
        case awayUntil = "away_until"
        case userID = "user_id"
    }
}

/// The editable fields of a member, as the add and edit sheet works with them.
struct MemberDraft: Equatable, Sendable {
    var firstName = ""
    var avatar: String?
    var ageGroup: AgeGroup = .adult
    var guardian = false
    var role: MemberRole = .member
    var status: MemberStatus = .active
    var awayUntil: CalendarDay?

    init() {}

    init(_ member: Member) {
        firstName = member.firstName
        avatar = member.avatar
        ageGroup = member.ageGroup
        guardian = member.guardian
        role = member.role
        status = member.status
        awayUntil = member.awayUntil
    }

    /// Normalized for the database's rules, or nil if the name doesn't fit.
    func validated() -> MemberDraft? {
        let name = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...30).contains(name.count) else { return nil }
        var draft = self
        draft.firstName = name
        draft.avatar = avatar?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        draft.guardian = guardian && ageGroup == .adult
        draft.awayUntil = status == .away ? awayUntil : nil
        return draft
    }
}

extension MemberDraft: Encodable {
    private enum CodingKeys: String, CodingKey {
        case avatar, guardian, role, status
        case firstName = "first_name"
        case ageGroup = "age_group"
        case awayUntil = "away_until"
    }

    // Nulls are written explicitly so clearing an avatar or a return date reaches the database.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(avatar, forKey: .avatar)
        try container.encode(ageGroup, forKey: .ageGroup)
        try container.encode(guardian, forKey: .guardian)
        try container.encode(role, forKey: .role)
        try container.encode(status, forKey: .status)
        try container.encode(awayUntil, forKey: .awayUntil)
    }
}

/// Only the fields an edit changed. Sending just these keeps a stale copy from overwriting another
/// device's edits, and lets someone who may only change their avatar save without tripping the
/// database's checks on fields they never touched. A double optional means "set this to nil".
struct MemberChanges: Equatable, Sendable, Encodable {
    var firstName: String?
    var avatar: String??
    var ageGroup: AgeGroup?
    var guardian: Bool?
    var role: MemberRole?
    var status: MemberStatus?
    var awayUntil: CalendarDay??

    var isEmpty: Bool { self == MemberChanges() }

    private enum CodingKeys: String, CodingKey {
        case avatar, guardian, role, status
        case firstName = "first_name"
        case ageGroup = "age_group"
        case awayUntil = "away_until"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let firstName { try container.encode(firstName, forKey: .firstName) }
        if let avatar { try container.encode(avatar, forKey: .avatar) }
        if let ageGroup { try container.encode(ageGroup, forKey: .ageGroup) }
        if let guardian { try container.encode(guardian, forKey: .guardian) }
        if let role { try container.encode(role, forKey: .role) }
        if let status { try container.encode(status, forKey: .status) }
        if let awayUntil { try container.encode(awayUntil, forKey: .awayUntil) }
    }
}

extension Member {
    func applying(_ changes: MemberChanges) -> Member {
        var member = self
        if let firstName = changes.firstName { member.firstName = firstName }
        if let avatar = changes.avatar { member.avatar = avatar }
        if let ageGroup = changes.ageGroup { member.ageGroup = ageGroup }
        if let guardian = changes.guardian { member.guardian = guardian }
        if let role = changes.role { member.role = role }
        if let status = changes.status { member.status = status }
        if let awayUntil = changes.awayUntil { member.awayUntil = awayUntil }
        return member
    }
}

extension MemberDraft {
    func changes(from member: Member) -> MemberChanges {
        var changes = MemberChanges()
        if firstName != member.firstName { changes.firstName = firstName }
        if avatar != member.avatar { changes.avatar = .some(avatar) }
        if ageGroup != member.ageGroup { changes.ageGroup = ageGroup }
        if guardian != member.guardian { changes.guardian = guardian }
        if role != member.role { changes.role = role }
        if status != member.status { changes.status = status }
        if awayUntil != member.awayUntil { changes.awayUntil = .some(awayUntil) }
        return changes
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
