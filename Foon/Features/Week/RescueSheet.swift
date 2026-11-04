import SwiftData
import SwiftUI

/// What a rescue row says, kept out of the view so it's testable.
enum RescueRow {
    /// The rescue checks against the library as read; when that read may be missing someone's allergy, a dish says so,
    /// as Swap's rows do.
    static func allergyCheck(_ idea: TonightRescue.Idea, lookup: LibraryLookup) -> AllergyCheck {
        if case .quickPick = idea.kind { return idea.allergies }
        let note = idea.allergies.note ?? (lookup.isOutOfDate ? AllergyMatcher.outOfDateNote : nil)
        return AllergyCheck(flags: idea.allergies.flags, note: note)
    }

    static func systemImage(_ kind: TonightRescue.Idea.Kind) -> String {
        switch kind {
        case .leftovers: QuickPick.leftovers.systemImage
        case .freezer: "snowflake"
        case .backup: "cabinet"
        case .quickDish: "timer"
        case .quickPick(let pick): pick.systemImage
        }
    }

    /// "For Ana, Ben and Nora": whoever hasn't said they're out, as allergy flags and the poll count them.
    static func forWhom(_ night: WeekNight, members: [Member]) -> String? {
        forWhom(members.filter { $0.status != .removed && night.attendance[$0.id] != false }.map(\.firstName))
    }

    static func forWhom(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return String(localized: "For \(names.formatted(.list(type: .and)))",
                      comment: "Tonight rescue: who's home tonight, e.g. For Ana, Ben and Nora")
    }
}

/// Tonight rescue (docs/spec.md → Tonight rescue): dinner fell through, so three ideas from what's in the house, in
/// the time there is. Planners make one tonight's dinner through a normal Swap; anyone can ask the family instead.
struct RescueSheet: View {
    @Environment(WeekStore.self) private var week
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(DinnerStore.self) private var dinner
    @Environment(FreezerStore.self) private var freezer: FreezerStore?
    @Environment(IdeasStore.self) private var ideaStore: IdeasStore?
    @Environment(PollStore.self) private var polls: PollStore?
    @Environment(\.dismiss) private var dismiss
    @Query private var items: [CachedItem]
    let nightID: UUID
    /// Asking the family started a poll; whoever opened this can step aside for it.
    var pollStarted: () -> Void = {}
    /// Tonight's dinner was chosen here.
    var chosen: () -> Void = {}
    /// Friendlier why-lines on a device that can run the model; the code lines show until then, and stay otherwise.
    var ai: AIService = .live

    @State private var minutes = TonightRescue.defaultMinutes
    @State private var seed = UInt64.random(in: .min ... .max)
    @State private var confirming: TonightChoice?
    @State private var askingFamily = false
    @State private var startedPoll = false
    @State private var isWorking = false
    @State private var wording: RescueWordingStore?

    private var night: WeekNight? { week.week?.nights.first { $0.id == nightID } }
    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }

    private var canPlan: Bool {
        LibraryStore.canEdit(me: household.me, isOwner: household.household?.owner == household.userID)
    }

    private var ideas: [TonightRescue.Idea] {
        guard let loaded = week.week, library.hasLoaded else { return [] }
        let stock = Dictionary(items.compactMap { item in item.stockState.map { (item.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        let context = PlanningContext(meals: library.meals, history: library.history, settings: settings,
                                      members: household.visibleMembers, traditions: week.traditions,
                                      reactions: library.reactions)
        return TonightRescue.ideas(minutes: minutes, nightID: nightID, week: loaded.nights,
                                   planning: context.inputs(for: loaded, today: week.todayDay),
                                   freezer: freezer?.items ?? [], logs: dinner.logs, stock: stock,
                                   allergies: library.allergies, seed: seed)
    }

    /// Two or more home and no vote already running: the same rule as Vote on dinner.
    private func canAsk(_ night: WeekNight) -> Bool {
        polls != nil && polls?.poll(for: night.id)?.isOpen(at: .now) != true
            && PollRules.voters(on: night, members: household.visibleMembers).count >= 2
    }

    var body: some View {
        let current = library.hasLoaded ? ideas : []
        NavigationStack {
            Group {
                if let night {
                    RescueContent(minutes: $minutes,
                                  forWhom: RescueRow.forWhom(night, members: household.visibleMembers),
                                  ideas: library.hasLoaded ? current.map(withLookup) : nil,
                                  wording: wording?.lines(for: current) ?? [:], canPlan: canPlan,
                                  canAsk: canAsk(night), message: week.errorMessage,
                                  isDisabled: isWorking || week.isBuilding,
                                  choose: { idea in Task { await choose(idea, on: night) } },
                                  moreIdeas: { seed = UInt64.random(in: .min ... .max) },
                                  askFamily: { askingFamily = true })
                } else {
                    ContentUnavailableView("Night not found", systemImage: "calendar")
                }
            }
            .navigationTitle("What can we make?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                week.clearError()
                if !library.hasLoaded { await library.load(members: household.members) }
                if freezer?.hasLoaded == false { await freezer?.load() }
            }
            // A new draw (the time, More ideas) cancels the call for the last one, as does closing the sheet.
            .task(id: RescueWording.draw(current)) {
                guard !current.isEmpty else { return }
                let store = wording ?? RescueWordingStore(ai: ai)
                wording = store
                await store.word(current, minutes: minutes)
            }
            .confirmingTonightChoice($confirming) { choice in Task { await apply(choice) } }
            .sheet(isPresented: $askingFamily, onDismiss: {
                if startedPoll {
                    pollStarted()
                    dismiss()
                }
            }) {
                StartPollSheet(nightID: nightID, preselected: ideas.map(\.pollChoice) + [.quickPick(.takeout)]) {
                    startedPoll = true
                }
            }
        }
    }

    private func withLookup(_ idea: TonightRescue.Idea) -> TonightRescue.Idea {
        TonightRescue.Idea(kind: idea.kind, title: idea.title, why: idea.why, minutes: idea.minutes,
                           isEstimate: idea.isEstimate, allergies: RescueRow.allergyCheck(idea, lookup: library.lookup),
                           swapChoice: idea.swapChoice)
    }

    private func choose(_ idea: TonightRescue.Idea, on night: WeekNight) async {
        week.clearError()
        if let pending = TonightChoice.confirmation(title: idea.title, choice: idea.swapChoice, night: night,
                                                    week: week.week?.nights ?? []) {
            confirming = pending
            return
        }
        await apply(idea.swapChoice)
    }

    private func apply(_ choice: WeekStore.SwapChoice) async {
        isWorking = true
        defer { isWorking = false }
        if await TonightChoice.apply(choice, nightID: nightID, week: week, ideas: ideaStore, freezer: freezer) {
            chosen()
            dismiss()
        } else if case .freezer = choice {
            // Most likely someone took it out already: read the freezer again so it drops out of the ideas.
            await freezer?.load()
        }
    }
}

/// The sheet's rows, apart from the stores so previews can show each case.
struct RescueContent: View {
    @Binding var minutes: Int
    let forWhom: String?
    /// Nil while the library loads.
    let ideas: [TonightRescue.Idea]?
    /// The model's friendlier line for an idea, by id, when there is one. The code line still shows the facts.
    var wording: [String: String] = [:]
    let canPlan: Bool
    let canAsk: Bool
    var message: String? = nil
    var isDisabled = false
    var choose: (TonightRescue.Idea) -> Void = { _ in }
    var moreIdeas: () -> Void = {}
    var askFamily: () -> Void = {}

    var body: some View {
        List {
            if let message {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            Section {
                Picker("Time", selection: $minutes) {
                    ForEach(TonightRescue.minuteChoices, id: \.self) { minutes in
                        Text("\(minutes) min", comment: "Tonight rescue: how long there is to get dinner on the table")
                            .tag(minutes)
                    }
                }
                .pickerStyle(.segmented)
                if let forWhom {
                    Text(forWhom).font(.foonCaption).foregroundStyle(.secondary)
                }
            }
            Section {
                if let ideas {
                    ForEach(ideas) { idea in row(idea) }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Button("More ideas", systemImage: "arrow.clockwise", action: moreIdeas)
                    .tint(Palette.paprika)
                    .disabled(ideas == nil)
            } footer: {
                if !canPlan {
                    Text("A planner can make one tonight's dinner.")
                }
            }
            if canAsk {
                Section {
                    Button("Ask the family", systemImage: "checklist", action: askFamily)
                        .tint(Palette.paprika)
                        .disabled(ideas == nil)
                } footer: {
                    Text("Starts a quick vote with these ideas and Takeout.")
                }
            }
        }
        .disabled(isDisabled)
    }

    @ViewBuilder
    private func row(_ idea: TonightRescue.Idea) -> some View {
        let label = SwapRow.label(idea.title, allergies: idea.allergies,
                                  details: [wording[idea.id], idea.why].compactMap { $0 })
        if canPlan {
            Button { choose(idea) } label: { rowContent(idea) }
                .accessibilityLabel(label)
                .accessibilityHint("Makes it tonight's dinner")
        } else {
            rowContent(idea)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    private func rowContent(_ idea: TonightRescue.Idea) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: RescueRow.systemImage(idea.kind))
                .foregroundStyle(Palette.paprika)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(idea.title).font(.foonBody).foregroundStyle(Palette.ink)
                if let friendly = wording[idea.id] {
                    Text(friendly).font(.foonCaption).foregroundStyle(.secondary)
                    Text(idea.why).font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text(idea.why).font(.foonCaption).foregroundStyle(.secondary)
                }
                AllergyChips(check: idea.allergies)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Previews

private enum RescuePreview {
    static let samples = TonightRescue.Idea.samples
    static let family = Member.sampleFamily.map(\.firstName)

    static func filler(_ pick: QuickPick) -> TonightRescue.Idea {
        TonightRescue.Idea(kind: .quickPick(pick), title: DayCardText.quickPickLabel(pick),
                           why: TonightRescue.fillerWhy(pick), minutes: nil, isEstimate: false,
                           allergies: AllergyCheck(), swapChoice: .quickPick(pick))
    }
}

#Preview("Planner") {
    @Previewable @State var minutes = TonightRescue.defaultMinutes
    NavigationStack {
        RescueContent(minutes: $minutes, forWhom: RescueRow.forWhom(RescuePreview.family),
                      ideas: Array(RescuePreview.samples.prefix(3)), canPlan: true, canAsk: true)
            .navigationTitle("What can we make?")
    }
}

#Preview("Member") {
    @Previewable @State var minutes = 30
    NavigationStack {
        RescueContent(minutes: $minutes, forWhom: RescueRow.forWhom(RescuePreview.family),
                      ideas: Array(RescuePreview.samples.suffix(3)), canPlan: false, canAsk: true)
            .navigationTitle("What can we make?")
    }
}

#Preview("AI wording") {
    @Previewable @State var minutes = TonightRescue.defaultMinutes
    let ideas = Array(RescuePreview.samples.prefix(3))
    NavigationStack {
        RescueContent(minutes: $minutes, forWhom: RescueRow.forWhom(RescuePreview.family), ideas: ideas,
                      wording: [ideas[0].id: "Mac and cheese, ready to warm up",
                                ideas[2].id: "Crispy pizza with everything on hand"],
                      canPlan: true, canAsk: true)
            .navigationTitle("What can we make?")
    }
}

#Preview("Little in the house") {
    @Previewable @State var minutes = TonightRescue.defaultMinutes
    NavigationStack {
        RescueContent(minutes: $minutes, forWhom: RescueRow.forWhom(Array(RescuePreview.family.prefix(2))),
                      ideas: [RescuePreview.samples[2], RescuePreview.filler(.takeout),
                              RescuePreview.filler(.freezerRaid)],
                      canPlan: true, canAsk: false)
            .navigationTitle("What can we make?")
    }
}

#Preview("Whole sheet") {
    let household = HouseholdStore.preview()
    let week = WeekStore(householdID: Household.sample.id, client: .preview(started: true))
    return RescueSheet(nightID: UUID(), ai: .none)
        .environment(PollStore(client: .preview))
        .environment(household)
        .environment(week)
        .environment(DinnerStore(householdID: Household.sample.id, client: .preview))
        .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
        .environment(FreezerStore(householdID: Household.sample.id, client: .preview))
        .modelContainer(try! SyncService.inMemoryContainer())
        .task {
            await household.load()
            await week.load(settings: HouseholdSettings())
        }
}
