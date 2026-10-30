import SwiftUI

/// Plan it's choices and what the sheet shows, kept out of the view so they're testable.
enum PlanIt {
    enum State: Equatable {
        case loading
        /// The week couldn't load; offer a retry.
        case failed(String)
        /// The week This Week shows hasn't been started.
        case noWeek
        /// It hasn't been started, and the family's away for what's left of it: nothing to start.
        case away
        /// Every night from tonight on already has this meal, or the week is over.
        case noNightsLeft
        case nights([WeekNight])
    }

    static func state(layout: WeekLayout?, mealID: UUID, isLoading: Bool, hasLoaded: Bool,
                      loadError: String?, includingPlanned: Bool = false, awayForTheRest: Bool = false) -> State {
        if let layout {
            let choices = choices(in: layout, for: mealID, includingPlanned: includingPlanned)
            return choices.isEmpty ? .noNightsLeft : .nights(choices)
        }
        if hasLoaded { return awayForTheRest ? .away : .noWeek }
        if !isLoading, let loadError { return .failed(loadError) }
        return .loading
    }

    /// Nights that can be planned from tonight on, minus any already set to this meal.
    static func choices(in layout: WeekLayout, for mealID: UUID, includingPlanned: Bool = false) -> [WeekNight] {
        includingPlanned ? layout.plannable : layout.plannable.filter { $0.mealID != mealID }
    }

    /// What a night holds now, so picking it says what gets replaced.
    static func currentPick(_ night: WeekNight) -> String {
        if let name = night.mealName { return name }
        if let pick = night.quickPick { return DayCardText.quickPickLabel(pick) }
        return String(localized: "Open")
    }
}

/// Plan it (library long-press, meal detail): put this meal on a night still ahead in the week This Week shows.
/// Like Swap, the planner's own pick locks the night so Rebuild keeps it.
struct PlanItSheet: View {
    @Environment(WeekStore.self) private var week
    @Environment(HouseholdStore.self) private var household
    @Environment(\.showTab) private var showTab
    @Environment(\.dismiss) private var dismiss
    let meal: LibraryMeal
    /// Called with the night once the meal is on it (the Ideas tab marks the request planned there). Returning false
    /// keeps the sheet open to try again; nights already holding this dish stay offered then.
    var onPlanned: ((UUID) async -> Bool)?
    @State private var saving: UUID?
    /// Only this sheet's own failure; the store's error may be left over from another screen.
    @State private var failure: String?

    private var state: PlanIt.State {
        PlanIt.state(layout: week.layout, mealID: meal.id, isLoading: week.isLoading, hasLoaded: week.hasLoaded,
                     loadError: week.errorMessage, includingPlanned: onPlanned != nil,
                     awayForTheRest: week.isAwayForTheRestOfTheWeek)
    }

    private var whichWeek: String {
        week.showingNextWeek ? String(localized: "Next week") : String(localized: "This week")
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't load the week", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                case .noWeek:
                    goToThisWeek(title: week.showingNextWeek ? String(localized: "Next week isn't started")
                                                            : String(localized: "No week yet"),
                                 detail: String(localized: "Start the week on This Week, then plan \(meal.name) into it."))
                case .away:
                    goToThisWeek(title: String(localized: "You're away those nights"),
                                 detail: String(localized: "Switch to another week on This Week, or change the away dates in Family."))
                case .noNightsLeft:
                    goToThisWeek(title: String(localized: "No nights left to plan"),
                                 detail: String(localized: "Switch to next week on This Week to plan it there."))
                case .nights(let choices):
                    nights(choices)
                }
            }
            .navigationTitle("Plan \(meal.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #endif
        .task { if !week.hasLoaded { await load() } }
    }

    private func load() async {
        await week.load(settings: household.household?.planningSettings ?? HouseholdSettings())
    }

    private func goToThisWeek(title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "calendar.badge.plus")
        } description: {
            Text(detail)
        } actions: {
            Button("Go to This Week") {
                showTab(.week)
                dismiss()
            }
        }
    }

    private func nights(_ choices: [WeekNight]) -> some View {
        List {
            Section {
                ForEach(choices) { night in
                    Button { plan(on: night) } label: { row(night) }
                        .buttonStyle(.plain)
                        .disabled(saving != nil || week.isBuilding)
                        .accessibilityHint(night.isPlanned ? "Replaces what's planned" : "Plans it for this night")
                }
            } header: {
                Text(whichWeek)
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                } else if week.isBuilding {
                    Text("Foon is building the week. Try again in a moment.")
                } else {
                    Text("The night stays locked, so Rebuild keeps it.")
                }
            }
        }
    }

    private func row(_ night: WeekNight) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(DayCardText.dayLabel(for: night.date, today: week.currentDay)) · \(DayCardText.dateLabel(for: night.date))")
                    .font(.foonHeadline)
                Text(PlanIt.currentPick(night)).font(.foonCaption).foregroundStyle(.secondary)
                if let warning = DoubleIt.changeWarning(for: night, in: week.week?.nights ?? []) {
                    Text(warning).font(.foonCaption).foregroundStyle(Palette.paprika)
                }
            }
            Spacer()
            if saving == night.id {
                ProgressView().accessibilityLabel("Saving")
            } else if night.locked {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("Locked")
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func plan(on night: WeekNight) {
        failure = nil
        Task {
            saving = night.id
            defer { saving = nil }
            if await week.swap(nightID: night.id, to: .meal(id: meal.id, name: meal.name)) {
                if let onPlanned, !(await onPlanned(night.id)) {
                    failure = String(localized: "The dish is on that night, but the idea wasn't marked planned. Tap it again.")
                    return
                }
                dismiss()
            } else {
                failure = week.errorMessage
                    ?? String(localized: "Couldn't plan it right now. Try again in a moment.")
            }
        }
    }
}

#Preview {
    let household = HouseholdStore.preview()
    let week = WeekStore(householdID: Household.sample.id, client: .preview(started: true))
    PlanItSheet(meal: LibraryMeal.sampleLibrary[0])
        .environment(household)
        .environment(week)
        .task {
            await household.load()
            await week.load(settings: HouseholdSettings())
        }
}
