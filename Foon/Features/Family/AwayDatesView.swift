import SwiftUI

/// Vacation mode (docs/spec.md → Away dates): mark when the whole household is away. Planners only.
struct AwayDatesView: View {
    @Environment(HouseholdStore.self) private var store
    /// For naming what comes off the week showing; the wording covers other weeks.
    @Environment(WeekStore.self) private var week: WeekStore?
    @State private var first = Date.now
    @State private var last = Date.now
    @State private var confirmingAdd = false
    @State private var isSaving = false

    private var settings: HouseholdSettings { store.household?.planningSettings ?? HouseholdSettings() }
    private var dates: [AwayDates] { settings.awayDates(endingOnOrAfter: today) }
    /// The household's day, which is what the server clears nights by, wherever this device is.
    private var today: CalendarDay { settings.today() }

    private var chosen: AwayDates {
        let (from, to) = (CalendarDay(first), CalendarDay(last))
        return AwayDates(from: from, to: max(from, to))
    }

    var body: some View {
        Form {
            if !dates.isEmpty {
                Section("Coming up") {
                    ForEach(dates) { stretch in
                        HStack {
                            Text(stretch.summary(today: today))
                            Spacer()
                            Button("Remove", systemImage: "xmark.circle") {
                                Task { await save { await store.removeAwayDates(stretch) } }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .tint(.secondary)
                            .disabled(isSaving)
                            .accessibilityLabel(String(localized: "Remove \(stretch.summary(today: today))"))
                        }
                    }
                }
            }

            Section {
                DatePicker("First night away", selection: $first, in: today.date()..., displayedComponents: .date)
                DatePicker("Last night away", selection: $last, in: lastNightRange, displayedComponents: .date)
                Button("Add away dates", systemImage: "airplane") { confirmingAdd = true }
                    .tint(Palette.paprika)
                    .disabled(isSaving)
            } footer: {
                Text("Foon won't plan dinners for those nights, add them to the list, or send reminders about them. Everyone shows as out, and you'll see Away on This Week.")
            }

            if let message = store.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Away dates")
        .onChange(of: first) { _, first in
            last = AwayDates.clampedLast(CalendarDay(last), first: CalendarDay(first)).date()
        }
        .onAppear {
            store.clearError()
            first = today.date()
            last = first
        }
        .confirmationDialog("Mark \(chosen.summary(today: today)) as away?", isPresented: $confirmingAdd, titleVisibility: .visible) {
            Button("Mark as away") {
                let chosen = chosen
                Task { await save { await store.addAwayDates(chosen) } }
            }
        } message: {
            Text(chosen.confirmation(today: today, week: week?.week?.nights ?? []))
        }
    }

    private var lastNightRange: ClosedRange<Date> {
        first...CalendarDay(first).adding(days: AwayDates.longestSpanDays).date()
    }

    private func save(_ work: () async -> Bool) async {
        isSaving = true
        defer { isSaving = false }
        _ = await work()
    }
}

#Preview("With dates") {
    var settings = HouseholdSettings()
    settings.awayDates = [AwayDates(from: CalendarDay(year: 2026, month: 12, day: 20),
                                    to: CalendarDay(year: 2026, month: 12, day: 27))]
    var household = Household.sample
    household.settings = settings
    let store = HouseholdStore.preview(household: household)
    return NavigationStack { AwayDatesView() }
        .environment(store)
        .task { await store.load() }
}

#Preview("None yet") {
    let store = HouseholdStore.preview()
    NavigationStack { AwayDatesView() }
        .environment(store)
        .task { await store.load() }
}
