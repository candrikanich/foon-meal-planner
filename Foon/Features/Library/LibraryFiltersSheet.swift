import SwiftUI

/// The filter choices in a sheet. Each chip toggles; chosen ones narrow together (#338).
struct LibraryFiltersSheet: View {
    @Binding var selection: Set<LibraryFilter>
    let dismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Filters").font(.foonTitle).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !selection.isEmpty {
                        Button("Clear") { selection = [] }
                            .buttonStyle(.borderless)
                            .tint(Palette.paprika)
                            .accessibilityHint(Text("Turns every filter off"))
                    }
                    Button("Done", action: dismiss).buttonStyle(.pill(.tinted))
                }
                Text(LibraryText.filtersSummary(selection)).font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(LibraryFilter.allCases) { filter in
                        let isOn = selection.contains(filter)
                        Button {
                            if isOn { selection.remove(filter) } else { selection.insert(filter) }
                        } label: {
                            Text(filter.title)
                        }
                        .buttonStyle(FilterChipStyle(isOn: isOn))
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            }
            .padding(Metrics.cardPadding)
        }
        .background(Palette.cream)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Every chip fills its grid cell and centres its text, so the set reads as even.
private struct FilterChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.foonHeadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(isOn ? Palette.onPaprika : Palette.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Metrics.minTapHeight)
            .background(Capsule().fill(isOn ? Palette.paprika : Palette.cardSurface))
            .overlay(Capsule().strokeBorder(isOn ? Palette.paprika : Palette.ink.opacity(0.25), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

#Preview("Filters") {
    @Previewable @State var filters: Set<LibraryFilter> = [.favorites, .quick]
    Color.clear.sheet(isPresented: .constant(true)) { LibraryFiltersSheet(selection: $filters) {} }
}

#Preview("Filters dark AX3") {
    @Previewable @State var filters: Set<LibraryFilter> = [.backup]
    Color.clear.sheet(isPresented: .constant(true)) { LibraryFiltersSheet(selection: $filters) {} }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
