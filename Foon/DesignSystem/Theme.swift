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

/// Type styles, all built on Dynamic Type text styles so they scale with the reader's setting.
/// Headings use the rounded design for Foon's friendly voice; body text stays default for reading.
extension Font {
    static let foonLargeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let foonTitle = Font.system(.title2, design: .rounded).weight(.bold)
    static let foonHeadline = Font.system(.headline, design: .rounded)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // A capsule on one line; a long one wraps, and a capsule's ends would cut into its text.
        .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.14)))
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
