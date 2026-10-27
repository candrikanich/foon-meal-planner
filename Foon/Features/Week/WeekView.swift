import SwiftData
import SwiftUI

/// This Week (docs/spec.md → Day cards): tonight on top, the rest of the week below, past nights tucked away.
/// Planners shape each night on its card or in its detail; everyone else sees the same cards read-only.
struct WeekView: View {
    @Environment(WeekStore.self) private var week
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.showTab) private var showTab
    @Query(filter: #Predicate<CachedListItem> { $0.checkedAt == nil }) private var openListItems: [CachedListItem]
    @State private var openNight: UUID?
    @State private var swappingNight: UUID?
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
        await week.load(settings: settings)
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
        ForEach(layout.ahead) { night in
            card(night)
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
        let model = WeekStore.card(for: night, members: household.visibleMembers, sides: sideNames, badges: badges)
        return DayCard(model: model, today: week.todayDay, actions: canPlan ? actions(for: night) : nil)
            .contentShape(Rectangle())
            .onTapGesture { openNight = night.id }
            .accessibilityAction(named: Text("Open night")) { openNight = night.id }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No plan yet", systemImage: "calendar.badge.plus")
        } description: {
            if canPlan {
                Text("Foon drafts the week from your library and who's home each night. You can change any night.")
            } else {
                Text("Your planner hasn't planned this week yet. Tell them what you'd like.")
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
                               members: household.visibleMembers)
    }

    private func build() async {
        await week.buildWeek { await planningContext() }
    }

    private func fillRemaining() async {
        await week.fillRemaining { await planningContext() }
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
        .environment(library)
        .modelContainer(try! SyncService.inMemoryContainer())
        .task {
            await household.load()
            await library.load(members: Member.sampleFamily)
        }
}
