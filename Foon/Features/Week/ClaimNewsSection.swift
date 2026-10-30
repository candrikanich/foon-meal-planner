import SwiftUI

/// "Ben will cook Thursday" at the top of This Week, for planners (docs/spec.md → Claim a night). Dismissed per device, like
/// request news. Push comes in M2 car 6, from the same rows in `night_claims`.
struct ClaimNewsSection: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(HouseholdStore.self) private var household
    @Environment(WeekStore.self) private var week
    @AppStorage("foon.dismissedClaimNews") private var dismissedRaw = ""

    private var dismissed: Set<UUID> { Set(dismissedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }

    private var canPlan: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    var body: some View {
        let settings = household.household?.planningSettings ?? HouseholdSettings()
        let news = NightClaims.news(claims: dinner.claims, nights: week.week?.nights ?? [], me: household.me?.id, canPlan: canPlan,
                                    members: household.visibleMembers, logged: Set(dinner.logs.map(\.nightID)),
                                    away: settings.awayDates, today: week.todayDay, dismissed: dismissed)
        if !news.isEmpty {
            VStack(spacing: 12) {
                ForEach(news) { claim in
                    let member = household.visibleMembers.first { $0.id == claim.memberID }
                    let text = ClaimText.willCook(member?.firstName ?? "", claim.date, today: week.todayDay)
                    HStack(spacing: 12) {
                        if let member {
                            MemberAvatar(member: member, size: 32).accessibilityHidden(true)
                        }
                        Text(text)
                            .font(.foonBody)
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                        Button("Dismiss", systemImage: "xmark") { dismiss(claim.id) }
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .buttonStyle(.borderless)
                            .tint(.secondary)
                            .accessibilityLabel(Text("Dismiss: \(text)", comment: "Claim news: close the note"))
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
        // Keep the list short: only claims still open are worth remembering.
        let live = Set(dinner.claims.map(\.id))
        dismissedRaw = (dismissed.intersection(live).union([id])).map(\.uuidString).joined(separator: ",")
    }
}

#Preview("Someone offered") {
    let household = HouseholdStore.preview()
    let ben = Member.sampleFamily[1].id
    var client = DinnerClient.preview
    client.claims = { _, _ in
        [NightClaim(nightID: UUID(), memberID: ben, enteredByMemberID: ben, date: CalendarDay(Date()).adding(days: 2))]
    }
    let dinner = DinnerStore(householdID: Household.sample.id, client: client)
    return ClaimNewsSection()
        .padding()
        .background(Palette.cream)
        .environment(household)
        .environment(dinner)
        .environment(WeekStore(householdID: Household.sample.id, client: .preview()))
        .task {
            await household.load()
            await dinner.load(settings: HouseholdSettings())
        }
}
