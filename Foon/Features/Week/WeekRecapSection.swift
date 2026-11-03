import Observation
import SwiftUI

/// Loads the weekly recap for This Week: last week's facts and counts, read together, only while the card can show.
/// Quiet on failure, like the Family tab's stats: it's a nice-to-have, never in the way.
@Observable @MainActor
final class WeekRecapStore {
    private(set) var recap: WeekRecap?
    private var householdID: UUID?

    func load(client: HouseholdClient, household: Household?, members: [Member], today: CalendarDay) async {
        guard let household,
              let week = WeekRecap.week(today: today, weekStart: household.planningSettings.weekStart,
                                        calendar: household.planningSettings.dayCalendar) else {
            recap = nil
            return
        }
        let settings = household.planningSettings
        if householdID != household.id || recap?.weekStart != week.start { recap = nil }
        async let facts = client.weekRecap(household.id, week.start, week.end)
        async let stats = client.familyStats(household.id, week.start, week.end)
        guard let facts = try? await facts, let stats = try? await stats else { return }
        householdID = household.id
        recap = WeekRecap(weekStart: week.start, facts: facts, stats: stats, members: members, settings: settings,
                          calendar: settings.dayCalendar)
    }
}

/// Last week's recap at the top of This Week, for everyone, until this device closes it.
struct WeekRecapSection: View {
    @Environment(HouseholdStore.self) private var household
    @AppStorage("foon.dismissedRecaps") private var dismissedRaw = ""
    let store: WeekRecapStore

    private var dismissed: [String] { dismissedRaw.split(separator: ",").map(String.init) }

    var body: some View {
        if let recap = store.recap, let householdID = household.household?.id,
           !dismissed.contains(WeekRecap.dismissalKey(household: householdID, week: recap.weekStart)) {
            WeekRecapCard(recap: recap) {
                // Only the last few are worth remembering: a recap is gone after three days anyway.
                let key = WeekRecap.dismissalKey(household: householdID, week: recap.weekStart)
                dismissedRaw = (dismissed.suffix(7) + [key]).joined(separator: ",")
            }
        }
    }
}

struct WeekRecapCard: View {
    let recap: WeekRecap
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last week's dinners")
                    .font(.foonHeadline)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    .accessibilityLabel(Text("Close last week's recap", comment: "Weekly recap: dismiss the card"))
            }
            ForEach(recap.lines, id: \.self) { line in
                Label(line.title(), systemImage: line.systemImage)
                    .font(.foonBody)
                    .foregroundStyle(Palette.ink)
            }
            if let note = recap.estimateNote {
                Text(note).font(.foonCaption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
        .accessibilityElement(children: .contain)
    }
}

#Preview("A good week") {
    let settings = HouseholdSettings()
    let recap = WeekRecap(weekStart: CalendarDay(year: 2026, month: 11, day: 1), facts: .sample(),
                          stats: .sampleWeek, members: Member.sampleFamily, settings: settings, calendar: .current)
    return ScrollView {
        if let recap { WeekRecapCard(recap: recap) {} }
    }
    .padding()
    .background(Palette.cream)
}

#Preview("A quiet week") {
    let recap = WeekRecap(weekStart: CalendarDay(year: 2026, month: 11, day: 1), facts: WeekRecapFacts(logged: 2),
                          stats: FamilyStats(dinners: 2, dishes: 1), members: [], settings: HouseholdSettings(),
                          calendar: .current)
    return ScrollView {
        if let recap { WeekRecapCard(recap: recap) {} }
    }
    .padding()
    .background(Palette.cream)
}
