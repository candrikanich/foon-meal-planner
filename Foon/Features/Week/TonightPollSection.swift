import SwiftUI

/// Tonight's poll at the top of This Week: voting while it's open, then how it came out (docs/spec.md → Tonight poll).
struct TonightPollSection: View {
    @Environment(PollStore.self) private var polls: PollStore?
    @Environment(HouseholdStore.self) private var household
    @Environment(WeekStore.self) private var week
    @Environment(DinnerStore.self) private var dinner
    @Environment(LibraryStore.self) private var library
    @Environment(FreezerStore.self) private var freezer: FreezerStore?
    @Environment(IdeasStore.self) private var ideas: IdeasStore?
    @AppStorage("foon.dismissedPolls") private var dismissedRaw = ""
    @State private var votingAs: UUID?
    @State private var confirming: PendingChoice?

    private struct PendingChoice: Identifiable {
        let id = UUID()
        let title: String
        let warning: String
        let choice: WeekStore.SwapChoice
    }

    private var tonight: WeekNight? {
        week.week?.nights.first { $0.date == week.todayDay }
    }

    private var canPlan: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    private var dismissed: [String] { dismissedRaw.split(separator: ",").map(String.init) }

    var body: some View {
        if let polls, let tonight, let poll = polls.poll(for: tonight.id),
           !dinner.logs.contains(where: { $0.nightID == tonight.id }) {
            // Redrawn every minute, so voting turns into the result with the app left open. Reads the clock itself: the timeline's
            // date is the top of the minute, which would keep a poll ended just now looking open until the next one.
            TimelineView(.everyMinute) { _ in
                if poll.isOpen(at: .now) {
                    openCard(poll, night: tonight, polls: polls)
                } else if !dismissed.contains(poll.id.uuidString) {
                    resultCard(poll, night: tonight, polls: polls)
                }
            }
            .task(id: poll.id) { await catchUpLibrary(for: poll) }
            .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible, presenting: confirming) { pending in
                Button("Make it tonight's dinner") { Task { await apply(pending.choice, polls: polls) } }
            } message: { pending in
                Text(pending.warning)
            }
        }
    }

    // MARK: - Open

    private func openCard(_ poll: TonightPoll, night: WeekNight, polls: PollStore) -> some View {
        let voters = PollRules.voters(on: night, members: household.visibleMembers)
        let candidates = PollRules.votesAs(voters: voters, me: household.me)
        let voter = candidates.first { $0.id == votingAs } ?? candidates.first
        let counts = PollRules.counts(poll, voters: voters)
        let myChoice = voter.flatMap { voter in poll.votes.first { $0.memberID == voter.id }?.choice }
        return VStack(alignment: .leading, spacing: 12) {
            Text("What's for dinner tonight?")
                .font(.foonHeadline)
                .foregroundStyle(Palette.ink)
            Text("Voting until \(poll.closesAt.formatted(date: .omitted, time: .shortened)). \(PollRules.votedCount(poll, voters: voters)) of \(voters.count) voted.",
                 comment: "Tonight poll: when it closes, and how many of those home have voted")
                .font(.foonCaption)
                .foregroundStyle(.secondary)
            if candidates.count > 1, let voter {
                Picker("Voting as", selection: Binding(get: { voter.id }, set: { votingAs = $0 })) {
                    ForEach(candidates) { Text($0.firstName).tag($0.id) }
                }
                .pickerStyle(.menu)
                .tint(Palette.paprika)
            }
            ForEach(poll.options.indices, id: \.self) { index in
                optionRow(poll.options[index], count: counts[index], isChosen: myChoice == index, night: night,
                          canVote: voter != nil && !polls.isWorking) {
                    guard let voter else { return }
                    Task { await polls.vote(poll, memberID: voter.id, option: index) }
                }
            }
            if voter == nil {
                Text("This one's for whoever's home tonight.").font(.foonCaption).foregroundStyle(.secondary)
            }
            if let message = polls.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            if PollRules.canClose(poll, me: household.me, canPlan: canPlan) {
                Button("End the poll") { Task { await polls.close(poll) } }
                    .font(.foonCaption)
                    .buttonStyle(.bordered)
                    .tint(Palette.paprika)
                    .disabled(polls.isWorking)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
    }

    private func optionRow(_ option: TonightPoll.Option, count: Int, isChosen: Bool, night: WeekNight, canVote: Bool,
                           vote: @escaping () -> Void) -> some View {
        let allergies = allergyCheck(option, night: night)
        return Button(action: vote) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Palette.paprika)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title).font(.foonBody).foregroundStyle(Palette.ink)
                    AllergyChips(check: allergies)
                }
                Spacer(minLength: 0)
                Text(count, format: .number).font(.foonCaption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canVote)
        .accessibilityLabel(SwapRow.label(option.title, allergies: allergies,
                                          details: [String(localized: "\(count) votes", comment: "Tonight poll, VoiceOver: votes for an option")]))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    // MARK: - Closed

    private func resultCard(_ poll: TonightPoll, night: WeekNight, polls: PollStore) -> some View {
        let voters = PollRules.voters(on: night, members: household.visibleMembers)
        let winners = PollRules.winners(poll, voters: voters).map { poll.options[$0] }
        let settled = winners.first { PollRules.holds(night, $0) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline(winners: winners, settled: settled))
                    .font(.foonHeadline)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Button("Dismiss", systemImage: "xmark") { dismiss(poll) }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.borderless)
                    .tint(.secondary)
            }
            if settled == nil {
                ForEach(winners.indices, id: \.self) { index in
                    winnerRow(winners[index], isTie: winners.count > 1, poll: poll, night: night, polls: polls)
                }
                if !winners.isEmpty, !canPlan {
                    Text("A planner can make it tonight's dinner.").font(.foonCaption).foregroundStyle(.secondary)
                }
            }
            if let message = polls.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
    }

    private func headline(winners: [TonightPoll.Option], settled: TonightPoll.Option?) -> String {
        if let settled {
            return String(localized: "\(settled.title) it is.", comment: "Tonight poll: the winner is now tonight's dinner")
        }
        switch winners.count {
        case 0: return String(localized: "Nobody voted.", comment: "Tonight poll closed with no votes")
        case 1: return String(localized: "\(winners[0].title) won.", comment: "Tonight poll closed with one winner")
        default:
            return String(localized: "It's a tie: \(winners.map(\.title).formatted(.list(type: .and))).",
                          comment: "Tonight poll closed with a tie")
        }
    }

    @ViewBuilder
    private func winnerRow(_ option: TonightPoll.Option, isTie: Bool, poll: TonightPoll, night: WeekNight, polls: PollStore) -> some View {
        let allergies = allergyCheck(option, night: night)
        if isTie {
            Text(option.title).font(.foonBody).foregroundStyle(Palette.ink)
        }
        AllergyChips(check: allergies)
        if canPlan {
            Button { Task { await plan(option, poll: poll, night: night, polls: polls) } } label: {
                Text("Make \(option.title) tonight's dinner", comment: "Tonight poll: a planner puts the winner on tonight").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.paprika)
            .disabled(week.isBuilding)
        }
    }

    /// A dish added since the library loaded would otherwise read as unchecked for allergies, and as something that can't be planned.
    private func catchUpLibrary(for poll: TonightPoll) async {
        if !library.hasLoaded || PollRules.hasUnknownDish(poll, library: library.meals) {
            await library.load(members: household.members)
        }
    }

    private func plan(_ option: TonightPoll.Option, poll: TonightPoll, night: WeekNight, polls: PollStore) async {
        polls.clearError()
        await catchUpLibrary(for: poll)
        if option.freezerItemID != nil { await freezer?.load() }
        guard let choice = PollRules.swapChoice(for: option, library: library.meals, freezer: freezer?.items ?? [], today: week.todayDay) else {
            polls.note(String(localized: "\(option.title) can't be planned any more. Use Swap to pick something else."))
            return
        }
        // Moving a doubled or freezer night moves another with it, and Swap says so before it does.
        if let warning = DoubleIt.changeWarning(for: night, in: week.week?.nights ?? []) {
            confirming = PendingChoice(title: option.title, warning: warning, choice: choice)
            return
        }
        await apply(choice, polls: polls)
    }

    private func apply(_ choice: WeekStore.SwapChoice, polls: PollStore) async {
        guard let nightID = tonight?.id else { return }
        if await week.swap(nightID: nightID, to: choice) {
            await ideas?.sync(with: week.week, today: week.todayDay, requestNights: week.requestNights, away: week.awayDates)
            if case .freezer = choice { await freezer?.load() }
        }
    }

    private func allergyCheck(_ option: TonightPoll.Option, night: WeekNight) -> AllergyCheck {
        guard let mealID = option.mealID else { return AllergyCheck() }
        return NightBadges.allergyCheck(dish: library.meal(mealID), library: library.meals, allergies: library.allergies,
                                        home: night.allergyHome(library.allergies), lookup: library.lookup)
    }

    private func dismiss(_ poll: TonightPoll) {
        // Only the last few can still show.
        dismissedRaw = (dismissed.suffix(4) + [poll.id.uuidString]).joined(separator: ",")
    }
}

/// Keeps tonight's poll current while This Week is on screen. Nothing tells a phone about a vote until server push. On the screen
/// and not the section, which is empty until there's a poll, and an empty view's tasks never run.
struct TonightPollRefresh: ViewModifier {
    @Environment(PollStore.self) private var polls: PollStore?
    @Environment(WeekStore.self) private var week
    @Environment(\.scenePhase) private var scenePhase

    private var tonightID: UUID? {
        week.week?.nights.first { $0.date == week.todayDay }?.id
    }

    func body(content: Content) -> some View {
        content
            .task(id: tonightID) {
                guard let polls, let tonightID else { return }
                while !Task.isCancelled {
                    await polls.load(nightID: tonightID)
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, let polls, let tonightID { Task { await polls.load(nightID: tonightID) } }
            }
    }
}

#Preview {
    let household = HouseholdStore.preview()
    let week = WeekStore(householdID: Household.sample.id, client: .preview(started: true))
    return ScrollView {
        TonightPollSection().padding()
    }
    .background(Palette.cream)
    .environment(PollStore(client: .preview))
    .environment(household)
    .environment(week)
    .environment(DinnerStore(householdID: Household.sample.id, client: .preview))
    .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
    .task {
        await household.load()
        await week.load(settings: HouseholdSettings())
    }
}
