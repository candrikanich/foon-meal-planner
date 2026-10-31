import SwiftUI

/// The Ideas tab (docs/spec.md → Ideas tab): what the family wants, For this week, Later, Someday, and New finds, with
/// me too and one "I want..." button. Planners decide what happens to each; no hard decline and no limits.
struct IdeasView: View {
    @Environment(IdeasStore.self) private var ideas
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(WeekStore.self) private var week
    @State private var asking = false
    @State private var open: DinnerRequest?

    private var sections: RequestBoard.Sections {
        let today = week.todayDay
        let start = week.week?.start ?? WeekMath.start(of: today, weekStart: settings.weekStart)
        return RequestBoard.sections(ideas.requests, weekStart: start, today: today)
    }

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }

    var body: some View {
        NavigationStack {
            List {
                if let message = ideas.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
                let sections = sections
                section("For this week", sections.thisWeek)
                section("Later", sections.later)
                section("Someday", sections.someday)
                section("New finds", sections.newFinds)
                if ideas.hasLoaded && ideas.requests.isEmpty {
                    ContentUnavailableView {
                        Label("No ideas yet", systemImage: "lightbulb")
                    } description: {
                        Text("Want steak Friday, or crab legs someday? Ask here, and the planner sees it.")
                    }
                }
            }
            .navigationTitle("Ideas")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("I want...", systemImage: "plus") { asking = true }
                }
            }
            .refreshable {
                await ideas.load()
                if RequestBoard.needsLibraryReload(ideas.requests, library: library.meals, hasLoaded: library.hasLoaded) {
                    await library.load(members: household.members)
                }
            }
            .task {
                await ideas.load()
                if !library.hasLoaded { await library.load(members: household.members) }
            }
            .sheet(isPresented: $asking) { IWantSheet() }
            .sheet(item: $open) { request in RequestDetailView(requestID: request.id) }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ requests: [DinnerRequest]) -> some View {
        if !requests.isEmpty {
            Section(title) {
                // Not a Button around the row: the row's own Me too button stays separately tappable and reachable.
                ForEach(requests) { request in
                    RequestRow(request: request)
                        .onTapGesture { open = request }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { open = request }
                }
            }
        }
    }
}

/// One idea: what, from whom, the note, me-toos, and its status.
struct RequestRow: View {
    @Environment(IdeasStore.self) private var ideas
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(WeekStore.self) private var week
    let request: DinnerRequest

    var body: some View {
        let from = household.members.first { $0.id == request.requestedByMemberID }
        HStack(alignment: .top, spacing: 12) {
            if let from { MemberAvatar(member: from, size: 36) }
            VStack(alignment: .leading, spacing: 4) {
                Text(RequestText.what(request, library: library)).font(.foonHeadline).foregroundStyle(Palette.ink)
                if let from {
                    Text(RequestText.from(from.firstName, request: request)).font(.foonCaption).foregroundStyle(.secondary)
                }
                if let note = request.note { Text(note).font(.foonBody).foregroundStyle(Palette.ink) }
                HStack(spacing: 8) {
                    Chip(text: RequestText.status(RequestBoard.shown(request, today: week.todayDay)))
                    if !request.plusOnes.isEmpty {
                        Label(request.plusOnes.count == 1 ? String(localized: "1 me-too")
                                                          : String(localized: "\(request.plusOnes.count) me-toos"),
                              systemImage: "hand.raised.fill")
                            .font(.foonCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let me = household.me, me.id != request.requestedByMemberID {
                let mine = request.plusOnes.contains(me.id)
                Button {
                    Task { await ideas.toggleMeToo(request.id, memberID: me.id) }
                } label: {
                    Label(mine ? "Me too" : "Me too?", systemImage: mine ? "hand.raised.fill" : "hand.raised")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .tint(mine ? Palette.paprika : .secondary)
                .disabled(ideas.saving.contains(request.id))
                .accessibilityLabel(mine ? Text("Take back your me too") : Text("Me too"))
            }
        }
        .contentShape(Rectangle())
    }
}

/// The words for a request, kept out of the views so they're testable.
enum RequestText {
    /// The dish, the typed name, or the link's site.
    @MainActor
    static func what(_ request: DinnerRequest, library: LibraryStore) -> String {
        request.mealID.flatMap { library.meal($0)?.name } ?? request.title ?? request.link?.host()
            ?? String(localized: "An idea")
    }

    static func from(_ name: String, request: DinnerRequest) -> String {
        guard let date = request.targetDate else { return String(localized: "From \(name)") }
        let day = date.date().formatted(.dateTime.weekday(.wide))
        return String(localized: "From \(name), for \(day)", comment: "Idea row: who asked and the night they want it")
    }

    /// "Your idea made Friday: Crab legs" ("is on for tonight" and "tomorrow" when it is).
    @MainActor
    static func madeIt(_ request: DinnerRequest, library: LibraryStore, today: CalendarDay) -> String {
        madeIt(what: what(request, library: library), on: request.plannedDate, today: today)
    }

    static func madeIt(what: String, on date: CalendarDay?, today: CalendarDay) -> String {
        guard let date else {
            return String(localized: "Your idea made the plan: \(what)", comment: "Request news: the dish, night unknown")
        }
        if date == today {
            return String(localized: "Your idea is on for tonight: \(what)", comment: "Request news: the dish")
        }
        if date == today.adding(days: 1) {
            return String(localized: "Your idea is on for tomorrow: \(what)", comment: "Request news: the dish")
        }
        let day = date.date().formatted(.dateTime.weekday(.wide))
        return String(localized: "Your idea made \(day): \(what)", comment: "Request news: the weekday it's planned, then the dish")
    }

    static func status(_ shown: RequestBoard.Shown) -> String {
        switch shown {
        case .waiting: String(localized: "Waiting")
        case .planned(let day):
            String(localized: "Planned for \(day.date().formatted(.dateTime.weekday(.wide)))",
                   comment: "Idea status: the night it's planned")
        case .tried: String(localized: "Tried")
        case .specialOccasion: String(localized: "Special occasion")
        }
    }
}

#Preview("Rows") {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    List {
        ForEach(DinnerRequest.samples) { RequestRow(request: $0) }
        RequestRow(request: DinnerRequest(requestedByMemberID: Member.sampleFamily[0].id, title: "Lasagna",
                                          status: .planned, plannedNightID: UUID(),
                                          plannedDate: CalendarDay(Date()).adding(days: 1)))
    }
    .environment(household)
    .environment(IdeasStore(householdID: Household.sample.id, client: .preview()))
    .environment(library)
    .environment(WeekStore(householdID: Household.sample.id, client: .preview()))
    .task {
        await household.load()
        await library.load(members: Member.sampleFamily)
    }
}

#Preview("Ideas") {
    let household = HouseholdStore.preview()
    let ideas = IdeasStore(householdID: Household.sample.id, client: .preview())
    IdeasView()
        .environment(household)
        .environment(ideas)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(WeekStore(householdID: Household.sample.id, client: .preview(started: true)))
        .task {
            await household.load()
            await ideas.load()
        }
}
