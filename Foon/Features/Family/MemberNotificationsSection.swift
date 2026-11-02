import SwiftUI

/// Member detail's "Notifications" row: their own preset, or the family's. Whoever may change it (themselves if an adult, a
/// parent for a kid or an unclaimed profile) opens the choices; everyone else just reads it.
struct MemberNotificationsSection: View {
    @Environment(HouseholdStore.self) private var store
    let member: Member

    private var family: HouseholdSettings.NotificationPreset {
        store.household?.planningSettings.notificationPreset ?? .balanced
    }

    var body: some View {
        Section {
            if store.canSetPreset(member) {
                NavigationLink {
                    MemberPresetPicker(member: member, family: family)
                } label: {
                    LabeledContent("Notifications", value: MemberPresetRules.title(for: member, family: family))
                }
            } else {
                LabeledContent("Notifications", value: MemberPresetRules.title(for: member, family: family))
            }
        } footer: {
            if member.ageGroup == .kid {
                Text("A kid's can be quieter than the family's, never louder. Quiet hours and the weekly limit still apply.")
            }
        }
    }
}

/// Same as family, then each preset with what it sends.
struct MemberPresetPicker: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let member: Member
    let family: HouseholdSettings.NotificationPreset
    @State private var saving = false

    /// As it counts: a kid's saved above the family's checks Same as family, as the row says.
    private var current: HouseholdSettings.NotificationPreset? {
        MemberPresetRules.selected(for: store.members.first { $0.id == member.id } ?? member, family: family)
    }

    var body: some View {
        List {
            Section {
                option(nil, title: String(localized: "Same as family (\(family.title))",
                                          comment: "A person's notifications follow the household's preset"),
                       summary: family.summary)
            }
            Section {
                ForEach(MemberPresetRules.choices(for: member, family: family), id: \.self) { preset in
                    option(preset, title: preset.title, summary: preset.summary)
                }
            }
            if let message = store.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        }
        .navigationTitle("Notifications")
        .disabled(saving)
    }

    private func option(_ preset: HouseholdSettings.NotificationPreset?, title: String, summary: String) -> some View {
        Button {
            Task {
                saving = true
                if await store.setPreset(preset, for: member) { dismiss() }
                saving = false
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    Text(summary).font(.foonCaption).foregroundStyle(.secondary)
                }
                Spacer()
                if current == preset {
                    Image(systemName: "checkmark").foregroundStyle(Palette.paprika).accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(current == preset ? .isSelected : [])
    }
}

#Preview("Their own") {
    let store = HouseholdStore.preview()
    NavigationStack {
        List { MemberNotificationsSection(member: Member.sampleFamily[0]) }
    }
    .environment(store)
    .task { await store.load() }
}

#Preview("A kid, set by a parent") {
    let store = HouseholdStore.preview()
    NavigationStack {
        List { MemberNotificationsSection(member: Member.sampleFamily[4]) }
    }
    .environment(store)
    .task { await store.load() }
}

#Preview("Choices for a kid") {
    let store = HouseholdStore.preview()
    NavigationStack {
        MemberPresetPicker(member: Member.sampleFamily[4], family: .balanced)
    }
    .environment(store)
    .task { await store.load() }
}
