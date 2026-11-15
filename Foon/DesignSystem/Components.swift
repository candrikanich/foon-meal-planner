import SwiftUI

/// Quiet Kitchen layout constants beyond the Spacing and Radius scales.
enum Metrics {
    static let minTapHeight: CGFloat = 44
}

extension View {
    /// A flat card on cream: the Quiet Kitchen surface for heroes and grouped content.
    func foonCard(padding: CGFloat = Spacing.l) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cardSurface, in: .rect(cornerRadius: Radius.card, style: .continuous))
    }

    /// For a system `List` or `Form`: cream behind it, paprika controls. Pair it with `foonRows()` on its content,
    /// because a row's background can only be set from inside the list.
    func foonGrouped() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Palette.cream)
            .tint(Palette.paprika)
    }

    /// For a `List` or `Form`'s content (wrap it in a `Group`): card-surface rows and headline section headers.
    /// In dark mode the system row gray is nearly the dark cream, so rows need the card color to stand apart.
    func foonRows() -> some View {
        self.listRowBackground(Palette.cardSurface)
            .headerProminence(.increased)
    }
}

/// Capsule buttons: `prominent` for the one main action on a screen or card, `tinted` for the ones beside it.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case prominent, tinted }

    var kind: Kind = .prominent
    var tint: Color = Palette.paprika
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration, kind: kind, tint: tint, fullWidth: fullWidth)
    }

    // A ButtonStyle can't read the environment itself; a view inside it can.
    private struct PillLabel: View {
        let configuration: Configuration
        let kind: Kind
        let tint: Color
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.foonHeadline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(kind == .prominent ? Palette.onPaprika : tint)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Metrics.minTapHeight)
                .background(Capsule().fill(kind == .prominent ? tint : tint.opacity(0.14)))
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }

    static func pill(_ kind: PillButtonStyle.Kind, tint: Color = Palette.paprika, fullWidth: Bool = false) -> PillButtonStyle {
        PillButtonStyle(kind: kind, tint: tint, fullWidth: fullWidth)
    }
}

/// The night's effort as a pill. A planner gets a menu to pick it; anyone else just reads it.
/// Ink on a tertiary fill, not secondary-on-gray: the Figma pill was too faint to read.
struct EffortMenu: View {
    let effort: NightEffort
    /// Nil when the viewer can't change the effort.
    var onChange: ((NightEffort) -> Void)?

    var body: some View {
        if let onChange {
            // Buttons, not a Picker over a Binding: passing the callback as a Binding setter crashed the
            // Xcode 26.6 compiler in IRGen (CI, PR #341).
            Menu {
                ForEach(NightEffort.ordered, id: \.self) { option in
                    Button { onChange(option) } label: {
                        Label(DayCardText.effortLabel(option),
                              systemImage: option == effort ? "checkmark" : option.symbolName)
                    }
                    .accessibilityAddTraits(option == effort ? .isSelected : [])
                }
            } label: {
                pill(showsChevron: true)
            }
            .accessibilityLabel(String(localized: "Effort"))
            .accessibilityValue(DayCardText.effortLabel(effort))
        } else {
            pill(showsChevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Effort"))
                .accessibilityValue(DayCardText.effortLabel(effort))
        }
    }

    private func pill(showsChevron: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(DayCardText.effortLabel(effort))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .font(.foonCaption)
        .foregroundStyle(effort == .event ? Palette.paprika : Palette.ink)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(Capsule().fill(.fill.tertiary))
        .contentShape(Capsule())
    }
}

/// Text tabs with a paprika underline under the chosen one, over a hairline: "This week / Next week".
struct UnderlineTabs<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value
    @Namespace private var underline

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.xl) {
            ForEach(options) { option in
                tab(option)
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { Divider() }
    }

    private func tab(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            withAnimation(.snappy) { selection = option.value }
        } label: {
            VStack(spacing: Spacing.s) {
                Text(option.title)
                    .font(.foonHeadline)
                    .foregroundStyle(isSelected ? Palette.ink : .secondary)
                if isSelected {
                    Capsule().fill(Palette.paprika).frame(height: 2)
                        .matchedGeometryEffect(id: "underline", in: underline)
                } else {
                    Color.clear.frame(height: 2)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: Metrics.minTapHeight, alignment: .bottom)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A section title with optional actions on the right. When the actions don't fit beside the title
/// they drop below it, instead of squeezing it (the Figma Ingredients header did).
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                titleText
                Spacer(minLength: Spacing.s)
                trailing
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                titleText
                HStack(spacing: Spacing.s) { trailing }
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.foonHeadline)
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

private struct ComponentsPreview: View {
    @State private var nextWeek = false
    @State private var effort = NightEffort.rushed

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                UnderlineTabs(options: [.init(value: false, title: String(localized: "This week")),
                                        .init(value: true, title: String(localized: "Next week"))],
                              selection: $nextWeek)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(verbatim: "Tonight").font(.foonHeadline).foregroundStyle(Palette.paprika)
                        Spacer()
                        EffortMenu(effort: effort) { effort = $0 }
                    }
                    Text(verbatim: "Tacos").font(.foonLargeTitle).foregroundStyle(Palette.ink)
                    HStack {
                        Button(String(localized: "View meal")) {}.buttonStyle(.pill(.prominent, fullWidth: true))
                        Button(String(localized: "Swap")) {}.buttonStyle(.pill(.tinted))
                        Button(String(localized: "More")) {}.buttonStyle(.pill(.tinted))
                    }
                }
                .foonCard()
                SectionHeader(title: String(localized: "Ingredients")) {
                    Button(String(localized: "Add all to list")) {}.buttonStyle(.pill(.tinted))
                }
                SectionHeader(String(localized: "Staples running low"))
                HStack {
                    EffortMenu(effort: .full)
                    EffortMenu(effort: .event)
                    Button(String(localized: "Start cooking")) {}.buttonStyle(.pill).disabled(true)
                }
            }
            .padding()
        }
        .background(Palette.cream)
    }
}

#Preview("Components") { ComponentsPreview() }
#Preview("Components · Dark") { ComponentsPreview().preferredColorScheme(.dark) }
#Preview("Components · AX3") { ComponentsPreview().dynamicTypeSize(.accessibility3) }
