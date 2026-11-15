import SwiftUI

/// Foon's palette (docs/spec.md → Brand: tomato/paprika primary, cream background, deep green accent).
/// Each color has light and dark values in the asset catalog; every text pairing meets WCAG AA.
enum Palette {
    /// Primary: buttons, tint, the "tonight" highlight.
    static let paprika = Color("Paprika")
    /// Text and icons placed on paprika.
    static let onPaprika = Color("OnPaprika")
    /// App background.
    static let cream = Color("Cream")
    /// Cards and sheets.
    static let cardSurface = Color("CardSurface")
    /// Accent: reason chips, success, "home".
    static let herb = Color("Herb")
    /// Allergy flags and warnings.
    static let caution = Color("Caution")
    /// Primary text on cream.
    static let ink = Color("Ink")
}

/// The spacing scale (docs/design-system.md → Spacing). Pick a step; don't invent a number between two.
enum Spacing {
    /// Between a title and its own subtitle.
    static let xxs: CGFloat = 2
    /// Inside a chip or pill; icon to label.
    static let xs: CGFloat = 4
    /// Between related items: chips in a row, buttons side by side.
    static let s: CGFloat = 8
    /// Between lines of a card or row.
    static let m: CGFloat = 12
    /// Card padding and screen margins.
    static let l: CGFloat = 16
    /// Between cards and sections.
    static let xl: CGFloat = 24
    /// Above a screen's first section, around empty states.
    static let xxl: CGFloat = 32
}

/// Corner radii (docs/design-system.md → Shape). Pills and avatars are capsules or circles, not a radius.
enum Radius {
    /// Thumbnails, swatches, small tiles.
    static let small: CGFloat = 8
    /// Chips that may wrap, text fields, inner panels.
    static let medium: CGFloat = 14
    /// Cards and sheets' grouped content.
    static let card: CGFloat = 20
}

/// Type styles, all built on Dynamic Type text styles so they scale with the reader's setting.
/// SF Pro throughout (the Quiet Kitchen redesign dropped SF Pro Rounded): weight, not shape, carries hierarchy.
extension Font {
    static let foonLargeTitle = Font.system(.largeTitle).weight(.bold)
    static let foonTitle = Font.system(.title2).weight(.bold)
    static let foonHeadline = Font.system(.headline)
    static let foonBody = Font.body
    static let foonCaption = Font.caption.weight(.medium)
}

/// A small rounded label: effort, reason, and badge chips.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Palette.herb

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
        }
        .labelStyle(.titleAndIcon)
        .font(.foonCaption)
        .foregroundStyle(tint)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        // A capsule on one line; a long one wraps, and a capsule's ends would cut into its text.
        .background(RoundedRectangle(cornerRadius: Radius.medium).fill(tint.opacity(0.14)))
    }
}

/// A dish's allergy flags and its note, in a row that offers the dish. A VoiceOver label on that row reads `check.texts`.
struct AllergyChips: View {
    let check: AllergyCheck

    var body: some View {
        ForEach(check.flags, id: \.self) { flag in
            Chip(text: flag.summary, systemImage: "exclamationmark.triangle.fill", tint: Palette.caution)
        }
        if let note = check.note {
            Chip(text: note, systemImage: "questionmark.circle", tint: Palette.caution)
        }
    }
}

#Preview("Allergy chips") {
    let flag = AllergyFlag(trigger: .allergen(.treeNuts),
                           members: ["Nora", "Owen", "Grandma Josephine"].map { AllergyFlag.Member(id: UUID(), firstName: $0) },
                           ingredients: ["almonds"])
    VStack(alignment: .leading, spacing: 4) {
        AllergyChips(check: AllergyCheck(flags: [flag], note: String(localized: "No ingredients for Cornbread yet, so allergies can't be checked")))
    }
    .padding()
    .frame(width: 320)
    .dynamicTypeSize(.accessibility2)
}

#Preview("Palette") {
    let swatches: [(String, Color)] = [
        ("Paprika", Palette.paprika), ("Cream", Palette.cream), ("Card", Palette.cardSurface),
        ("Herb", Palette.herb), ("Caution", Palette.caution), ("Ink", Palette.ink)
    ]
    VStack(alignment: .leading, spacing: 12) {
        Text("Foon").font(.foonLargeTitle).foregroundStyle(Palette.ink)
        ForEach(swatches, id: \.0) { name, color in
            HStack {
                RoundedRectangle(cornerRadius: 8).fill(color).frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                Text(name).font(.foonHeadline)
            }
        }
        HStack {
            Chip(text: "Nora's favorite", systemImage: "heart.fill")
            Chip(text: "Contains milk", systemImage: "exclamationmark.triangle.fill", tint: Palette.caution)
        }
    }
    .padding()
    .background(Palette.cream)
}
