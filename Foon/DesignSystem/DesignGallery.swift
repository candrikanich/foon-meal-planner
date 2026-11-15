#if DEBUG || FOON_QA
import SwiftUI

/// Every Quiet Kitchen token and component on one screen (docs/design-system.md), so the design can be reviewed on a
/// phone without Figma. Compiled into Debug and Foon QA (Staging) only; family Foon never has it.
/// Gallery samples are fixed design specimens, not app copy, so they use `verbatim` and skip the string catalog.
struct DesignGallery: View {
    @State private var scheme: ColorScheme?
    @State private var largeText = false
    @State private var week = 0
    @State private var effort = NightEffort.rushed

    var body: some View {
        List {
            Group {
                Section {
                    Picker(selection: $scheme) {
                        Text(verbatim: "System").tag(ColorScheme?.none)
                        Text(verbatim: "Light").tag(ColorScheme?.some(.light))
                        Text(verbatim: "Dark").tag(ColorScheme?.some(.dark))
                    } label: { Text(verbatim: "Appearance") }
                    Toggle(isOn: $largeText) { Text(verbatim: "Accessibility text size") }
                } header: { Text(verbatim: "Preview") }

                Section { colors } header: { Text(verbatim: "Color") }
                Section { type } header: { Text(verbatim: "Type") }
                Section { spacing } header: { Text(verbatim: "Spacing") }
                Section { chips } header: { Text(verbatim: "Chips") }
                Section { buttons } header: { Text(verbatim: "Buttons") }
                Section {
                    UnderlineTabs(options: [.init(value: 0, title: "This week"), .init(value: 1, title: "Next week")],
                                  selection: $week)
                    SectionHeader(title: "Ingredients") {
                        Button { } label: { Text(verbatim: "Add all to list") }.buttonStyle(.pill(.tinted))
                    }
                } header: { Text(verbatim: "Navigation and headers") }
                Section {
                    LabeledContent { Text(verbatim: "Oven, slow cooker") } label: { Text(verbatim: "Kitchen") }
                    Toggle(isOn: .constant(true)) { Text(verbatim: "Show when to start cooking") }
                    NavigationLink { Text(verbatim: "Detail") } label: { Text(verbatim: "A row that opens a screen") }
                    Button(role: .destructive) { } label: { Text(verbatim: "Delete household") }
                } header: { Text(verbatim: "Grouped rows") } footer: {
                    Text(verbatim: "Footers explain a section in a sentence or two.")
                }
            }
            .foonRows()

            Section {
                card
                ContentUnavailableView {
                    Label { Text(verbatim: "No dishes yet") } icon: { Image(systemName: "fork.knife") }
                } description: {
                    Text(verbatim: "Add the dinners your family already makes.")
                } actions: {
                    Button { } label: { Text(verbatim: "Add a dish") }.buttonStyle(.pill)
                }
            } header: { Text(verbatim: "Cards and empty states") }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .headerProminence(.increased)
        }
        .foonGrouped()
        .navigationTitle(Text(verbatim: "Design gallery"))
        .preferredColorScheme(scheme)
        .dynamicTypeSize(largeText ? .accessibility2 ... .accessibility2 : .xSmall ... .accessibility5)
    }

    private var colors: some View {
        let swatches: [(String, String, Color)] = [
            ("Paprika", "Primary actions, tint, tonight", Palette.paprika),
            ("On paprika", "Text on paprika", Palette.onPaprika),
            ("Cream", "Screen background", Palette.cream),
            ("Card", "Cards and rows", Palette.cardSurface),
            ("Herb", "Reasons, success, home", Palette.herb),
            ("Caution", "Allergies and warnings", Palette.caution),
            ("Ink", "Primary text", Palette.ink)
        ]
        return ForEach(swatches, id: \.0) { name, role, color in
            HStack(spacing: Spacing.m) {
                RoundedRectangle(cornerRadius: Radius.small).fill(color).frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(.quaternary))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(verbatim: name).font(.foonHeadline)
                    Text(verbatim: role).font(.foonCaption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var type: some View {
        Group {
            Text(verbatim: "Large title · bold").font(.foonLargeTitle)
            Text(verbatim: "Title · bold").font(.foonTitle)
            Text(verbatim: "Headline").font(.foonHeadline)
            Text(verbatim: "Body: the text people read.").font(.foonBody)
            Text(verbatim: "Caption · medium").font(.foonCaption)
            Text(verbatim: "Secondary text").font(.foonBody).foregroundStyle(.secondary)
        }
        .foregroundStyle(Palette.ink)
    }

    private var spacing: some View {
        let steps: [(String, CGFloat)] = [("xxs", Spacing.xxs), ("xs", Spacing.xs), ("s", Spacing.s), ("m", Spacing.m),
                                          ("l", Spacing.l), ("xl", Spacing.xl), ("xxl", Spacing.xxl)]
        return ForEach(steps, id: \.0) { name, value in
            HStack(spacing: Spacing.m) {
                Text(verbatim: "\(name) · \(Int(value))").font(.foonCaption.monospacedDigit()).frame(width: 64, alignment: .leading)
                Capsule().fill(Palette.paprika).frame(width: value * 3, height: 8)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: Spacing.s) {
            Chip(text: "Nora's favorite", systemImage: "heart.fill")
            Chip(text: "Contains milk", systemImage: "exclamationmark.triangle.fill", tint: Palette.caution)
            EffortMenu(effort: effort) { effort = $0 }
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Button { } label: { Text(verbatim: "Build my week") }.buttonStyle(.pill(.prominent, fullWidth: true))
            HStack(spacing: Spacing.s) {
                Button { } label: { Text(verbatim: "Swap") }.buttonStyle(.pill(.tinted))
                Button { } label: { Text(verbatim: "More") }.buttonStyle(.pill(.tinted))
                Button { } label: { Text(verbatim: "Off") }.buttonStyle(.pill).disabled(true)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text(verbatim: "Tonight").font(.foonHeadline).foregroundStyle(Palette.paprika)
                Spacer()
                EffortMenu(effort: effort)
            }
            Text(verbatim: "Sheet-pan chicken fajitas").font(.foonTitle).foregroundStyle(Palette.ink)
            Text(verbatim: "Start cooking at 5:15").font(.foonBody).foregroundStyle(.secondary)
            HStack(spacing: Spacing.s) {
                Button { } label: { Text(verbatim: "View meal") }.buttonStyle(.pill(.prominent, fullWidth: true))
                Button { } label: { Text(verbatim: "Swap") }.buttonStyle(.pill(.tinted))
            }
        }
        .foonCard()
    }
}

#Preview("Gallery") { NavigationStack { DesignGallery() } }
#Preview("Gallery · Dark") { NavigationStack { DesignGallery() }.preferredColorScheme(.dark) }
#endif
