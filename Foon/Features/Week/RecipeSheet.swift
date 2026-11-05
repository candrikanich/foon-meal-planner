import SwiftUI

/// A night's recipe straight from its day card (#267), for whoever's cooking. Meal detail carries Start cooking.
struct RecipeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mealID: UUID
    let canEdit: Bool

    var body: some View {
        NavigationStack {
            MealDetailView(mealID: mealID, canEdit: canEdit)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

#Preview("Member") {
    let household = HouseholdStore.preview()
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    RecipeSheet(mealID: LibraryMeal.sampleLibrary[0].id, canEdit: false)
        .environment(library)
        .environment(household)
        .environment(SubscriptionStore(householdID: Household.sample.id, client: .preview(), storeKit: .preview))
        .task {
            await household.load()
            await library.load(members: Member.sampleFamily)
        }
}
