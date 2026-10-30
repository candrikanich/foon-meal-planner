import SwiftUI

/// Who changed what on the plan, for everyone in the family (Family → Plan activity). Undo lives on the night itself.
struct PlanActivityView: View {
    @Environment(PlanActivityStore.self) private var activity
    @Environment(HouseholdStore.self) private var household

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }

    var body: some View {
        let calendar = settings.dayCalendar
        let today = settings.today()
        List {
            if let message = activity.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            if activity.hasLoaded, activity.entries.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("When someone changes the plan, it shows here."))
            }
            Section {
                ForEach(activity.entries) { entry in
                    PlanChangeRow(line: PlanChangeText.line(entry, members: household.members, today: today, calendar: calendar),
                                  at: entry.changes[0].createdAt)
                }
            } footer: {
                if !activity.entries.isEmpty {
                    Text("The last eight weeks. To undo a change, open that night on This Week.")
                }
            }
        }
        .navigationTitle("Plan activity")
        .refreshable { await activity.load() }
        .task { await activity.load() }
    }
}

/// One change: what happened, and when.
struct PlanChangeRow: View {
    let line: String
    let at: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line).font(.foonBody)
            Text(at, format: .relative(presentation: .named)).font(.foonCaption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A night's recent changes, for everyone; planners can undo the last one if it's still safe to.
struct NightChangesSection: View {
    @Environment(PlanActivityStore.self) private var activity: PlanActivityStore?
    @Environment(HouseholdStore.self) private var household
    @Environment(WeekStore.self) private var week
    @Environment(DinnerStore.self) private var dinner
    @Environment(LibraryStore.self) private var library
    let night: WeekNight
    let canPlan: Bool
    /// After an undo saved: a dish leaving the night takes its request back to open.
    let onUndone: () async -> Void

    private static let shown = 5

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }

    var body: some View {
        let changes = activity?.changes(on: night.id) ?? []
        if !changes.isEmpty {
            let today = week.todayDay
            let calendar = settings.dayCalendar
            Section {
                ForEach(changes.prefix(Self.shown)) { change in
                    PlanChangeRow(line: PlanChangeText.line(change, members: household.members, today: today, calendar: calendar),
                                  at: change.createdAt)
                }
                if canPlan, let last = changes.first,
                   PlanActivity.canUndo(last, on: night, nights: week.week?.nights ?? [],
                                        isLogged: dinner.log(for: night.id) != nil, away: settings.awayDates, today: today,
                                        library: library.meals) {
                    Button(PlanChangeText.undoTitle(last), systemImage: "arrow.uturn.backward") {
                        Task {
                            if await week.undoChange(last) { await onUndone() }
                            await activity?.load()
                        }
                    }
                    .tint(Palette.paprika)
                    .disabled(week.isBuilding || week.undoing.contains(night.id))
                    .accessibilityHint("Puts back what this night held before its last change")
                }
            } header: {
                Text("Recent changes")
            }
        }
    }
}

#Preview("Plan activity") {
    let store = HouseholdStore.preview()
    NavigationStack { PlanActivityView() }
        .environment(store)
        .environment(PlanActivityStore(householdID: Household.sample.id, client: .preview(started: true)))
        .task { await store.load() }
}

#Preview("On a night") {
    @Previewable @State var store = HouseholdStore.preview()
    let change = PlanChange.samples[0]
    let night = WeekNight(id: change.nightID, date: change.nightDate, effort: .normal, mealID: change.after.mealID,
                          mealName: change.after.mealName, locked: true, attendance: [:])
    let activity: PlanActivityStore = {
        var client = WeekClient.preview(started: true)
        client.planChanges = { _ in [change] }
        return PlanActivityStore(householdID: Household.sample.id, client: client)
    }()
    Form {
        NightChangesSection(night: night, canPlan: true) {}
    }
    .environment(store)
    .environment(activity)
    .environment(WeekStore(householdID: Household.sample.id, client: .preview(started: true)))
    .environment(DinnerStore(householdID: Household.sample.id, client: .preview))
    .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
    .task {
        await store.load()
        await activity.load()
    }
}
