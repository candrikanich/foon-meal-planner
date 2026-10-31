import SwiftData
import SwiftUI

/// Keeps reminders in step while the household's screens are up: at launch, back in the foreground, and when the plan, the
/// family, the rhythm, or a rating changes on this phone.
struct ReminderRunner: ViewModifier {
    @Environment(HouseholdStore.self) private var household
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    let store: ReminderStore
    let week: Week?
    let logs: [DinnerLog]

    private struct Key: Equatable {
        let context: ReminderStore.Context?
        let week: Week?
        let logs: [DinnerLog]
    }

    private var context: ReminderStore.Context? {
        household.reminderContext
    }

    func body(content: Content) -> some View {
        content
            .task(id: Key(context: context, week: week, logs: logs)) {
                // A week load or a Build changes this several times in a row; one re-plan is enough.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                replan()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { replan() }
            }
    }

    /// Unstructured, so a change of key doesn't cancel a run halfway through scheduling.
    private func replan() {
        store.attach(modelContext)
        guard let context else { return }
        Task { await store.replan(context) }
    }
}

extension HouseholdStore {
    /// Nil until this person's profile has loaded. Nothing is decided without it, so nothing already scheduled is touched.
    var reminderContext: ReminderStore.Context? {
        guard let me, let household else { return nil }
        return ReminderStore.Context(me: me, members: visibleMembers, settings: household.planningSettings)
    }
}

/// Foon's one ask, once a week has been approved and there's something to remind them of. "Not now" is the end of it: Family has
/// the switch from then on.
struct ReminderAskCard: View {
    @Environment(ReminderStore.self) private var reminders
    @Environment(HouseholdStore.self) private var household

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Want a few reminders?", systemImage: "bell")
                .font(.foonHeadline)
            Text("Foon can nudge you about dinner on this device, when something needs starting or a dish needs rating. Only a few a week, and you can turn them off anytime.")
                .font(.foonCaption)
                .foregroundStyle(.secondary)
            // Side by side, until a large text size needs them stacked.
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
            .font(.foonCaption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.cardSurface))
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Turn on reminders") {
            guard let context = household.reminderContext else { return }
            Task { await reminders.requestPermission(for: context) }
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.paprika)
        Button("Not now") {
            if let me = household.me { reminders.decline(me.id) }
        }
        .buttonStyle(.bordered)
    }
}

/// Family: whether this device shows reminders, and the way back after "Not now" or a no. It never asks on its own.
struct ReminderSettingsSection: View {
    @Environment(ReminderStore.self) private var reminders: ReminderStore?
    @Environment(HouseholdStore.self) private var household

    var body: some View {
        if let reminders { section(reminders) }
    }

    private func section(_ reminders: ReminderStore) -> some View {
        Section {
            switch reminders.permission {
            case .on:
                Label("Reminders are on for this device", systemImage: "bell")
            case .notAsked:
                Button("Turn on reminders", systemImage: "bell") {
                    guard let context = household.reminderContext else { return }
                    Task { await reminders.requestPermission(for: context) }
                }
            case .off:
                Link(destination: Self.settingsURL) {
                    Label("Reminders are off. Turn them on in Settings.", systemImage: "bell.slash")
                }
            }
        } footer: {
            Text("A few reminders about dinner, sent from this device. Foon works the same without them.")
        }
    }

    static let settingsURL: URL = {
        #if canImport(UIKit)
        URL(string: UIApplication.openNotificationSettingsURLString)!
        #else
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        #endif
    }()
}

private extension ReminderStore {
    static var preview: ReminderStore {
        ReminderStore(householdID: Household.sample.id, client: .preview, center: .none)
    }
}

#Preview("The ask") {
    let household = HouseholdStore.preview()
    ReminderAskCard()
        .environment(ReminderStore.preview)
        .environment(household)
        .padding()
}

#Preview("On Family") {
    let household = HouseholdStore.preview()
    List { ReminderSettingsSection() }
        .environment(ReminderStore.preview)
        .environment(household)
}
