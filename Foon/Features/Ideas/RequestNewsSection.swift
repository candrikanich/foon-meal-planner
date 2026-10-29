import SwiftUI

/// "Your crab legs made Friday" at the top of This Week, for whoever asked (docs/spec.md → Inbox rules: requesters
/// hear when their idea makes the plan). Dismissed per device. Push comes in M2 car 6.
struct RequestNewsSection: View {
    @Environment(IdeasStore.self) private var ideas
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(WeekStore.self) private var week
    @AppStorage("foon.dismissedRequestNews") private var dismissedRaw = ""

    private var dismissed: Set<UUID> { Set(dismissedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }

    var body: some View {
        if let me = household.me {
            let news = RequestBoard.news(ideas.requests, me: me.id, today: week.todayDay, dismissed: dismissed)
            VStack(spacing: 12) {
                ForEach(news) { request in
                    let text = RequestText.madeIt(request, library: library, today: week.todayDay)
                    HStack(spacing: 12) {
                        Image(systemName: "party.popper").font(.title2).foregroundStyle(Palette.paprika)
                            .accessibilityHidden(true)
                        Text(text)
                            .font(.foonBody)
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                        Button("Dismiss", systemImage: "xmark") { dismiss(request.id) }
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .buttonStyle(.borderless)
                            .tint(.secondary)
                            .accessibilityLabel(Text("Dismiss: \(text)", comment: "Request news: close the note"))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
                }
            }
        }
    }

    private func dismiss(_ id: UUID) {
        // Keep the list short: only ideas still around are worth remembering.
        let live = Set(ideas.requests.map(\.id))
        dismissedRaw = (dismissed.intersection(live).union([id])).map(\.uuidString).joined(separator: ",")
    }
}

#Preview("Your request made it") {
    let household = HouseholdStore.preview()
    let ann = Member.sampleFamily[0].id
    let ideas = IdeasStore(householdID: Household.sample.id, client: .preview(requests: [
        DinnerRequest(requestedByMemberID: ann, title: "Crab legs", status: .planned, plannedNightID: UUID(),
                      plannedDate: CalendarDay(Date()).adding(days: 3))
    ]))
    RequestNewsSection()
        .padding()
        .background(Palette.cream)
        .environment(household)
        .environment(ideas)
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(WeekStore(householdID: Household.sample.id, client: .preview()))
        .task {
            await household.load()
            await ideas.load()
        }
}
