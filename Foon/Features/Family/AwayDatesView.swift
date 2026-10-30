import SwiftUI

/// Vacation mode (docs/spec.md → Away dates): mark when the whole household is away. Planners only.
struct AwayDatesView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var first = Date.now
    @State private var last = Date.now
    @State private var confirmingAdd = false
    @State private var isSaving = false

    private var dates: [AwayDates] { store.household?.planningSettings.awayDates(endingOnOrAfter: today) ?? [] }
    private var today: CalendarDay { CalendarDay(Date.now) }

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
                            Text(stretch.summary)
                            Spacer()
                            Button("Remove", systemImage: "xmark.circle") {
                                Task { await save { await store.removeAwayDates(stretch) } }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .tint(.secondary)
                            .disabled(isSaving)
                            .accessibilityLabel(String(localized: "Remove \(stretch.summary)"))
                        }
                    }
                }
            }

            Section {
                DatePicker("First night away", selection: $first, in: Calendar.current.startOfDay(for: .now)...,
                           displayedComponents: .date)
                DatePicker("Last night away", selection: $last, in: lastNightRange, displayedComponents: .date)
                Button("Add away dates", systemImage: "airplane") { confirmingAdd = true }
                    .tint(Palette.paprika)
                    .disabled(isSaving)
            } footer: {
                Text("Foon won't plan dinners, build a list, or send reminders for those nights. Everyone shows as out, and you'll see Away on This Week.")
            }

            if let message = store.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Away dates")
        .onChange(of: first) { _, first in
            if last < first { last = first }
        }
        .onAppear { store.clearError() }
        .confirmationDialog("Mark \(chosen.summary) as away?", isPresented: $confirmingAdd, titleVisibility: .visible) {
            Button("Mark as away") {
                let chosen = chosen
                Task { await save { await store.addAwayDates(chosen, today: today) } }
            }
        } message: {
            Text("Anything already planned for those nights comes off, including locked nights, and stays off if you change your mind.")
        }
    }

    /// The server takes a year at most per stretch.
    private var lastNightRange: ClosedRange<Date> {
        first...(Calendar.current.date(byAdding: .day, value: 366, to: first) ?? first)
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
