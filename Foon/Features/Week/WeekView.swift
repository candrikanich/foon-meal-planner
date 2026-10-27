import SwiftUI

/// This week (or next): the planner starts it, then sets who's home and each night's effort on the day cards.
/// Everyone else sees the same cards read-only. Build my week, swaps, and the wallet stack come with #23–#25.
struct WeekView: View {
    @Environment(WeekStore.self) private var week
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase

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
            .refreshable { await load() }
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

    @ViewBuilder
    private var content: some View {
        if week.week == nil && !week.hasLoaded && week.isLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else if week.week == nil {
            emptyState
        } else {
            ForEach(week.cards(members: household.visibleMembers, sides: sideNames)) { card in
                DayCard(model: card, today: week.todayDay, actions: canPlan ? actions(for: card) : nil)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No plan yet", systemImage: "calendar.badge.plus")
        } description: {
            if canPlan {
                Text("Start the week to lay out the nights, with who's home from everyone's usual schedule.")
            } else {
                Text("Your planner hasn't started this week yet.")
            }
        } actions: {
            if canPlan {
                Button("Start the week") { Task { await week.startWeek() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.paprika)
                    .disabled(week.isStarting)
            }
        }
        .frame(minHeight: 320)
    }

    private func actions(for card: DayCardModel) -> DayCard.Actions? {
        guard let night = week.night(card.date) else { return nil }
        return DayCard.Actions(
            toggleAttendance: { memberID in Task { await week.toggleAttendance(nightID: night.id, memberID: memberID) } },
            cycleEffort: { Task { await week.cycleEffort(nightID: night.id) } }
        )
    }

    private func sideNames(_ mealID: UUID) -> [String] {
        library.meal(mealID).map(library.sideNames(for:)) ?? []
    }
}

#Preview("Planner, no week yet") {
    let household = HouseholdStore.preview()
    let week = WeekStore(householdID: Household.sample.id, client: .preview())
    WeekView()
        .environment(household)
        .environment(week)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .task { await household.load() }
}

#Preview("Planner, started") {
    let household = HouseholdStore.preview()
    let week = WeekStore(householdID: Household.sample.id, client: .preview(started: true))
    WeekView()
        .environment(household)
        .environment(week)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .task { await household.load() }
}
