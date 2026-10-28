import SwiftUI

/// First-run setup for the household's owner (docs/spec.md → Households and members, Meal library): who's at the
/// table, allergies (one question, skippable), the dinners they make, the household's rhythm, and invites
/// (skippable). Ends on This Week, ready for Build my week. A sample family fills itself in instead.
struct OnboardingFlow: View {
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(WeekStore.self) private var week
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case family, allergies, dinners, rhythm, invite
    }

    @State private var step: Step = .family
    @State private var model = OnboardingModel()
    @State private var settings = HouseholdSettings()
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if household.household?.planningSettings.samplePending == true {
                    SampleFamilySetup(onFinish: onFinish)
                } else {
                    stepView
                }
            }
            .safeAreaInset(edge: .top) {
                if household.household?.planningSettings.samplePending != true {
                    ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                        .tint(Palette.paprika)
                        .padding(.horizontal)
                        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                }
            }
        }
        .task {
            settings = household.household?.planningSettings ?? HouseholdSettings()
            if !library.hasLoaded { await library.load(members: household.members) }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .family:
            FamilyStep { step = .allergies }
        case .allergies:
            AllergyStep(model: model) { step = .dinners }
        case .dinners:
            DinnersStep(model: model) { step = .rhythm }
        case .rhythm:
            RhythmStep(settings: $settings) { step = .invite }
        case .invite:
            InviteStep {
                Task {
                    if await household.finishOnboarding(settings) { onFinish() }
                }
            }
        }
    }
}

// MARK: - Steps

private struct StepFooter: View {
    let primary: String
    var secondary: String?
    var isWorking = false
    let onPrimary: () -> Void
    var onSecondary: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onPrimary) {
                Text(primary).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.paprika)
            .disabled(isWorking)
            if let secondary, let onSecondary {
                Button(secondary, action: onSecondary).disabled(isWorking)
            }
        }
        .padding()
        .background(.bar)
    }
}

private struct FamilyStep: View {
    @Environment(HouseholdStore.self) private var household
    @State private var adding = false
    let onNext: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(household.visibleMembers) { member in
                    MemberRow(member: member, isYou: member.userID == household.userID)
                }
                Button("Add someone", systemImage: "person.badge.plus") { adding = true }
            } footer: {
                Text("Add everyone who eats with you, kids too. They can join on their own phones later.")
            }
        }
        .navigationTitle("Who's at your table?")
        .safeAreaInset(edge: .bottom) { StepFooter(primary: String(localized: "Next"), onPrimary: onNext) }
        .sheet(isPresented: $adding) { MemberEditorView(member: nil) }
    }
}

private struct AllergyStep: View {
    @Environment(HouseholdStore.self) private var household
    @Bindable var model: OnboardingModel
    let onNext: () -> Void
    @State private var hasAllergies = false
    @State private var isSaving = false

    var body: some View {
        List {
            if !hasAllergies {
                Section {
                    Text("Does anyone have food allergies?").font(.foonTitle)
                    Text("Foon flags dishes that contain them, and you plan as usual.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text(AllergyConsent.statement).font(.callout)
                }
                ForEach(household.visibleMembers) { member in
                    Section(member.firstName) {
                        AllergenChips(selection: binding(for: member).allergens)
                        TextField("Other (like kiwi)", text: otherBinding(for: member))
                    }
                }
                if let message = model.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Allergies")
        .safeAreaInset(edge: .bottom) {
            if hasAllergies {
                StepFooter(primary: String(localized: "Agree and save"), isWorking: isSaving, onPrimary: save)
            } else {
                StepFooter(primary: String(localized: "No allergies"), secondary: String(localized: "Yes, someone does"),
                           onPrimary: onNext, onSecondary: { hasAllergies = true })
            }
        }
    }

    private func binding(for member: Member) -> Binding<OnboardingModel.Answer> {
        Binding(get: { model.answers[member.id] ?? OnboardingModel.Answer() },
                set: { model.answers[member.id] = $0 })
    }

    private func otherBinding(for member: Member) -> Binding<String> {
        Binding(get: { model.answers[member.id]?.otherText ?? "" },
                set: { typed in
                    var answer = model.answers[member.id] ?? OnboardingModel.Answer()
                    answer.otherText = typed
                    model.answers[member.id] = answer
                })
    }

    private func save() {
        guard let householdID = household.household?.id else { return }
        Task {
            isSaving = true
            defer { isSaving = false }
            if await model.saveAllergies(householdID: householdID, client: household.client) { onNext() }
        }
    }
}

/// The nine major allergens as toggle chips.
private struct AllergenChips: View {
    @Binding var selection: Set<Allergen>

    var body: some View {
        ChipFlow(spacing: 8) {
            ForEach(Allergen.allCases.filter { $0 != .custom }, id: \.self) { allergen in
                let on = selection.contains(allergen)
                Button {
                    if on { selection.remove(allergen) } else { selection.insert(allergen) }
                } label: {
                    Text(allergen.displayName.localizedCapitalized)
                        .font(.foonCaption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(on ? Palette.onPaprika : Palette.ink)
                        .background(Capsule().fill(on ? Palette.caution : Palette.cardSurface))
                        .overlay(Capsule().strokeBorder(.quaternary))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DinnersStep: View {
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Bindable var model: OnboardingModel
    let onNext: () -> Void
    @State private var tab: DinnerPicker.Tab = .popular
    @State private var search = ""
    @State private var showAll = false
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                Text("Which of these does your family make?").font(.foonTitle)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DinnerPicker.tabs(library.catalog), id: \.self) { option in
                            Button(option.title) {
                                tab = option
                                showAll = false
                            }
                            .buttonStyle(.bordered)
                            .tint(tab == option ? Palette.paprika : .secondary)
                            .accessibilityAddTraits(tab == option ? .isSelected : [])
                        }
                    }
                }
            }
            Section {
                let dishes = DinnerPicker.visible(library.catalog, tab: tab, search: search, showAll: showAll)
                ForEach(dishes) { dish in
                    Button { model.toggle(dish) } label: { dishRow(dish) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.picked.contains(dish.id) ? .isSelected : [])
                }
                if search.isEmpty, !showAll,
                   DinnerPicker.visible(library.catalog, tab: tab, search: "", showAll: true).count > dishes.count {
                    Button("Show more") { showAll = true }
                }
            } footer: {
                Text("Tap the dinners your family already makes. You can add your own anytime.")
            }
            if library.catalog.isEmpty, let message = library.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("Try again") { Task { await library.load(members: household.members) } }
                }
            } else if let message = library.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .searchable(text: $search, prompt: Text("Search dinners"))
        .navigationTitle("Dinners")
        .safeAreaInset(edge: .bottom) {
            if model.picked.isEmpty {
                StepFooter(primary: String(localized: "Skip for now"), onPrimary: onNext)
            } else {
                StepFooter(primary: addTitle, secondary: String(localized: "Skip for now"), isWorking: isAdding,
                           onPrimary: add, onSecondary: onNext)
            }
        }
    }

    private var addTitle: String {
        let count = model.picked.count
        return count == 1 ? String(localized: "Add 1 dinner") : String(localized: "Add \(count) dinners")
    }

    private func dishRow(_ dish: CatalogDish) -> some View {
        let picked = model.picked.contains(dish.id)
        let flags = model.flags(for: dish, members: household.visibleMembers)
        return HStack(spacing: 12) {
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(picked ? Palette.herb : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(dish.name).font(.foonBody)
                ForEach(flags, id: \.self) { flag in
                    Label(flag.summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.foonCaption)
                        .foregroundStyle(Palette.caution)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// Adds what's picked; on any failure it stays here (the error shows, Skip still works) so a retry adds the rest.
    private func add() {
        let toAdd = library.catalog.filter { model.picked.contains($0.id) && !library.isInLibrary($0) }
        Task {
            isAdding = true
            defer { isAdding = false }
            var allAdded = true
            for dish in toAdd {
                if await library.add(dish) == nil { allAdded = false }
            }
            if allAdded { onNext() }
        }
    }
}

private struct RhythmStep: View {
    @Binding var settings: HouseholdSettings
    let onNext: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Plan on", selection: $settings.planningDay) { weekdayOptions }
                DatePicker("At", selection: time(\.planningTime), displayedComponents: .hourAndMinute)
            } header: {
                Text("When do you plan the week?")
            } footer: {
                Text("Foon reminds you then. Lots of families plan Sunday morning, before shopping.")
            }
            Section {
                Picker("Week starts", selection: $settings.weekStart) { weekdayOptions }
                DatePicker("Dinner at", selection: time(\.dinnerTime), displayedComponents: .hourAndMinute)
            } footer: {
                Text("The week starts on your shopping day.")
            }
            Section {
                Picker("Notifications", selection: $settings.notificationPreset) {
                    ForEach(HouseholdSettings.NotificationPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Light sends only what matters. You can change any of this later.")
            }
        }
        .navigationTitle("Your rhythm")
        .safeAreaInset(edge: .bottom) { StepFooter(primary: String(localized: "Next"), onPrimary: onNext) }
    }

    private var weekdayOptions: some View {
        ForEach(WeekMath.weekdays) { Text($0.name()).tag($0.iso) }
    }

    /// "HH:mm" in settings, a Date in the picker.
    private func time(_ key: WritableKeyPath<HouseholdSettings, String>) -> Binding<Date> {
        Binding(
            get: {
                let parts = settings[keyPath: key].split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: parts.first ?? 18, minute: parts.last ?? 0, second: 0,
                                             of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings[keyPath: key] = String(format: "%02d:%02d", parts.hour ?? 18, parts.minute ?? 0)
            }
        )
    }
}

private struct InviteStep: View {
    @Environment(HouseholdStore.self) private var household
    @State private var inviting: Member?
    let onDone: () -> Void

    private var invitable: [Member] { household.visibleMembers.filter { household.canInvite($0) } }

    var body: some View {
        List {
            Section {
                if invitable.isEmpty {
                    Text("Everyone's here. You can invite people later from Family.").foregroundStyle(.secondary)
                }
                ForEach(invitable) { member in
                    Button { inviting = member } label: {
                        MemberRow(member: member, isYou: false,
                                  invited: household.invitedMemberIDs.contains(member.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens their profile to send an invite")
                }
            } footer: {
                Text("Each person gets a link and a code to join on their own phone. Kids need a parent's OK first.")
            }
        }
        .navigationTitle("Invite your family")
        .safeAreaInset(edge: .bottom) {
            StepFooter(primary: String(localized: "Go to This Week"), onPrimary: onDone)
        }
        .sheet(item: $inviting) { member in MemberEditorView(member: member) }
    }
}

// MARK: - Sample family

/// Fills in the demo household: family, a kid's allergy, starter dishes, and a planned week.
private struct SampleFamilySetup: View {
    @Environment(HouseholdStore.self) private var household
    @Environment(LibraryStore.self) private var library
    @Environment(WeekStore.self) private var week
    let onFinish: () -> Void
    @State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            if failed {
                ContentUnavailableView {
                    Label("Couldn't set up the sample family", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try again") { Task { await run() } }
                }
            } else {
                ProgressView()
                Text("Setting up the sample family…").font(.foonHeadline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await run() }
    }

    private func run() async {
        failed = false
        guard let householdID = household.household?.id else { failed = true; return }
        let existing = Set(household.members.map(\.firstName))
        for draft in SampleFamily.members where !existing.contains(draft.firstName) {
            guard await household.save(draft, editing: nil) else { failed = true; return }
        }
        let model = OnboardingModel()
        for member in household.members {
            if let allergens = SampleFamily.allergies[member.firstName] {
                model.answers[member.id] = OnboardingModel.Answer(allergens: Set(allergens))
            }
        }
        guard await model.saveAllergies(householdID: householdID, client: household.client,
                                        consentVersion: AllergyConsent.sampleVersion) else { failed = true; return }
        await library.load(members: household.members)
        let dishes = SampleFamily.pick(from: library.catalog)
        for dish in dishes where !library.isInLibrary(dish) {
            await library.add(dish)
        }
        guard !dishes.isEmpty, dishes.allSatisfy(library.isInLibrary) else { failed = true; return }
        let settings = household.household?.planningSettings ?? HouseholdSettings()
        await week.load(settings: settings)
        await week.buildWeek {
            PlanningContext(meals: library.meals, history: library.history, settings: settings,
                            members: household.visibleMembers, traditions: week.traditions,
                            reactions: library.reactions)
        }
        guard week.errorMessage == nil, week.week?.nights.contains(where: { $0.mealID != nil }) == true,
              await household.finishOnboarding(settings) else { failed = true; return }
        onFinish()
    }
}

// MARK: - Previews

private struct OnboardingPreview<Content: View>: View {
    var household = HouseholdStore.preview()
    var library = LibraryStore(householdID: Household.sample.id, client: .preview(meals: []))
    var week = WeekStore(householdID: Household.sample.id, client: .preview())
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(household)
            .environment(library)
            .environment(week)
            .task {
                await household.load()
                await library.load(members: household.members)
            }
    }
}

#Preview("Onboarding") {
    OnboardingPreview { OnboardingFlow(onFinish: {}) }
}

#Preview("Allergies") {
    OnboardingPreview {
        NavigationStack { AllergyStep(model: OnboardingModel(), onNext: {}) }
    }
}

#Preview("Dinners, with a flagged kid") {
    let model = OnboardingModel()
    if let nora = Member.sampleFamily.first(where: { $0.firstName == "Nora" }) {
        model.answers[nora.id] = OnboardingModel.Answer(allergens: [.milk])
    }
    return OnboardingPreview {
        NavigationStack { DinnersStep(model: model, onNext: {}) }
    }
}

#Preview("Rhythm") {
    @Previewable @State var settings = HouseholdSettings()
    NavigationStack { RhythmStep(settings: $settings, onNext: {}) }
}
