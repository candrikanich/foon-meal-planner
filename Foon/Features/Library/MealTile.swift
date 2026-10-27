import SwiftUI

/// One meal on the library grid: photo, name, and effort, made-by, and allergy indicators.
struct MealTile: View {
    let entry: LibraryEntry
    let madeBy: Member?
    let photoURL: (String) async throws -> URL

    @State private var url: URL?

    private var meal: LibraryMeal { entry.meal }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            photo
            Text(meal.name)
                .font(.foonHeadline)
                .foregroundStyle(Palette.ink)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            indicators
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.cardSurface))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LibraryText.accessibilityLabel(entry, madeBy: madeBy))
        .task(id: meal.photoPath) {
            guard let path = meal.photoPath else { url = nil; return }
            url = try? await photoURL(path)
        }
    }

    private var photo: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholder
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if meal.status == .trial {
                    Chip(text: String(localized: "Trying"), tint: Palette.paprika)
                        .background(Capsule().fill(Palette.cardSurface))
                        .padding(6)
                }
            }
    }

    private var placeholder: some View {
        Palette.herb.opacity(0.14)
            .overlay(Image(systemName: "fork.knife").font(.largeTitle).foregroundStyle(Palette.herb))
    }

    private var indicators: some View {
        HStack(spacing: 6) {
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
        return parts.joined(separator: ", ")
    }
}

#Preview {
    let entries = LibraryQuery.entries(
        meals: LibraryMeal.sampleLibrary, history: [],
        allergies: [MemberAllergies(memberID: UUID(), firstName: "Nora", allergens: [.milk])], favorites: []
    )
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(entries) { entry in
                MealTile(entry: entry, madeBy: entry.meal.madeByMemberID.map { _ in Member.sampleFamily[1] },
                         photoURL: { _ in throw URLError(.fileDoesNotExist) })
            }
        }
        .padding()
    }
    .background(Palette.cream)
}
