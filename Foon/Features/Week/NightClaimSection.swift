import SwiftUI

/// Who's cooking, in a night's detail: everyone sees it, anyone can offer (for themselves, or passing the phone for someone
/// with no account of their own), and whoever offered or a planner can take it back. Nothing to show for a night gone by
/// without a log, or a logged dinner with nobody down as the cook.
struct NightClaimSection: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(HouseholdStore.self) private var household
    @Environment(WeekStore.self) private var week
    let night: WeekNight
    let canPlan: Bool

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }
    private var members: [Member] { household.visibleMembers }
    private var log: DinnerLog? { dinner.log(for: night.id) }

    var body: some View {
        let today = week.todayDay
        let claim = log == nil && night.date >= today ? NightClaims.claim(on: night.id, in: dinner.claims) : nil
        let standing = claim.flatMap {
            NightClaims.standing(of: $0, on: night, members: members, away: settings.awayDates, today: today)
        }
        let cook = NightClaims.cookLine(night: night, claims: dinner.claims, log: log, members: members,
                                        me: household.me?.id, away: settings.awayDates, today: today)
        let offering = household.me.map {
            NightClaims.whoCanClaim(me: $0, night: night, claims: dinner.claims, log: log, members: members,
                                    away: settings.awayDates, today: today)
        } ?? []
        let isBusy = dinner.saving.contains(night.id)
        if cook != nil || standing != nil || !offering.isEmpty {
            Section {
                if let cook {
                    Label {
                        Text(DayCardText.cookLabel(cook))
                    } icon: {
                        MemberAvatar(member: .fixture(id: cook.memberID, firstName: cook.firstName, avatar: cook.avatar), size: 28)
                    }
                }
                if case .onHold(let hold) = standing, let name = members.first(where: { $0.id == claim?.memberID })?.firstName {
                    Text(ClaimText.onHold(name, hold)).foregroundStyle(.secondary)
                }
                if let claim, standing != nil,
                   NightClaims.canRelease(claim, me: household.me, canPlan: canPlan, members: members) {
                    Button(claim.memberID == household.me?.id ? String(localized: "I can't cook after all")
                                                              : String(localized: "Take this off the night"),
                           systemImage: "arrow.uturn.backward") {
                        Task { await dinner.release(claim) }
                    }
                    .tint(Palette.paprika)
                    .disabled(isBusy)
                }
                ForEach(offering) { member in
                    Button(member.id == household.me?.id ? ClaimText.offer(night.date, today: today)
                                                         : ClaimText.willCook(member.firstName, night.date, today: today),
                           systemImage: "frying.pan") {
                        Task { await dinner.claim(nightID: night.id, memberID: member.id) }
                    }
                    .tint(Palette.paprika)
                    .disabled(isBusy)
                }
                if let message = dinner.claimMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Who's cooking")
            }
        }
    }
}

#Preview("Offer, passing the phone") {
    let household = HouseholdStore.preview()
    let night = WeekNight(id: UUID(), date: CalendarDay(Date()).adding(days: 2), effort: .normal, dinnerTime: nil,
                          mealID: UUID(), mealName: "Chili", quickPick: nil, locked: false, attendance: [:])
    Form { NightClaimSection(night: night, canPlan: true) }
        .environment(household)
        .environment(DinnerStore(householdID: Household.sample.id, client: .preview))
        .environment(WeekStore(householdID: Household.sample.id, client: .preview()))
        .task { await household.load() }
}
