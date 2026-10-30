import SwiftUI

/// Kitchen equipment and the start-cooking nudge (docs/spec.md → Kitchen equipment, Cooking start time). Planners only.
struct KitchenView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var isSaving = false

    private var settings: HouseholdSettings { store.household?.planningSettings ?? HouseholdSettings() }

    var body: some View {
        Form {
            Section {
                ForEach(KitchenEquipment.allCases, id: \.self) { equipment in
                    Toggle(equipment.title, isOn: Binding(
                        get: { !settings.missingEquipment.contains(equipment) },
                        set: { has in
                            var changed = settings
                            if has { changed.missingEquipment.remove(equipment) } else { changed.missingEquipment.insert(equipment) }
                            save(changed)
                        }
                    ))
                }
            } header: {
                Text("What you have")
            } footer: {
                Text("Turn off what you don't have, and Foon stops suggesting dishes that need it. They stay in your library, and anything the family asks for still lands.")
            }

            Section {
                Toggle("Show when to start cooking", isOn: Binding(
                    get: { settings.showsStartCooking },
                    set: { shows in
                        var changed = settings
                        changed.showsStartCooking = shows
                        save(changed)
                    }
                ))
            } footer: {
                Text("This Week counts back from dinner time. Set a dish's time to cook in its editor; without one, Foon estimates.")
            }

            if let message = store.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        // One save at a time: each sends the whole list, so a second tap mustn't start from the one before it.
        .disabled(isSaving)
        .navigationTitle("Kitchen")
        .onAppear { store.clearError() }
    }

    private func save(_ changed: HouseholdSettings) {
        isSaving = true
        Task {
            await store.updateSettings(changed)
            isSaving = false
        }
    }
}

#Preview("Everything") {
    let store = HouseholdStore.preview()
    NavigationStack { KitchenView() }
        .environment(store)
        .task { await store.load() }
}

#Preview("No grill") {
    var settings = HouseholdSettings()
    settings.missingEquipment = [.grill]
    settings.showsStartCooking = false
    var household = Household.sample
    household.settings = settings
    let store = HouseholdStore.preview(household: household)
    return NavigationStack { KitchenView() }
        .environment(store)
        .task { await store.load() }
}
