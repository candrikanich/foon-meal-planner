import Observation
import SwiftUI

/// Loads one year's recap. Loading never blocks the screen; a failure says so (with a retry) until a load works, and
/// a failed refresh keeps what already shows.
@Observable @MainActor
final class YearRecapStore {
    enum Phase: Equatable, Sendable {
        case loading
        /// Nil for a year with no dinners logged.
        case loaded(YearRecap?)
        case failed
    }

    private struct Key: Equatable {
        let household: UUID
        let year: Int
    }

    private(set) var phase: Phase = .loading
    private var key: Key?

    var recap: YearRecap? {
        if case .loaded(let recap) = phase { recap } else { nil }
    }

    /// `today` is the household's day: the year shown ends there while it's still going.
    func load(client: HouseholdClient, householdID: UUID, year: Int, today: CalendarDay, members: [Member]) async {
        let key = Key(household: householdID, year: year)
        if key != self.key || phase == .failed { phase = .loading }
        self.key = key
        do {
            let facts = try await client.yearRecap(householdID, year, YearRecap.through(year: year, today: today))
            guard self.key == key else { return }
            phase = .loaded(YearRecap(year: year, facts: facts, members: members))
        } catch {
            guard self.key == key else { return }
            if case .loaded = phase { return }
            phase = .failed
        }
    }
}

/// "Your year in dinners": the whole screen, for everyone in the household, kids included.
struct YearRecapView: View {
    @Environment(HouseholdStore.self) private var household
    @State private var store = YearRecapStore()
    let year: Int

    private var today: CalendarDay {
        household.household?.planningSettings.today() ?? CalendarDay(.now)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(YearRecap.heading(year: year, today: today))
                    .font(.foonLargeTitle)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .padding()
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.cream)
        .navigationTitle("Your year in dinners")
        .task(id: household.household?.id) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load your year", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        case .loaded(nil):
            Text("Once dinners are logged, the year's dinners show up here.")
                .font(.foonBody)
                .foregroundStyle(.secondary)
        case .loaded(let recap?):
            YearRecapContent(recap: recap)
        }
    }

    private func load() async {
        guard let id = household.household?.id else { return }
        await store.load(client: household.client, householdID: id, year: year, today: today,
                         members: household.members)
    }
}

/// The year's lines, one card each, and the footnote under planning time saved.
struct YearRecapContent: View {
    let recap: YearRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(recap.lines, id: \.self) { line in
                YearRecapLineCard(line: line)
            }
            if let note = recap.estimateNote {
                Text(note).font(.foonCaption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct YearRecapLineCard: View {
    let line: YearRecap.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(line.title(), systemImage: line.systemImage)
                .font(isHeading ? .foonHeadline : .foonBody)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(isHeading ? .isHeader : [])
            if case .topDishes(let dishes) = line {
                ForEach(dishes) { dish in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dish.name).font(.foonBody).foregroundStyle(Palette.ink)
                        Text(dish.detail).font(.foonCaption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 30)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
        .accessibilityElement(children: .contain)
    }

    private var isHeading: Bool {
        if case .topDishes = line { true } else { false }
    }
}

#Preview("A good year") {
    let recap = YearRecap(year: 2026, facts: .sample(), members: Member.sampleFamily)
    return ScrollView {
        if let recap { YearRecapContent(recap: recap).padding() }
    }
    .background(Palette.cream)
}

#Preview("The whole screen") {
    YearRecapPreview(store: .preview())
}

#Preview("Couldn't load") {
    var client = HouseholdClient.preview()
    client.yearRecap = { _, _, _ in throw URLError(.notConnectedToInternet) }
    return YearRecapPreview(store: HouseholdStore(userID: .previewUser, client: client))
}

#Preview("Nothing logged yet") {
    var client = HouseholdClient.preview()
    client.yearRecap = { _, _, _ in YearRecapFacts() }
    return YearRecapPreview(store: HouseholdStore(userID: .previewUser, client: client))
}

private struct YearRecapPreview: View {
    let store: HouseholdStore

    var body: some View {
        NavigationStack { YearRecapView(year: 2026) }
            .environment(store)
            .task { await store.load() }
    }
}
