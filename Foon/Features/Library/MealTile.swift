import SwiftUI

/// One meal on the library grid: name, effort, made-by, and allergy indicators.
struct MealTile: View {
    let entry: LibraryEntry
    let madeBy: Member?

    private var meal: LibraryMeal { entry.meal }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meal.name)
                .font(.foonHeadline)
                .foregroundStyle(Palette.ink)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            indicators
            if let note = entry.uncheckedNote {
                Text(note)
                    .font(.foonCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.cardSurface))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LibraryText.accessibilityLabel(entry, madeBy: madeBy))
    }

    private var indicators: some View {
        HStack(spacing: 6) {
            if meal.status == .trial {
                Chip(text: String(localized: "Trying"), tint: Palette.paprika)
            }
            if meal.tags.contains(.quick) {
                Image(systemName: "hare").foregroundStyle(.secondary)
            }
            if meal.tags.contains(.slowCooker) {
                Image(systemName: "timer").foregroundStyle(.secondary)
            }
            if meal.tags.contains(.grill) {
                Image(systemName: "flame").foregroundStyle(.secondary)
            }
            if !entry.flags.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.caution)
            }
            if meal.ingredients.isEmpty {
                // The spec's reminder for quick-added meals: ingredients can come later.
                Chip(text: String(localized: "Add ingredients"), systemImage: "plus", tint: Palette.paprika)
            }
            Spacer(minLength: 0)
            if let madeBy {
                MemberAvatar(member: madeBy, size: 22)
            }
        }
        .font(.caption)
        .frame(minHeight: 22)
    }
}

/// Words for library tiles, kept out of the view so they're testable and localizable.
enum LibraryText {
    static func accessibilityLabel(_ entry: LibraryEntry, madeBy: Member?) -> String {
        var parts = [entry.meal.name]
        if entry.meal.status == .trial { parts.append(String(localized: "Trying")) }
        if entry.meal.status == .archived { parts.append(String(localized: "Archived")) }
        if entry.meal.tags.contains(.quick) { parts.append(String(localized: "Quick")) }
        if let madeBy { parts.append(String(localized: "Made by \(madeBy.firstName)")) }
        parts.append(contentsOf: entry.flags.map(\.summary))
        if let note = entry.uncheckedNote { parts.append(note) }
        if entry.meal.ingredients.isEmpty { parts.append(String(localized: "Add ingredients")) }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    let entries = LibraryQuery.entries(
        meals: LibraryMeal.sampleLibrary, library: LibraryMeal.sampleLibrary, history: [],
        allergies: [MemberAllergies(memberID: UUID(), firstName: "Nora", allergens: [.milk])], favorites: []
    )
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(entries) { entry in
                MealTile(entry: entry, madeBy: entry.meal.madeByMemberID.map { _ in Member.sampleFamily[1] })
            }
        }
        .padding()
    }
    .background(Palette.cream)
}
