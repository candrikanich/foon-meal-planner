import SwiftUI

/// Food rules (docs/spec.md → Food rules): what the household skips, and when. Planners only. Foon goes by names and
/// ingredients, so this view says what that can and can't promise.
struct FoodRulesView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var isSaving = false

    private var rules: [FoodRule] { store.household?.planningSettings.foodRules ?? [] }

    var body: some View {
        Form {
            Section {
                ForEach(FoodRule.Avoid.allCases, id: \.self) { avoid in
                    Picker(avoid.title, selection: Binding(
                        get: { rules.first { $0.avoid == avoid }?.nights },
                        set: { save(avoid, nights: $0) }
                    )) {
                        Text("No rule").tag(FoodRule.Nights?.none)
                        ForEach(FoodRule.Nights.allCases, id: \.self) { nights in
                            Text(nights.title).tag(FoodRule.Nights?.some(nights))
                        }
                    }
                }
            } header: {
                Text("What you skip")
            } footer: {
                Text("Fish doesn't count as meat here. Foon won't plan a dish on those nights if its name or ingredients look like they break the rule. Swap lists what it held back, so you can pick one anyway, and anything the family asks for still lands with a note on the card.")
            }

            Section {
                Text("Foon reads dish names and ingredients, so it can miss what they don't say, and it can't promise a dish is free of anything. Kosher and halal depend on how food is made and prepared, so Foon can't check them.")
                    .font(.foonCaption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("What this can't do")
            }

            if let message = store.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .disabled(isSaving)
        .navigationTitle("Food rules")
        .onAppear { store.clearError() }
    }

    private func save(_ avoid: FoodRule.Avoid, nights: FoodRule.Nights?) {
        isSaving = true
        Task {
            await store.setFoodRule(avoid, nights: nights)
            isSaving = false
        }
    }
}

#Preview("None") {
    let store = HouseholdStore.preview()
    NavigationStack { FoodRulesView() }
        .environment(store)
        .task { await store.load() }
}

#Preview("Fridays in Lent") {
    var settings = HouseholdSettings()
    settings.foodRules = [FoodRule(avoid: .meat, nights: .lentFridays)]
    var household = Household.sample
    household.settings = settings
    let store = HouseholdStore.preview(household: household)
    return NavigationStack { FoodRulesView() }
        .environment(store)
        .task { await store.load() }
}
