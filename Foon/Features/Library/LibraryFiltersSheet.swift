import SwiftUI

/// The filter choices in a sheet. One at a time; tapping the chosen one again clears it.
struct LibraryFiltersSheet: View {
    @Binding var selection: LibraryFilter?
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
                    Button("Done", action: dismiss).buttonStyle(.pill(.tinted))
                }
                Text(LibraryText.filtersSummary(selection)).font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(LibraryFilter.allCases) { filter in
                        let isOn = selection == filter
                        Button {
                            selection = isOn ? nil : filter
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
    @Previewable @State var filter: LibraryFilter? = .favorites
    Color.clear.sheet(isPresented: .constant(true)) { LibraryFiltersSheet(selection: $filter) {} }
}

#Preview("Filters dark AX3") {
    @Previewable @State var filter: LibraryFilter? = .backup
    Color.clear.sheet(isPresented: .constant(true)) { LibraryFiltersSheet(selection: $filter) {} }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
