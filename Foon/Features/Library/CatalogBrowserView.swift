import SwiftUI

/// Browse ideas: Foon's starter dishes by category. Planners copy a dish into the library to make it
/// their own; everyone else can look.
struct CatalogBrowserView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let canAdd: Bool

    var body: some View {
        NavigationStack {
            List {
                if let message = library.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                ForEach(library.catalogSections) { section in
                    Section(section.category) {
                        ForEach(section.dishes) { dish in
                            CatalogDishRow(dish: dish, canAdd: canAdd)
                        }
                    }
                }
            }
            .overlay {
                if library.catalog.isEmpty {
                    ContentUnavailableView("No ideas yet", systemImage: "sparkles",
                                           description: Text("Pull to refresh the library, then try again."))
                }
            }
            .navigationTitle("Browse ideas")
            .onAppear { library.clearError() }
            .onDisappear { library.clearError() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// A starter dish with its first few ingredients and an Add button, or a check once it's in the library.
struct CatalogDishRow: View {
    @Environment(LibraryStore.self) private var library
    let dish: CatalogDish
    let canAdd: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dish.name).font(.body.weight(.medium))
                if !dish.ingredients.isEmpty {
                    Text(dish.ingredients.prefix(4).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        if library.isInLibrary(dish) {
            Label("In your library", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(Palette.herb)
        } else if canAdd {
            Button("Add") { Task { await library.add(dish) } }
                .buttonStyle(.bordered)
                .tint(Palette.paprika)
                .disabled(library.addingDishIDs.contains(dish.id))
                .accessibilityLabel("Add \(dish.name) to your library")
        }
    }
}

#Preview {
    let library = LibraryStore(householdID: Household.sample.id, client: .preview())
    CatalogBrowserView(canAdd: true)
        .environment(library)
        .task { await library.load(members: Member.sampleFamily) }
}
