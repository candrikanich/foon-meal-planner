import SwiftUI

/// Planning day and time, week start, dinner time, and the notification preset: onboarding's "Your rhythm" step and
/// Family → Rhythm use the same form.
struct RhythmFields: View {
    @Binding var settings: HouseholdSettings
    /// True while a running plan holds the week start in place. Onboarding has no plan yet.
    var weekStartIsLocked = false
    /// What Family adds about weeks already started.
    var weekNote: String?

    var body: some View {
        Section {
            Picker("Plan on", selection: $settings.planningDay) { weekdayOptions }
            DatePicker("At", selection: time(\.planningTime), displayedComponents: .hourAndMinute)
        } header: {
            Text("When do you plan the week?")
        } footer: {
            Text("Lots of families plan Sunday morning, before shopping. Foon will remind you then once reminders arrive.")
        }
        Section {
            Picker("Week starts", selection: $settings.weekStart) { weekdayOptions }
                .disabled(weekStartIsLocked)
            DatePicker("Dinner at", selection: time(\.dinnerTime), displayedComponents: .hourAndMinute)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The week starts on your shopping day.")
                if let weekNote { Text(weekNote) }
            }
        }
        Section {
            Picker("Notifications", selection: $settings.notificationPreset) {
                ForEach(HouseholdSettings.NotificationPreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("\(settings.notificationPreset.summary) Nothing is sent yet: notifications are still on the way. You can change this anytime in Family.")
        }
    }

    private var weekdayOptions: some View {
        ForEach(WeekMath.weekdays) { Text($0.name()).tag($0.iso) }
    }

    /// "HH:mm" in settings, a Date in the picker.
    private func time(_ key: WritableKeyPath<HouseholdSettings, String>) -> Binding<Date> {
        Binding(
            get: {
                let parts = settings[keyPath: key].split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: parts.first ?? 18, minute: parts.last ?? 0, second: 0,
                                             of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings[keyPath: key] = String(format: "%02d:%02d", parts.hour ?? 18, parts.minute ?? 0)
            }
        )
    }
}

/// Family → Rhythm: the household's rhythm and planning mix after onboarding. Planners only (the server's rule too). Saves
/// only what changed since the screen opened, however old this phone's copy of the rest is.
struct HouseholdRhythmView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let opened: HouseholdSettings
    @State private var draft: HouseholdSettings
    @State private var weekStart: WeekStartCheck?
    @State private var isSaving = false

    init(settings: HouseholdSettings) {
        opened = settings
        _draft = State(initialValue: settings)
    }

    private var changes: RhythmChanges { RhythmChanges(from: opened, to: draft) }

    var body: some View {
        NavigationStack {
            Form {
                RhythmFields(settings: $draft, weekStartIsLocked: weekStart != .free, weekNote: weekNote)
                Section {
                    Stepper("New dishes a week: \(draft.newDishesPerWeek)", value: $draft.newDishesPerWeek, in: 0...7)
                    Stepper("Takeout nights a week: \(draft.takeoutNights)", value: $draft.takeoutNights, in: 0...7)
                    Stepper("Leftover nights a week: \(draft.leftoverNights)", value: $draft.leftoverNights, in: 0...7)
                    Stepper("Days before a repeat: \(draft.repeatWindowDays)", value: $draft.repeatWindowDays, in: 0...60)
                } header: {
                    Text("Planning mix")
                } footer: {
                    Text("Build my week aims for these the next time it runs. Dinners already planned stay as they are.")
                }
                if let message = store.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Rhythm")
            .onAppear { store.clearError() }
            .task { weekStart = await store.weekStartCheck() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            if await store.updateRhythm(changes) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || changes.isEmpty)
                }
            }
        }
    }

    private var weekNote: String {
        let times = String(localized: "A new dinner time starts with the next week you start.")
        switch weekStart {
        case .lockedThrough(let last):
            let date = DayCardText.dateLabel(for: last)
            return String(localized: "\(times) The week start can change once your plan ends on \(date), before you start another week.",
                          comment: "Rhythm: the first sentence is about dinner time, then a date such as Sat, Oct 31")
        case .unknown:
            return String(localized: "\(times) Foon couldn't check your plan, so the week start can't change right now.",
                          comment: "Rhythm: the first sentence is about dinner time")
        case .free, nil:
            return times
        }
    }
}

#Preview("Rhythm, a plan running") {
    let store = HouseholdStore(userID: .previewUser, client: {
        var client = HouseholdClient.preview()
        client.latestWeekStart = { _ in CalendarDay(Date()) }
        return client
    }())
    HouseholdRhythmView(settings: HouseholdSettings())
        .environment(store)
        .task { await store.load() }
}

#Preview("Rhythm, between plans") {
    let store = HouseholdStore.preview()
    HouseholdRhythmView(settings: HouseholdSettings())
        .environment(store)
        .task { await store.load() }
}
