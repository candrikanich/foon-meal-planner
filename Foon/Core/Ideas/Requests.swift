import Foundation
import Supabase

/// Mirrors Postgres `request_status`. "Someday" and "Tried" are worked out from dates (see `RequestBoard`).
enum RequestStatus: String, Codable, Sendable {
    case open, planned, special, archived
}

/// One idea: a library dish, a typed name, or a link, from someone in the family.
struct DinnerRequest: Identifiable, Equatable, Sendable, Decodable {
    let id: UUID
    let requestedByMemberID: UUID
    let mealID: UUID?
    let title: String?
    let link: URL?
    let note: String?
    let targetDate: CalendarDay?
    let status: RequestStatus
    let plannedNightID: UUID?
    /// The planned night's date, when it's planned.
    let plannedDate: CalendarDay?
    let createdAt: Date
    /// Who said me too.
    let plusOnes: [UUID]

    init(id: UUID = UUID(), requestedByMemberID: UUID, mealID: UUID? = nil, title: String? = nil, link: URL? = nil,
         note: String? = nil, targetDate: CalendarDay? = nil, status: RequestStatus = .open, plannedNightID: UUID? = nil,
         plannedDate: CalendarDay? = nil, createdAt: Date = .now, plusOnes: [UUID] = []) {
        (self.id, self.requestedByMemberID, self.mealID, self.title, self.link) = (id, requestedByMemberID, mealID, title, link)
        (self.note, self.targetDate, self.status, self.plannedNightID) = (note, targetDate, status, plannedNightID)
        self.plannedDate = plannedDate
        (self.createdAt, self.plusOnes) = (createdAt, plusOnes)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, link, note, status
        case requestedByMemberID = "requested_by_member_id"
        case mealID = "meal_id"
        case targetDate = "target_date"
        case plannedNightID = "planned_night_id"
        case createdAt = "created_at"
        case plusOnes = "request_plus_ones"
        case plannedNight = "plan_nights"
    }

    private struct Night: Decodable { let date: CalendarDay }

    private struct PlusOne: Decodable {
        let memberID: UUID
        private enum CodingKeys: String, CodingKey { case memberID = "member_id" }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        requestedByMemberID = try container.decode(UUID.self, forKey: .requestedByMemberID)
        mealID = try container.decodeIfPresent(UUID.self, forKey: .mealID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        link = try container.decodeIfPresent(String.self, forKey: .link).flatMap(URL.init(string:))
        note = try container.decodeIfPresent(String.self, forKey: .note)
        targetDate = try container.decodeIfPresent(CalendarDay.self, forKey: .targetDate)
        status = try container.decode(RequestStatus.self, forKey: .status)
        plannedNightID = try container.decodeIfPresent(UUID.self, forKey: .plannedNightID)
        plannedDate = try container.decodeIfPresent(Night.self, forKey: .plannedNight)?.date
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        plusOnes = try container.decodeIfPresent([PlusOne].self, forKey: .plusOnes)?.map(\.memberID) ?? []
    }
}

/// What "I want..." sends.
struct NewRequest: Equatable, Sendable {
    var from: UUID
    var mealID: UUID?
    var title: String?
    var link: String?
    var note: String?
    var date: CalendarDay?
}

/// A planner's (or the requester's) next step for a request; nil fields stay as they are.
struct RequestUpdate: Equatable, Sendable {
    var status: RequestStatus?
    var nightID: UUID?
    /// Not this week: back to Someday.
    var clearDate = false
    var linkMealID: UUID?
    var note: String?
    var date: CalendarDay?
}

/// Requests and me-toos, as closures so tests and previews can swap them out.
struct IdeasClient: Sendable {
    var requests: @Sendable (_ householdID: UUID) async throws -> [DinnerRequest]
    var make: @Sendable (_ householdID: UUID, _ request: NewRequest) async throws -> UUID
    /// Returns whether the me-too is on now.
    var toggleMeToo: @Sendable (_ requestID: UUID, _ memberID: UUID) async throws -> Bool
    var update: @Sendable (_ requestID: UUID, _ update: RequestUpdate) async throws -> Void
}

extension IdeasClient {
    static func live(_ client: SupabaseClient) -> IdeasClient {
        IdeasClient(
            requests: { householdID in
                try await client.from("requests")
                    .select("""
                        id, requested_by_member_id, meal_id, title, link, note, target_date, status, planned_night_id, \
                        created_at, request_plus_ones(member_id), plan_nights!requests_night_fkey(date)
                        """)
                    .eq("household_id", value: householdID)
                    .neq("status", value: RequestStatus.archived.rawValue)
                    .order("created_at", ascending: false)
                    .execute()
                    .value
            },
            make: { householdID, request in
                try await client.rpc("make_request", params: MakeRequestParams(householdID: householdID, request: request))
                    .execute()
                    .value
            },
            toggleMeToo: { requestID, memberID in
                try await client.rpc("toggle_me_too", params: [
                    "target_request": requestID.uuidString, "from_member": memberID.uuidString
                ]).execute().value
            },
            update: { requestID, update in
                try await client.rpc("update_request", params: UpdateRequestParams(requestID: requestID, update: update))
                    .execute()
            }
        )
    }
}

/// Every argument is sent, nulls included: PostgREST picks the function by its argument names.
private struct MakeRequestParams: Encodable {
    let householdID: UUID
    let request: NewRequest

    enum CodingKeys: String, CodingKey {
        case household = "target_household", from = "from_member", meal = "wanted_meal", title = "wanted_title"
        case link = "wanted_link", note = "request_note", date = "wanted_on"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(householdID, forKey: .household)
        try container.encode(request.from, forKey: .from)
        try container.encode(request.mealID, forKey: .meal)
        try container.encode(request.title, forKey: .title)
        try container.encode(request.link, forKey: .link)
        try container.encode(request.note, forKey: .note)
        try container.encode(request.date?.isoString, forKey: .date)
    }
}

private struct UpdateRequestParams: Encodable {
    let requestID: UUID
    let update: RequestUpdate

    enum CodingKeys: String, CodingKey {
        case request = "target_request", status = "new_status", night, clearDate = "clear_date", meal = "link_meal"
        case note = "new_note", date = "new_date"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .request)
        try container.encode(update.status, forKey: .status)
        try container.encode(update.nightID, forKey: .night)
        try container.encode(update.clearDate, forKey: .clearDate)
        try container.encode(update.linkMealID, forKey: .meal)
        try container.encode(update.note, forKey: .note)
        try container.encode(update.date?.isoString, forKey: .date)
    }
}

/// The Ideas tab's sections and each request's status (docs/spec.md → Ideas tab), and the requests Build my week
/// honors. Pure.
enum RequestBoard {
    enum Shown: Equatable, Sendable {
        case waiting
        case planned(CalendarDay)
        case tried
        case specialOccasion
    }

    struct Sections: Equatable, Sendable {
        /// Dated this week, or planned on one of its nights (Tried once that night has passed).
        var thisWeek: [DinnerRequest] = []
        /// Dated or planned for a week after this one.
        var later: [DinnerRequest] = []
        /// No date, or one gone by without being planned; and special-occasion ideas.
        var someday: [DinnerRequest] = []
        /// Links nobody has turned into a library dish yet.
        var newFinds: [DinnerRequest] = []
    }

    /// Planned for a week before this one: history now (Tried), so off the board.
    static func sections(_ requests: [DinnerRequest], weekStart: CalendarDay, today: CalendarDay) -> Sections {
        var sections = Sections()
        let weekEnd = weekStart.adding(days: 7)
        for request in requests where request.status != .archived {
            if request.status == .planned {
                guard let date = request.plannedDate, date >= weekStart else { continue }
                if date < weekEnd { sections.thisWeek.append(request) } else { sections.later.append(request) }
                continue
            }
            if request.link != nil, request.mealID == nil, request.status == .open {
                sections.newFinds.append(request)
            } else if request.status == .open, let date = request.targetDate, date >= today {
                if date < weekEnd { sections.thisWeek.append(request) } else { sections.later.append(request) }
            } else {
                sections.someday.append(request)
            }
        }
        // Most wanted first, then oldest first: a long-standing wish isn't buried.
        let order: (DinnerRequest, DinnerRequest) -> Bool = {
            ($0.plusOnes.count, $1.createdAt) > ($1.plusOnes.count, $0.createdAt)
        }
        sections.someday.sort(by: order)
        sections.newFinds.sort(by: order)
        let byNight: (DinnerRequest, DinnerRequest) -> Bool = {
            ($0.plannedDate ?? $0.targetDate ?? today) < ($1.plannedDate ?? $1.targetDate ?? today)
        }
        sections.thisWeek.sort(by: byNight)
        sections.later.sort(by: byNight)
        return sections
    }

    static func shown(_ request: DinnerRequest, today: CalendarDay) -> Shown {
        switch request.status {
        case .special: return .specialOccasion
        case .planned:
            guard let date = request.plannedDate else { return .waiting }
            return date < today ? .tried : .planned(date)
        case .open, .archived: return .waiting
        }
    }

    /// Open requests for a library dish with a night this week: Build my week lands them there.
    static func dated(_ requests: [DinnerRequest], weekStart: CalendarDay, today: CalendarDay) -> [DatedRequest] {
        requests.compactMap { request in
            guard request.status == .open, let mealID = request.mealID, let date = request.targetDate,
                  date >= max(weekStart, today), date < weekStart.adding(days: 7) else { return nil }
            return DatedRequest(mealID: mealID, date: date, requesterID: request.requestedByMemberID)
        }
    }

    /// "3 requests waiting", for This Week's empty state.
    static func waitingCount(_ requests: [DinnerRequest]) -> Int {
        requests.count { $0.status == .open }
    }
}
