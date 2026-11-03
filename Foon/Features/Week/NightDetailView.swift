import SwiftUI

/// One night in full: what's for dinner, who's home, effort, and the lock. Planners change it; everyone sees it.
struct NightDetailView: View {
    @Environment(WeekStore.self) private var week
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(DinnerStore.self) private var dinnerStore
    @Environment(\.dismiss) private var dismiss
    let nightID: UUID
    let canPlan: Bool
    @Environment(IdeasStore.self) private var ideas: IdeasStore?
    @Environment(PlanActivityStore.self) private var activity: PlanActivityStore?
    @Environment(PollStore.self) private var polls: PollStore?
    @Environment(CalendarBusyStore.self) private var calendarBusy: CalendarBusyStore?
    @State private var swapping = false
    @State private var choosingLeftovers = false
    @State private var startingPoll = false
    @State private var rescuing = false
    @State private var pollStarted = false

    private static let efforts: [NightEffort] = [.normal, .rushed, .full, .event]

    private var night: WeekNight? { week.week?.nights.first { $0.id == nightID } }

    var body: some View {
        NavigationStack {
            if let night {
                form(night)
                    .navigationTitle(DayCardText.dayLabel(for: night.date, today: week.todayDay))
            } else {
                ContentUnavailableView("Night not found", systemImage: "calendar")
            }
        }
    }

    /// Tonight, before dinner's logged: what can we make, for anyone, and a vote when there are at least two people
    /// to ask. One poll at a time: an open one is on This Week.
    @ViewBuilder
    private func tonightSection(_ night: WeekNight) -> some View {
        let logged = dinnerStore.logs.contains(where: { $0.nightID == night.id })
        let settings = household.household?.planningSettings ?? HouseholdSettings()
        let offersRescue = TonightRescue.offers(night: night, logged: logged,
                                                isAway: night.readsAway(in: settings.awayDates, today: week.todayDay),
                                                today: week.todayDay)
        let offersPoll = polls != nil && night.date == week.todayDay && !logged
            && polls?.poll(for: night.id)?.isOpen(at: .now) != true
            && PollRules.voters(on: night, members: household.visibleMembers).count >= 2
        if offersRescue || offersPoll {
            Section {
                if offersRescue {
                    Button("What can we make?", systemImage: "lifepreserver") { rescuing = true }
                        .tint(Palette.paprika)
                        .accessibilityHint("Shows a few quick ideas from what's in the house")
                }
                if offersPoll {
                    Button("Vote on dinner", systemImage: "checklist") { startingPoll = true }
                        .tint(Palette.paprika)
                }
            } footer: {
                if offersPoll {
                    Text("Plans fell through? Start a quick vote on what's for dinner.")
                } else {
                    Text("Plans fell through? See what you can make in the time there is.")
                }
            }
        }
    }

    private func isBusy(_ night: WeekNight) -> Bool {
        let settings = household.household?.planningSettings ?? HouseholdSettings()
        return calendarBusy?.suggestions(nights: week.week?.nights ?? [], settings: settings).contains(night.id) == true
    }

    /// Calendar awareness (#64): the same suggestion as the card, accepted through the usual effort change.
    @ViewBuilder
    private func busySuggestion(_ night: WeekNight) -> some View {
        if let calendarBusy, isBusy(night) {
            Button("Busy evening? Mark it rushed", systemImage: "calendar.badge.clock") {
                Task { await week.setEffort(.rushed, nightID: night.id) }
            }
            .tint(Palette.paprika)
            .accessibilityHint("Changes the night's effort to rushed")
            Button("Not this time", systemImage: "xmark") { calendarBusy.dismiss(night.id) }
                .tint(.secondary)
                .accessibilityHint("Hides this suggestion for this night")
        }
    }

    private func form(_ night: WeekNight) -> some View {
        Form {
            Section {
                dinner(night)
                if let time = night.dinnerTime {
                    LabeledContent("Dinner at", value: String(time.prefix(5)))
                }
                if canPlan {
                    Button("Swap", systemImage: "arrow.triangle.2.circlepath") { swapping = true }
                        .tint(Palette.paprika)
                        .disabled(week.isBuilding)
                }
            } header: {
                Text(DayCardText.dateLabel(for: night.date))
            }

            tonightSection(night)

            NightClaimSection(night: night, canPlan: canPlan)

            dinnerJobs(night)

            cookOnceEatTwice(night)

            Section {
                if canPlan {
                    Picker("Effort", selection: Binding(
                        get: { night.effort },
                        set: { effort in Task { await week.setEffort(effort, nightID: night.id) } }
                    )) {
                        ForEach(Self.efforts, id: \.self) { Text(DayCardText.effortLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    busySuggestion(night)
                } else {
                    Text(DayCardText.effortLabel(night.effort))
                }
            } header: {
                Text("Effort")
            } footer: {
                if canPlan, isBusy(night) {
                    Text("Your calendar has plans around dinner. Nothing changes unless you tap.")
                }
            }

            Section("Who's home") {
                ForEach(household.visibleMembers.filter { night.attendance[$0.id] != nil }) { member in
                    let home = night.attendance[member.id] ?? false
                    if canPlan {
                        Toggle(isOn: Binding(
                            get: { home },
                            set: { _ in Task { await week.toggleAttendance(nightID: night.id, memberID: member.id) } }
                        )) {
                            Label { Text(member.firstName) } icon: { MemberAvatar(member: member, size: 28) }
                        }
                    } else {
                        LabeledContent {
                            Text(home ? "Home" : "Out")
                        } label: {
                            Label { Text(member.firstName) } icon: { MemberAvatar(member: member, size: 28) }
                        }
                    }
                }
            }

            if canPlan {
                Section {
                    Toggle("Lock this night", isOn: Binding(
                        get: { night.locked },
                        set: { _ in Task { await week.toggleLock(nightID: night.id) } }
                    ))
                } footer: {
                    Text("Build my week and shuffles leave locked nights as they are.")
                }
            }

            NightChangesSection(night: night, canPlan: canPlan) { await syncIdeas(undone: night.id) }

            if let message = week.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $swapping) {
            SwapSheet(nightID: nightID)
        }
        // Up here and not with its button, which goes when someone else's poll opens: the 30-second refresh keeps running behind
        // the sheet, and it would close on whoever's still choosing. This screen leaves once the sheet has, so the vote is in view.
        .sheet(isPresented: $startingPoll, onDismiss: {
            if pollStarted { dismiss() }
        }) {
            StartPollSheet(nightID: nightID) { pollStarted = true }
        }
        // Asking the family from here starts a poll too, and this screen steps aside for it the same way.
        .sheet(isPresented: $rescuing, onDismiss: {
            if pollStarted { dismiss() }
        }) {
            RescueSheet(nightID: nightID) { pollStarted = true }
        }
        // Again when the swap sheet closes, by when its write has landed. The pick shows before it does.
        .task(id: swapping) {
            if !swapping { await activity?.load() }
        }
    }

    /// Whose turn it is, when the household uses jobs.
    @ViewBuilder
    private func dinnerJobs(_ night: WeekNight) -> some View {
        let settings = household.household?.planningSettings ?? HouseholdSettings()
        let members = household.visibleMembers
        let lines = DinnerJobs.lines(
            for: night,
            in: DinnerJobs.forWeek(nights: week.week?.nights ?? [], settings: settings.dinnerJobs, members: members,
                                   claims: dinnerStore.claims, away: settings.awayDates, today: week.todayDay),
            members: members, today: week.todayDay)
        if !lines.isEmpty {
            Section {
                ForEach(lines, id: \.self) { line in
                    LabeledContent(line.title, value: line.firstName)
                }
            } header: {
                Text("Dinner jobs")
            } footer: {
                Text("Can't do it tonight? Just trade. Foon doesn't keep score.")
            }
        }
    }

    /// Everyone sees what's doubled and where the leftovers are; planners double a dish or undo it.
    @ViewBuilder
    private func cookOnceEatTwice(_ night: WeekNight) -> some View {
        let nights = week.week?.nights ?? []
        let later = DoubleIt.leftoversNight(of: night, in: nights)
        let source = nights.first { $0.id == night.leftoversFrom }
        if later != nil || source != nil {
            Section {
                if let later {
                    Text(DoubleIt.doubledText(leftoversOn: later, today: week.todayDay))
                } else if let note = source.flatMap({ DoubleIt.leftoversNote(from: $0) }) {
                    Text(note)
                }
                if canPlan {
                    Button("Undo Double it", systemImage: "arrow.uturn.backward") {
                        Task {
                            if await week.undoDouble(nightID: night.id) { await syncIdeas() }
                            await activity?.load()
                        }
                    }
                    .tint(Palette.paprika)
                    .disabled(week.isBuilding)
                    .accessibilityHint("Goes back to what the leftovers night held, and the regular amounts")
                }
            } header: {
                Text("Cook once, eat twice")
            } footer: {
                if canPlan, week.week?.approvedAt != nil {
                    Text("Update the list on This Week after undoing, to go back to the regular amounts.")
                }
            }
        } else if canPlan, let layout = week.layout, DoubleIt.canDouble(night, in: layout) {
            let choices = DoubleIt.choices(for: night, in: layout)
            Section {
                Button("Double it", systemImage: "square.on.square") { choosingLeftovers = true }
                    .tint(Palette.paprika)
                    .disabled(week.isBuilding || choices.isEmpty)
                    .confirmationDialog("Which night for the leftovers?", isPresented: $choosingLeftovers,
                                        titleVisibility: .visible) {
                        ForEach(choices) { later in
                            Button(leftoversChoice(later)) {
                                Task {
                                    if await week.doubleIt(nightID: night.id, leftoversNightID: later.id) {
                                        await syncIdeas()
                                    }
                                    await activity?.load()
                                }
                            }
                        }
                    } message: {
                        Text(DoubleIt.listNote(approved: week.week?.approvedAt != nil))
                    }
            } header: {
                Text("Cook once, eat twice")
            } footer: {
                Text(choices.isEmpty ? "No later night this week can take the leftovers."
                                     : "Cook twice as much, and plan a night off later this week.")
            }
        }
    }

    private func leftoversChoice(_ later: WeekNight) -> String {
        let day = DayCardText.dayLabel(for: later.date, today: week.todayDay)
        guard later.isPlanned, later.quickPick != .leftovers else { return day }
        return String(localized: "\(day): replaces \(PlanIt.currentPick(later))",
                      comment: "Double it, choosing the leftovers night: the night and what's planned there now")
    }

    /// A dish that leaves a night takes its request back to open, as after a swap.
    private func syncIdeas(undone: UUID? = nil) async {
        await ideas?.sync(with: week.week, today: week.todayDay, requestNights: week.requestNights, away: week.awayDates,
                          undoneNight: undone)
    }

    @ViewBuilder
    private func dinner(_ night: WeekNight) -> some View {
        if let mealID = night.mealID, let name = night.mealName {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.foonTitle)
                if let sides = DayCardText.sidesLabel(library.meal(mealID).map(library.sideNames(for:)) ?? []) {
                    Text(sides).font(.foonCaption).foregroundStyle(.secondary)
                }
            }
        } else if let pick = night.quickPick {
            Text(DayCardText.quickPickLabel(pick)).font(.foonTitle)
        } else {
            Text("Nothing planned yet").foregroundStyle(.secondary)
        }
    }
}
