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
            Text("Lots of families plan Sunday morning, before shopping. Foon reminds planners then, on devices with reminders on.")
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
            if settings.notificationPreset != .light {
                DatePicker("Ask who's home at", selection: time(\.checkInTime), displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text("\(settings.notificationPreset.summary) Each person's device asks before it sends anything. You can change this anytime in Family.")
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

/// One sitting on the Rhythm screen: the settings as it opened, and the edits since. Only the difference between those two
/// is ever saved, so a refresh underneath, bringing in another planner's change, can't turn into a change here.
@Observable @MainActor
final class RhythmEditModel {
    private let store: HouseholdStore
    private let opened: HouseholdSettings
    var draft: HouseholdSettings

    init(store: HouseholdStore) {
        self.store = store
        opened = store.household?.planningSettings ?? HouseholdSettings()
        draft = opened
    }

    var changes: RhythmChanges { RhythmChanges(from: opened, to: draft) }

    func save() async -> Bool {
        await store.updateRhythm(changes)
    }
}

/// Family → Rhythm: the household's rhythm and planning mix after onboarding. Planners only (the server's rule too).
struct HouseholdRhythmView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// In `@State`, so it's the first one made that stays: the sheet's content is rebuilt each time the household refreshes.
    @State private var model: RhythmEditModel
    @State private var weekStart: WeekStartCheck?
    @State private var isSaving = false

    init(store: HouseholdStore) {
        _model = State(initialValue: RhythmEditModel(store: store))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                RhythmFields(settings: $model.draft, weekStartIsLocked: weekStart != .free, weekNote: weekNote)
                Section {
                    Stepper("New dishes a week: \(model.draft.newDishesPerWeek)", value: $model.draft.newDishesPerWeek, in: 0...7)
                    Stepper("Takeout nights a week: \(model.draft.takeoutNights)", value: $model.draft.takeoutNights, in: 0...7)
                    Stepper("Leftover nights a week: \(model.draft.leftoverNights)", value: $model.draft.leftoverNights, in: 0...7)
                    Stepper("Days before a repeat: \(model.draft.repeatWindowDays)", value: $model.draft.repeatWindowDays, in: 0...60)
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
                            if await model.save() { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || model.changes.isEmpty)
                }
            }
        }
    }

    private var weekNote: String {
        let times = String(localized: "Changing dinner time moves tonight and every night after it.")
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
    HouseholdRhythmView(store: store)
        .environment(store)
        .task { await store.load() }
}

#Preview("Rhythm, between plans") {
    let store = HouseholdStore.preview()
    HouseholdRhythmView(store: store)
        .environment(store)
        .task { await store.load() }
}
