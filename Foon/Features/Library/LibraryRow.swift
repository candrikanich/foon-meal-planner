import SwiftUI

/// One meal on the Library list: name, what kind of meal it is, and anything needing attention.
struct LibraryRow: View {
    let entry: LibraryEntry
    let madeBy: Member?

    @Environment(\.dynamicTypeSize) private var typeSize

    private var meal: LibraryMeal { entry.meal }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !typeSize.isAccessibilitySize { leading }
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                if let meta = LibraryText.meta(of: meal) {
                    Text(meta).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                attention
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(minHeight: Metrics.minTapHeight)
                .accessibilityHidden(true)
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LibraryText.accessibilityLabel(entry, madeBy: madeBy))
    }

    @ViewBuilder
    private var leading: some View {
        if let madeBy {
            MemberAvatar(member: madeBy, size: 36)
        } else {
            Image(systemName: "fork.knife")
                .font(.footnote)
                .foregroundStyle(Palette.herb)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Palette.herb.opacity(0.14)))
        }
    }

    @ViewBuilder
    private var attention: some View {
        if !entry.flags.isEmpty {
            Label(String(localized: "Allergy flag"), systemImage: "exclamationmark.triangle.fill")
                .font(.foonCaption)
                .foregroundStyle(Palette.caution)
        }
        if let note = entry.uncheckedNote {
            Text(note).font(.foonCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        }
        if meal.ingredients.isEmpty {
            // The spec's reminder for quick-added meals: ingredients can come later.
            Chip(text: String(localized: "Add ingredients"), systemImage: "plus", tint: Palette.paprika)
        }
    }
}

/// Words for library rows, kept out of the view so they're testable and localizable.
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

    /// The row's second line: whether it's on trial or archived, then its tags, as "Quick · Slow cooker".
    static func meta(of meal: LibraryMeal) -> String? {
        var parts: [String] = []
        switch meal.status {
        case .trial: parts.append(String(localized: "Trying"))
        case .archived: parts.append(String(localized: "Archived"))
        case .retired: parts.append(String(localized: "Retired"))
        case .active: break
        }
        parts.append(contentsOf: MealTag.allCases.filter(meal.tags.contains).map(\.title))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func count(_ meals: Int) -> String {
        meals == 1 ? String(localized: "1 meal") : String(localized: "\(meals) meals")
    }

    /// The Filters pill names what's applied, so a separate label for it isn't needed.
    static func filtersPill(_ filter: LibraryFilter?) -> String {
        guard let filter else { return String(localized: "Filters") }
        return String(localized: "Filters · \(filter.title)")
    }

    static func filtersSummary(_ filter: LibraryFilter?) -> String {
        guard let filter else { return String(localized: "Showing meals in your rotation") }
        return String(localized: "Showing \(filter.title.localizedLowercase)")
    }
}

private struct LibraryRowsPreview: View {
    var body: some View {
        var long = LibraryMeal.sampleLibrary[0]
        long.name = "Slow-braised short ribs with creamy parmesan polenta and roasted garlic greens"
        let meals = LibraryMeal.sampleLibrary + [long]
        let entries = LibraryQuery.entries(
            meals: meals, library: meals, history: [],
            allergies: [MemberAllergies(memberID: UUID(), firstName: "Nora", allergens: [.milk])], favorites: []
        )
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    LibraryRow(entry: entry, madeBy: entry.meal.madeByMemberID.map { _ in Member.sampleFamily[1] })
                    Divider()
                }
            }
            .background(Palette.cardSurface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
            .padding()
        }
        .background(Palette.cream)
    }
}

#Preview("Rows") { LibraryRowsPreview() }
#Preview("Rows dark") { LibraryRowsPreview().preferredColorScheme(.dark) }
#Preview("Rows AX3") { LibraryRowsPreview().dynamicTypeSize(.accessibility3) }
