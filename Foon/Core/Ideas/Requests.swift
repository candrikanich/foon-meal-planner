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
    /// Whose phone it was asked on (the requester, or someone passing the phone).
    var enteredByMemberID: UUID?
    /// The start of a week a planner said "not this week" to (or swapped it away): no priority that week.
    var skippedWeek: CalendarDay?

    init(id: UUID = UUID(), requestedByMemberID: UUID, mealID: UUID? = nil, title: String? = nil, link: URL? = nil,
         note: String? = nil, targetDate: CalendarDay? = nil, status: RequestStatus = .open, plannedNightID: UUID? = nil,
         plannedDate: CalendarDay? = nil, createdAt: Date = .now, plusOnes: [UUID] = [], enteredByMemberID: UUID? = nil) {
        (self.id, self.requestedByMemberID, self.mealID, self.title, self.link) = (id, requestedByMemberID, mealID, title, link)
        (self.note, self.targetDate, self.status, self.plannedNightID) = (note, targetDate, status, plannedNightID)
        self.plannedDate = plannedDate
        self.enteredByMemberID = enteredByMemberID
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
        case enteredByMemberID = "entered_by_member_id"
        case skippedWeek = "skipped_week"
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
        enteredByMemberID = try container.decodeIfPresent(UUID.self, forKey: .enteredByMemberID)
        skippedWeek = try container.decodeIfPresent(CalendarDay.self, forKey: .skippedWeek)
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

    enum Kind: Hashable, Sendable { case library, name, link }

    static let titleLimit = 80
    static let noteLimit = 200
    static let linkLimit = 2048

    /// The request the sheet's fields describe, or nil until it's complete and within the server's limits. Names and
    /// notes are trimmed; a link must be a web link ("recipes.example/x" gains https).
    static func build(kind: Kind, from: UUID, mealID: UUID?, title: String, link: String, note: String,
                      date: CalendarDay?) -> NewRequest? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.unicodeScalars.count <= titleLimit, note.unicodeScalars.count <= noteLimit else { return nil }
        var request = NewRequest(from: from, note: note.isEmpty ? nil : note, date: date)
        switch kind {
        case .library:
            guard let mealID else { return nil }
            request.mealID = mealID
        case .name:
            guard !title.isEmpty else { return nil }
            request.title = title
        case .link:
            guard let url = LibraryStore.webLink(link), url.absoluteString.count <= linkLimit else { return nil }
            request.link = url.absoluteString
            request.title = title.isEmpty ? nil : title
        }
        return request
    }
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
    /// Not this week (or a priority dish swapped away): that week's start. Planners only.
    var skipWeek: CalendarDay?
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
                        created_at, entered_by_member_id, skipped_week, request_plus_ones(member_id), \
                        plan_nights!requests_night_fkey(date)
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
        case note = "new_note", date = "new_date", skipWeek = "skip_week"
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
        try container.encode(update.skipWeek?.isoString, forKey: .skipWeek)
    }
}

/// A link on an idea, to read before saving it as a dish.
struct IdeaLink: Identifiable, Equatable, Sendable {
    let url: URL
    /// The idea's own name, when it has one.
    let name: String?

    var id: URL { url }
}

/// What Save to library does next for an idea.
enum LibrarySave: Equatable, Sendable {
    /// A dish is already made for it and linking failed: link that one, never a second.
    case link(UUID)
    case read(IdeaLink)
    case make(MealDraft)
}

/// The Ideas tab's sections and each request's status (docs/spec.md → Ideas tab), and the requests Build my week
/// honors. Pure.
enum RequestBoard {
    /// Whether pulling down on Ideas should load the library too: it never loaded, or an idea points at a dish it doesn't
    /// hold yet (a reload that failed after the dish was made, a dish from another phone).
    static func needsLibraryReload(_ requests: [DinnerRequest], library: [LibraryMeal], hasLoaded: Bool) -> Bool {
        guard hasLoaded else { return true }
        let held = Set(library.map(\.id))
        return requests.contains { $0.mealID.map { !held.contains($0) } ?? false }
    }

    /// A link is read first, so the dish gets its ingredients. A name with nothing to read is made as it is.
    static func librarySave(_ request: DinnerRequest, made: UUID?) -> LibrarySave {
        if let made { return .link(made) }
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title?.isEmpty == false ? title : nil
        if let link = request.link, LibraryStore.webLink(link.absoluteString) != nil {
            return .read(IdeaLink(url: link, name: name))
        }
        var draft = MealDraft(newNamed: name ?? request.link.map(ShareRouter.siteLabel) ?? String(localized: "New dish"))
        draft.link = request.link?.absoluteString ?? ""
        return .make(draft)
    }

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
            return DatedRequest(mealID: mealID, date: date, requesterID: request.requestedByMemberID, requestID: request.id)
        }
    }

    /// The fewest people (requester included) for a someday request to get top priority: "multiple +1s". A smaller
    /// family needs everyone, and never just one person.
    static func wantedThreshold(familySize: Int) -> Int {
        max(2, min(3, familySize))
    }

    /// Someday requests for a library dish that enough of the family wants (active members: someone away all week could
    /// never be home for it, so they don't count, and neither do removed ones, or anyone who eats separately: this is a
    /// vote, and they don't get one): Build my week finds them a night everyone who wants them is home. Not in a week a
    /// planner said "not this week" to. Most wanted first, then the oldest.
    static func wanted(_ requests: [DinnerRequest], weekStart: CalendarDay, today: CalendarDay,
                       members: [Member]) -> [WantedRequest] {
        let family = Set(members.filter { $0.status != .removed && !$0.isAway(today: today) && !$0.eatsSeparately }.map(\.id))
        let threshold = wantedThreshold(familySize: family.count)
        return requests
            .compactMap { request -> (request: DinnerRequest, wanted: WantedRequest)? in
                guard request.status == .open, let mealID = request.mealID, request.skippedWeek != weekStart,
                      request.targetDate.map({ $0 < today }) ?? true else { return nil }
                let wanters = Set(request.plusOnes).union([request.requestedByMemberID]).intersection(family)
                guard wanters.count >= threshold else { return nil }
                return (request, WantedRequest(mealID: mealID, requesterID: request.requestedByMemberID, wanters: wanters,
                                               requestID: request.id))
            }
            .sorted { ($0.wanted.wanters.count, $1.request.createdAt) > ($1.wanted.wanters.count, $0.request.createdAt) }
            .map(\.wanted)
    }

    /// Open requests whose dish now made the week: request → night. A request dated from today on, on its night;
    /// any other (someday, or a date gone by), only on the night Build my week landed that very request
    /// (`requestNights`, request → night), never just a night that happens to hold the same dish.
    static func landed(_ requests: [DinnerRequest], nights: [WeekNight], today: CalendarDay,
                       requestNights: [UUID: UUID] = [:], away: [AwayDates] = []) -> [(requestID: UUID, nightID: UUID)] {
        var taken = Set<UUID>()
        return requests.compactMap { request in
            guard request.status == .open, let mealID = request.mealID else { return nil }
            let night: WeekNight? = if let date = request.targetDate, date >= today {
                nights.first { $0.date == date && $0.mealID == mealID }
            } else {
                requestNights[request.id].flatMap { id in nights.first { $0.id == id && $0.mealID == mealID } }
            }
            guard let night, !taken.contains(night.id), !away.contains(where: { $0.contains(night.date) }) else { return nil }
            taken.insert(night.id)
            return (request.id, night.id)
        }
    }

    /// Open requests a swap took off this week, as candidates for the night an undo just put back: request → night, for
    /// `landed`, which holds them to the dish that's there. A planner's own "not this week" reads the same, and lands too.
    static func sentBack(_ requests: [DinnerRequest], night nightID: UUID, in week: Week) -> [UUID: UUID] {
        Dictionary(requests.filter { $0.status == .open && $0.skippedWeek == week.start }.map { ($0.id, nightID) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Planned requests whose night (in this week) no longer holds their dish, after a swap or rebuild: back to open.
    static func unlanded(_ requests: [DinnerRequest], nights: [WeekNight]) -> [UUID] {
        let byID = Dictionary(nights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return requests.compactMap { request in
            guard request.status == .planned, let nightID = request.plannedNightID, let night = byID[nightID],
                  let mealID = request.mealID, night.mealID != mealID else { return nil }
            return request.id
        }
    }

    /// Whether a non-planner may archive a request (the server's rule): it's theirs or entered on their phone, and
    /// the person it's from is them or still has no account of their own.
    static func canArchive(_ request: DinnerRequest, me: Member?, members: [Member]) -> Bool {
        guard let me, me.id == request.requestedByMemberID || me.id == request.enteredByMemberID,
              let from = members.first(where: { $0.id == request.requestedByMemberID }), from.status != .removed
        else { return false }
        return from.id == me.id || from.userID == nil
    }

    /// "Your crab legs made Friday": your requests (or ones entered on your phone) planned on a night within the coming
    /// week (today and the seven nights after), until you dismiss them. The in-app note until push arrives (M2 car 6).
    static func news(_ requests: [DinnerRequest], me: UUID, today: CalendarDay, dismissed: Set<UUID>) -> [DinnerRequest] {
        requests.filter { request in
            guard request.status == .planned, let date = request.plannedDate, !dismissed.contains(request.id),
                  me == request.requestedByMemberID || me == request.enteredByMemberID else { return false }
            return date >= today && date < today.adding(days: 8)
        }
        .sorted { ($0.plannedDate ?? today) < ($1.plannedDate ?? today) }
    }

    /// "3 requests waiting", for This Week's empty state.
    static func waitingCount(_ requests: [DinnerRequest]) -> Int {
        requests.count { $0.status == .open }
    }
}
