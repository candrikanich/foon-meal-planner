import SwiftData
import SwiftUI

/// This Week (docs/spec.md → Day cards): tonight on top, the rest of the week below, past nights tucked away.
/// Planners shape each night on its card or in its detail; everyone else sees the same cards read-only.
struct WeekView: View {
    @Environment(WeekStore.self) private var week
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(DinnerStore.self) private var dinner
    @Environment(IdeasStore.self) private var ideas
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.showTab) private var showTab
    @Query(filter: #Predicate<CachedListItem> { $0.checkedAt == nil }) private var openListItems: [CachedListItem]
    @Query private var cachedItems: [CachedItem]
    @Environment(SyncService.self) private var sync: SyncService?
    @State private var isApproving = false
    @State private var openNight: UUID?
    @State private var swappingNight: UUID?
    @State private var showingTraditions = false
    @State private var browsingIdeas = false
    @State private var showingPast = false

    private var canPlan: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }

    var body: some View {
        @Bindable var week = week
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !week.showingNextWeek {
                        DinnerPromptsSection()
                    }
                    Picker("Week", selection: $week.showingNextWeek) {
                        Text("This week").tag(false)
                        Text("Next week").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if let message = week.errorMessage {
                        Text(message).font(.callout).foregroundStyle(.red)
                    }
                    content
                }
                .padding()
            }
            .background(Palette.cream)
            .navigationTitle("This Week")
            .toolbar { cart }
            .refreshable { await load() }
            .sheet(item: Binding(get: { openNight.map(NightID.init) }, set: { openNight = $0?.id })) { night in
                NightDetailView(nightID: night.id, canPlan: canPlan)
            }
            .sheet(item: Binding(get: { swappingNight.map(NightID.init) }, set: { swappingNight = $0?.id })) { night in
                SwapSheet(nightID: night.id)
            }
            .sheet(isPresented: $showingTraditions) {
                TraditionsView()
            }
            .sheet(isPresented: $browsingIdeas) {
                CatalogBrowserView(canAdd: true)
            }
        }
        .task(id: LoadKey(householdID: household.household?.id, next: week.showingNextWeek,
                          weekStart: settings.weekStart, today: week.todayDay)) {
            await load()
        }
        .onChange(of: scenePhase) { _, phase in
            // Back in the foreground, possibly on a new day or a new week.
            if phase == .active { Task { await load() } }
        }
        .onChange(of: household.members) { _, members in
            if canPlan { Task { await week.fillInMissing(members: members) } }
        }
    }

    private struct NightID: Identifiable {
        let id: UUID
    }

    private struct LoadKey: Equatable {
        let householdID: UUID?
        let next: Bool
        let weekStart: Int
        let today: CalendarDay
    }

    /// Waits for the household, so the first load uses its real shopping day.
    private func load() async {
        guard household.household != nil else { return }
        // The library (allergy flags, sides, serving notes, and Build) loads alongside the week, not before it, for
        // everyone: members see the same flags and notes on the cards as planners.
        let loadsLibrary = !library.hasLoaded
        async let libraryLoad: Void = loadsLibrary ? library.load(members: household.members) : ()
        async let dinnerLoad: Void = dinner.load(settings: settings)
        async let ideasLoad: Void = ideas.load()
        await week.load(settings: settings)
        await libraryLoad
        await dinnerLoad
        await ideasLoad
        // A full library load just read them; otherwise last night's answers count in the next build.
        if !loadsLibrary { await library.refreshReactions() }
        if canPlan { await week.fillInMissing(members: household.members) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let layout = week.layout {
            planned(layout)
        } else if !week.hasLoaded && week.isLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func planned(_ layout: WeekLayout) -> some View {
        if canPlan, layout.progress == .unplanned, !layout.ahead.isEmpty {
            Button { Task { await build() } } label: {
                Label("Build my week", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.paprika)
            .disabled(week.isBuilding)
        } else if canPlan, layout.progress == .partlyPlanned {
            HStack {
                Label(openNightsText(layout.emptyNights.count), systemImage: "square.dashed")
                    .font(.foonCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fill remaining nights") { Task { await fillRemaining() } }
                    .font(.foonCaption)
                    .buttonStyle(.bordered)
                    .tint(Palette.paprika)
                    .disabled(week.isBuilding)
            }
        }
        let unfillable = layout.emptyNights.filter { week.unfillableNights.contains($0.id) }.count
        if canPlan, library.hasLoaded, unfillable > 0 {
            smallLibrary(unfillable: unfillable, planned: Set(layout.ahead.compactMap(\.mealID)))
        }
        ForEach(layout.ahead) { night in
            card(night)
        }
        if canPlan, layout.ahead.contains(where: \.isPlanned) {
            approveSection(layout)
        }
        if !layout.past.isEmpty {
            DisclosureGroup(isExpanded: $showingPast) {
                VStack(spacing: 12) {
                    ForEach(layout.past) { night in card(night) }
                }
                .padding(.top, 8)
            } label: {
                Text(earlierText(layout.past.count)).font(.foonHeadline).foregroundStyle(Palette.ink)
            }
            .tint(Palette.paprika)
        }
    }

    private func card(_ night: WeekNight) -> some View {
        let model = WeekStore.card(for: night, members: household.visibleMembers, sides: sideNames, badges: badges,
                                   notes: { meal, home in
                                       ServingNotes.lines(library.servingNotes, mealID: meal, home: home,
                                                          members: household.visibleMembers)
                                   })
        return DayCard(model: model, today: week.todayDay, actions: canPlan ? actions(for: night) : nil)
            .contentShape(Rectangle())
            .onTapGesture { openNight = night.id }
            .accessibilityAction(named: Text("Open night")) { openNight = night.id }
    }

    /// The weekly list for the nights still ahead: their meals and sides merged by item, minus what's in stock,
    /// plus low or out staples, with allergy notes for whoever's home.
    private func weeklyList(_ layout: WeekLayout) -> [WeeklyList.Line] {
        let stock = Dictionary(cachedItems.compactMap { item in item.stockState.map { (item.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        let staples = cachedItems.filter(\.keepOnHand).compactMap { item in
            item.stockState.map { WeeklyList.Staple(itemID: item.id, name: item.name, state: $0) }
        }
        let nights = layout.ahead.map { WeeklyList.Night(mealID: $0.mealID, home: Set($0.attendance.filter(\.value).keys)) }
        return WeeklyList.build(nights: nights, library: library.meals, stock: stock, staples: staples,
                                allergies: library.allergies)
    }

    private func approveSection(_ layout: WeekLayout) -> some View {
        let lines = weeklyList(layout)
        let approved = week.week?.approvedAt != nil
        return VStack(spacing: 6) {
            Button { Task { await approve(lines) } } label: {
                Label(approved ? approveText(lines.count, update: true) : approveText(lines.count, update: false),
                      systemImage: approved ? "arrow.triangle.2.circlepath" : "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(approved ? Palette.herb : Palette.paprika)
            // The list leans on the offline cache for stock and staples, so wait for its first sync.
            .disabled(isApproving || week.isBuilding || !library.hasLoaded || (sync != nil && sync?.lastPulled == nil))
            Text(approved ? "Approved. Changed a night? Update the list."
                          : "Approving builds the weekly list from these nights.")
                .font(.foonCaption)
                .foregroundStyle(.secondary)
        }
    }

    private func approve(_ lines: [WeeklyList.Line]) async {
        isApproving = true
        defer { isApproving = false }
        // Pull right away so the cart badge and Lists show the new list without waiting for Realtime.
        if await week.approve(lines) { await sync?.pull() }
    }

    private func approveText(_ count: Int, update: Bool) -> String {
        switch (update, count == 1) {
        case (false, true): String(localized: "Approve · 1 item")
        case (false, false): String(localized: "Approve · \(count) items")
        case (true, true): String(localized: "Update the list · 1 item")
        case (true, false): String(localized: "Update the list · \(count) items")
        }
    }

    /// Build left nights open rather than repeat a dish or break a rule, so offer a few starters to widen the choice.
    private func smallLibrary(unfillable: Int, planned: Set<UUID>) -> some View {
        let count = library.meals.filter(\.status.isInRotation).count
        let tooFew = LibraryQuery.unusedInRotation(library.meals, planned: planned) < unfillable
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if tooFew {
                    Text(count == 1 ? String(localized: "Your library has 1 meal")
                                    : String(localized: "Your library has \(count) meals"))
                } else {
                    Text(unfillable == 1 ? String(localized: "Nothing fit 1 night")
                                         : String(localized: "Nothing fit \(unfillable) nights"))
                }
            }
            .font(.foonHeadline)
            Text(tooFew ? String(localized: "Add a few family favorites so Foon can fill the week.")
                        : String(localized: "Add a few dishes to widen the choice, then fill the rest."))
                .font(.foonCaption)
                .foregroundStyle(.secondary)
            if let message = library.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            ForEach(LibraryQuery.starterIdeas(library.catalog, library: library.meals, count: 3)) { dish in
                CatalogDishRow(dish: dish, canAdd: true)
            }
            Button("Browse ideas") { browsingIdeas = true }
                .font(.foonCaption)
                .tint(Palette.paprika)
        }
        .onAppear { library.clearError() }
        .onDisappear { library.clearError() }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.cardSurface))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No plan yet", systemImage: "calendar.badge.plus")
        } description: {
            VStack(spacing: 8) {
                if canPlan {
                    Text("Foon drafts the week from your library and who's home each night. You can change any night.")
                } else {
                    Text("Your planner hasn't planned this week yet. Tell them what you'd like.")
                }
                let waiting = RequestBoard.waitingCount(ideas.requests)
                if waiting > 0 {
                    Button(waiting == 1 ? String(localized: "1 request waiting")
                                        : String(localized: "\(waiting) requests waiting")) { showTab(.ideas) }
                        .font(.foonCaption)
                        .tint(Palette.paprika)
                }
            }
        } actions: {
            if canPlan {
                Button("Build my week") { Task { await build() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.paprika)
                    .disabled(week.isStarting || week.isBuilding)
                Button("Start with empty nights") { Task { await week.startWeek() } }
                    .disabled(week.isStarting || week.isBuilding)
            } else {
                Button("Add your requests") { showTab(.ideas) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.paprika)
            }
        }
        .frame(minHeight: 320)
    }

    @ToolbarContentBuilder
    private var cart: some ToolbarContent {
        if canPlan {
            ToolbarItem(placement: .secondaryAction) {
                Button("Traditions", systemImage: "repeat") { showingTraditions = true }
            }
        }
        if canPlan, let layout = week.layout, layout.progress != .unplanned {
            ToolbarItem(placement: .secondaryAction) {
                Button("Rebuild unlocked nights", systemImage: "wand.and.stars") { Task { await build() } }
                    .disabled(week.isBuilding)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showTab(.lists) } label: {
                Image(systemName: "cart")
                    .overlay(alignment: .topTrailing) {
                        if !openListItems.isEmpty {
                            Text("\(openListItems.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Palette.onPaprika)
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(Palette.paprika))
                                .offset(x: 10, y: -8)
                        }
                    }
            }
            .accessibilityLabel("Lists")
            .accessibilityValue(openListItems.isEmpty ? Text("Nothing to buy") : Text("\(openListItems.count) to buy"))
        }
    }

    // MARK: - Helpers

    private func actions(for night: WeekNight) -> DayCard.Actions {
        DayCard.Actions(
            toggleAttendance: { memberID in Task { await week.toggleAttendance(nightID: night.id, memberID: memberID) } },
            cycleEffort: { Task { await week.cycleEffort(nightID: night.id) } },
            toggleLock: { Task { await week.toggleLock(nightID: night.id) } },
            // Quick-pick nights change through Swap (#25); shuffle re-rolls meals and fills empty nights.
            shuffle: night.quickPick == nil && !week.isBuilding ? { Task { await shuffle(night.id) } } : nil,
            swap: week.isBuilding ? nil : { swappingNight = night.id },
            open: { openNight = night.id }
        )
    }

    // MARK: - Build my week

    /// The library must load before drafting from it; nil when it didn't.
    private func planningContext() async -> PlanningContext? {
        if !library.hasLoaded { await library.load(members: household.members) }
        guard library.hasLoaded else { return nil }
        return PlanningContext(meals: library.meals, history: library.history, settings: settings,
                               members: household.visibleMembers, requests: requests, traditions: week.traditions,
                               reactions: library.reactions)
    }

    /// Dated requests for a library dish this week: Build my week lands each on its night. The week's start comes from
    /// settings when there's no week yet (Build from the empty state starts it after asking for this).
    private var requests: [DatedRequest] {
        let thisWeek = WeekMath.start(of: week.todayDay, weekStart: settings.weekStart)
        let start = week.week?.start ?? (week.showingNextWeek ? thisWeek.adding(days: 7) : thisWeek)
        return RequestBoard.dated(ideas.requests, weekStart: start, today: week.todayDay)
    }

    private func build() async {
        await week.buildWeek { await planningContext() }
        await ideas.sync(with: week.week)
    }

    private func fillRemaining() async {
        await week.fillRemaining { await planningContext() }
        await ideas.sync(with: week.week)
    }

    private func shuffle(_ nightID: UUID) async {
        await week.shuffle(nightID: nightID) { await planningContext() }
    }

    private func sideNames(_ mealID: UUID) -> [String] {
        library.meal(mealID).map(library.sideNames(for:)) ?? []
    }

    private func badges(_ mealID: UUID, home: Set<UUID>) -> [DayCardModel.Badge] {
        guard let meal = library.meal(mealID) else { return [] }
        return NightBadges.badges(meal: meal, library: library.meals, allergies: library.allergies, home: home)
    }

    private func openNightsText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 night still open") : String(localized: "\(count) nights still open")
    }

    private func earlierText(_ count: Int) -> String {
        count == 1 ? String(localized: "Earlier this week: 1 night") : String(localized: "Earlier this week: \(count) nights")
    }
}

#Preview("Planner, no week yet") {
    let household = HouseholdStore.preview()
    WeekView()
        .environment(household)
        .environment(WeekStore(householdID: Household.sample.id, client: .preview()))
        .environment(DinnerStore(householdID: Household.sample.id, client: .preview))
        .environment(IdeasStore(householdID: Household.sample.id, client: .preview()))
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .modelContainer(try! SyncService.inMemoryContainer())
        .task { await household.load() }
}

#Preview("Planner, partly planned") {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    WeekView()
        .environment(household)
        .environment(WeekStore(householdID: Household.sample.id, client: .preview(started: true)))
        .environment(DinnerStore(householdID: Household.sample.id, client: .preview))
        .environment(IdeasStore(householdID: Household.sample.id, client: .preview()))
        .environment(library)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task {
            await household.load()
            await library.load(members: Member.sampleFamily)
        }
}
