import SwiftUI

/// "Your year in dinners is ready" on This Week, from December 26 through January 7 by the household's day, until
/// this device closes it for that year. Only once the year has loaded with something to say: a failed load or a year
/// with no dinners logged just leaves it out.
struct YearRecapCardSection: View {
    @Environment(HouseholdStore.self) private var household
    @AppStorage("foon.dismissedYearRecaps") private var dismissedRaw = ""
    let store: YearRecapStore
    let today: CalendarDay

    private var dismissed: [String] { dismissedRaw.split(separator: ",").map(String.init) }

    var body: some View {
        if let year = YearRecap.cardYear(today: today), store.recap?.year == year,
           let householdID = household.household?.id,
           !dismissed.contains(YearRecap.dismissalKey(household: householdID, year: year)) {
            YearRecapReadyCard(year: year) {
                // A couple of years is plenty: the card only shows for two weeks a year.
                let key = YearRecap.dismissalKey(household: householdID, year: year)
                dismissedRaw = (dismissed.suffix(3) + [key]).joined(separator: ",")
            }
        }
    }
}

struct YearRecapReadyCard: View {
    let year: Int
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            NavigationLink {
                YearRecapView(year: year)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your year in dinners is ready")
                            .font(.foonHeadline)
                            .foregroundStyle(Palette.ink)
                        Text("Look back at the year's dinners together.")
                            .font(.foonBody)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "book.pages").foregroundStyle(Palette.paprika)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens your year in dinners", comment: "Yearly recap card: what tapping it does"))
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.borderless)
                .tint(.secondary)
                .accessibilityLabel(Text("Close the year in dinners card",
                                         comment: "Yearly recap card on This Week: dismiss it for this year"))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
        .accessibilityElement(children: .contain)
    }
}

#Preview("Ready") {
    NavigationStack {
        ScrollView {
            YearRecapReadyCard(year: 2026) {}
                .padding()
        }
        .background(Palette.cream)
    }
    .environment(HouseholdStore.preview())
}
