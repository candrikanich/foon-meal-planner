import SwiftUI

/// "Home tonight?" on This Week, with what's for dinner, from the check-in time until dinner (docs/spec.md → Notifications). The
/// notification's words can't name the dish, so this is its preview. Not on Light, which doesn't ask.
struct CheckInSection: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(HouseholdStore.self) private var household
    @Environment(WeekStore.self) private var week
    @Environment(ReminderStore.self) private var reminders: ReminderStore?

    /// The week's, since that's what a change on this phone updates.
    private var nights: [WeekNight] { week.week?.nights ?? [] }

    var body: some View {
        if let me = household.me {
            let settings = household.household?.planningSettings ?? HouseholdSettings()
            if ReminderRules(member: me, settings: settings).kinds.contains(.checkIn) {
                // Re-checked every minute, so the card comes and goes with the app left open.
                TimelineView(.everyMinute) { context in
                    let calendar = DinnerPrompts.calendar(for: settings)
                    let isApproved = week.week?.approvedAt != nil
                    if let night = DayOfCheckIn.asking(me, nights: nights, logs: dinner.logs, settings: settings,
                                                       isApproved: isApproved, now: context.date, calendar: calendar) {
                        askCard(night, me: me)
                    } else if let night = DayOfCheckIn.saidNotHome(me, nights: nights, logs: dinner.logs, settings: settings,
                                                                   isApproved: isApproved, now: context.date, calendar: calendar) {
                        notHomeNote(night, me: me)
                    }
                }
            }
        }
    }

    private func askCard(_ night: WeekNight, me: Member) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Home tonight?")
                .font(.foonHeadline)
                .foregroundStyle(Palette.ink)
            if let preview = preview(night) {
                Text(preview).font(.foonBody).foregroundStyle(.secondary)
            }
            HStack {
                Button { answer(night, me: me, home: true) } label: {
                    Text("Home", comment: "Check-in answer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.paprika)
                Button { answer(night, me: me, home: false) } label: {
                    Text("Not home", comment: "Check-in answer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Palette.paprika)
            }
            .disabled(dinner.saving.contains(night.id))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
    }

    private func notHomeNote(_ night: WeekNight, me: Member) -> some View {
        HStack(spacing: 12) {
            Text("You said you won't be home tonight.")
                .font(.foonBody)
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            Button("I'll be home") { answer(night, me: me, home: true) }
                .font(.foonCaption)
                .buttonStyle(.bordered)
                .tint(Palette.paprika)
                .disabled(dinner.saving.contains(night.id))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
    }

    private func preview(_ night: WeekNight) -> String? {
        if let pick = night.quickPick { return DayCardText.quickPickLabel(pick) }
        return night.mealName.map { String(localized: "\($0) for dinner", comment: "Check-in card: tonight's dish") }
    }

    private func answer(_ night: WeekNight, me: Member, home: Bool) {
        Task {
            if await dinner.answerCheckIn(nightID: night.id, memberID: me.id, home: home) {
                reminders?.forgetWaitingCheckIns(night: night.id, member: me.id)
            }
            // Refused too: this phone was behind on who's home.
            await week.refresh()
        }
    }
}

/// "Ben won't be home tonight" at the top of This Week, for planners. Only a change reaches them, since no answer means home.
/// Dismissed per device, like claim news. Push comes with server push (#40), from the same rows in `night_attendance`.
struct CheckInNewsSection: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(HouseholdStore.self) private var household
    @Environment(WeekStore.self) private var week
    @AppStorage("foon.dismissedCheckInNews") private var dismissedRaw = ""
    let swap: (UUID) -> Void

    private var dismissed: [String] { dismissedRaw.split(separator: ",").map(String.init) }

    private var canPlan: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    var body: some View {
        let news = DayOfCheckIn.changes(nights: week.week?.nights ?? [], members: household.visibleMembers, me: household.me?.id, canPlan: canPlan,
                                        today: week.todayDay, dismissed: Set(dismissed))
        if !news.isEmpty {
            VStack(spacing: 12) {
                ForEach(news) { change in
                    row(change)
                }
            }
        }
    }

    private func row(_ change: DayOfCheckIn.Change) -> some View {
        let text = String(localized: "\(change.member.firstName) won't be home tonight.", comment: "Check-in news for a planner")
        return HStack(spacing: 12) {
            MemberAvatar(member: change.member, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.foonBody).foregroundStyle(Palette.ink)
                if change.expectsLeftovers {
                    Text("Expect leftovers.", comment: "Check-in news: someone's out, so there'll be food left")
                        .font(.foonCaption)
                        .foregroundStyle(.secondary)
                }
                if change.offersSwap {
                    Button("Swap dinner") { swap(change.night.id) }
                        .font(.foonCaption)
                        .buttonStyle(.bordered)
                        .tint(Palette.paprika)
                }
            }
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark") { dismiss(change.id) }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.borderless)
                .tint(.secondary)
                .accessibilityLabel(Text("Dismiss: \(text)", comment: "Check-in news: close the note"))
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
    }

    private func dismiss(_ id: String) {
        // Keep the list short: tonight's are the only ones that can still show.
        let live = Set((week.week?.nights ?? []).filter { $0.date == week.todayDay }.map(\.id.uuidString))
        let kept = dismissed.filter { key in live.contains { key.hasPrefix($0) } }
        dismissedRaw = (kept + [id]).joined(separator: ",")
    }
}

#Preview("Asking") {
    let household = HouseholdStore.preview()
    let dinner = DinnerStore(householdID: Household.sample.id, client: .preview)
    return CheckInSection()
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
