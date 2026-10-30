import SwiftUI

/// The after-dinner cards at the top of This Week (docs/spec.md → After-dinner loop): "Chili last night?" with one-tap
/// reactions about the food, then the first responder's leftovers and who cooked. In-app until push arrives (M2 car 6).
/// The sheets live here, not on a card: a card goes away once you rate, and Pass the phone must stay open for the rest.
struct DinnerPromptsSection: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(HouseholdStore.self) private var household
    @State private var sheet: DinnerSheet?

    enum DinnerSheet: Identifiable {
        case passThePhone(UUID)
        case hadInstead(UUID)

        var id: String {
            switch self {
            case .passThePhone(let night): "phone-\(night)"
            case .hadInstead(let night): "instead-\(night)"
            }
        }
    }

    var body: some View {
        if let me = household.me {
            let settings = household.household?.planningSettings ?? HouseholdSettings()
            // Re-checked every minute, so the card appears an hour after dinner with the app left open.
            TimelineView(.everyMinute) { context in
                VStack(spacing: 12) {
                    ForEach(DinnerPrompts.rates(me) ? dinner.prompts(me: me.id, settings: settings, at: context.date) : []) { prompt in
                        DinnerCard(prompt: prompt, me: me, open: { sheet = $0 })
                    }
                    ForEach(dinner.extras(me: me.id, settings: settings, at: context.date)) { prompt in
                        DinnerExtrasCard(prompt: prompt)
                    }
                    ForEach(dinner.recentlyCooked(me: me.id, settings: settings, at: context.date)) { log in
                        if let cook = household.members.first(where: { $0.id == log.cookedByMemberID }) {
                            ThanksChefCard(log: log, cook: cook, me: me)
                        }
                    }
                    if sheet == nil, let message = dinner.errorMessage {
                        Text(message).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .passThePhone(let night): PassThePhoneSheet(nightID: night, me: me)
                case .hadInstead(let night): HadInsteadSheet(nightID: night)
                }
            }
        }
    }
}

/// One night's "How was it?": four reactions, then We had something else, Wasn't home, and Pass the phone.
struct DinnerCard: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(\.dynamicTypeSize) private var typeSize
    let prompt: DinnerPrompts.Prompt
    let me: Member
    let open: (DinnerPromptsSection.DinnerSheet) -> Void
    @State private var confirmingNotHome = false

    private var question: String {
        let dish = prompt.dishName ?? String(localized: "Dinner")
        return prompt.night.date == dinner.today
            ? String(localized: "\(dish) tonight?", comment: "After-dinner card: the dish, then the question")
            : String(localized: "\(dish) last night?", comment: "After-dinner card: the dish, then the question")
    }

    private var isSaving: Bool { dinner.saving.contains(prompt.night.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question).font(.foonHeadline).foregroundStyle(Palette.ink)
            ReactionRow(selected: nil, disabled: isSaving) { kind in
                Task { await dinner.react(nightID: prompt.night.id, memberID: me.id, kind) }
            }
            actions
                .font(.foonCaption)
                .buttonStyle(.borderless)
                .tint(Palette.paprika)
                .disabled(isSaving)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
        .confirmationDialog("You weren't home for dinner?", isPresented: $confirmingNotHome, titleVisibility: .visible) {
            Button("I wasn't home") { Task { await dinner.notHome(nightID: prompt.night.id, memberID: me.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The card goes away and you're marked away for that night.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                                  : AnyLayout(HStackLayout(spacing: 16))
        layout {
            if dinner.canChangeDish(nightID: prompt.night.id) {
                Button("We had something else") { open(.hadInstead(prompt.night.id)) }
            }
            Button("Wasn't home") { confirmingNotHome = true }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button("Pass the phone", systemImage: "person.2") { open(.passThePhone(prompt.night.id)) }
                .labelStyle(typeSize.isAccessibilitySize ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                .accessibilityHint("Everyone at the table rates on this phone")
        }
    }
}

/// A label style chosen at runtime.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<Style: LabelStyle>(_ style: Style) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// The four reactions, as big tappable chips (a 2×2 grid at accessibility sizes). Always about the dish.
struct ReactionRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let selected: ReactionKind?
    var disabled = false
    let onPick: (ReactionKind) -> Void

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 2 : 4)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(ReactionKind.allCases, id: \.self) { kind in
                let on = selected == kind
                Button { onPick(kind) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: kind.systemImage).font(.title3)
                        Text(kind.title).font(.foonCaption).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .padding(.vertical, 4)
                    .foregroundStyle(on ? Palette.onPaprika : Palette.ink)
                    .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.paprika : Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// After the first reaction: leftovers (pre-filled with the guess) and, for a dish, who cooked; then Save.
struct DinnerExtrasCard: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(HouseholdStore.self) private var household
    let prompt: DinnerPrompts.Prompt
    @State private var leftovers: Bool?
    /// Starts with who offered to cook, if anyone, so a tap only corrects it.
    @State private var cook: UUID?
    /// What the server said when `cook` was last in step: Save sends the cook only if this person changed it.
    @State private var startedFrom: UUID?

    init(prompt: DinnerPrompts.Prompt) {
        self.prompt = prompt
        _cook = State(initialValue: prompt.log?.cookedByMemberID)
        _startedFrom = State(initialValue: prompt.log?.cookedByMemberID)
    }

    var body: some View {
        let guess = DinnerPrompts.expectsLeftovers(prompt.night)
        let cooked = prompt.log?.mealID != nil
        VStack(alignment: .leading, spacing: 12) {
            Text("Thanks! Anything left over?").font(.foonHeadline).foregroundStyle(Palette.ink)
            Picker("Leftovers", selection: Binding(get: { leftovers ?? guess }, set: { leftovers = $0 })) {
                Text("Leftovers").tag(true)
                Text("All gone").tag(false)
            }
            .pickerStyle(.segmented)
            if cooked {
                Text("Who cooked?").font(.foonCaption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(household.visibleMembers.filter { !$0.eatsSeparately || $0.id == cook }) { member in
                            Button { cook = cook == member.id ? nil : member.id } label: {
                                VStack(spacing: 4) {
                                    MemberAvatar(member: member, size: 36)
                                        .overlay(Circle().strokeBorder(Palette.paprika,
                                                                       lineWidth: cook == member.id ? 3 : 0))
                                    Text(member.firstName).font(.foonCaption).foregroundStyle(Palette.ink)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(member.firstName)
                            .accessibilityAddTraits(cook == member.id ? .isSelected : [])
                        }
                    }
                }
            }
            Button("Save") {
                Task {
                    await dinner.saveExtras(nightID: prompt.night.id, leftovers: leftovers ?? guess, cookedBy: cook,
                                            startedFrom: startedFrom)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.paprika)
            .disabled(dinner.saving.contains(prompt.night.id))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
        // Someone took them off as the cook on another phone: follow it, unless this person has already picked.
        .onChange(of: prompt.log?.cookedByMemberID) { _, latest in
            if cook == startedFrom { cook = latest }
            startedFrom = latest
        }
    }
}

/// Cook credit: "Ann cooked the chili" with a one-tap Thanks, chef for everyone else; the cook sees their thanks, and can
/// say "That wasn't me" until someone has thanked them.
/// Only shown when the cook is someone in the family (the section filters), so it never renders empty.
struct ThanksChefCard: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(\.dynamicTypeSize) private var typeSize
    let log: DinnerLog
    let cook: Member
    let me: Member

    var body: some View {
        let thanks = dinner.thanks(for: log.id)
        let dish = log.mealName ?? String(localized: "dinner")
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                                  : AnyLayout(HStackLayout(spacing: 12))
        layout {
            MemberAvatar(member: cook, size: 32)
            if cook.id == me.id {
                Text(Self.cookLine(thanks: thanks.count, dish: dish)).font(.foonBody)
                if CookCredit.canTakeOffCook(log, thanks: thanks, me: me, canPlan: false, members: [me, cook]) {
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Button("That wasn't me") { Task { await dinner.takeOffCook(log) } }
                        .buttonStyle(.bordered)
                        .tint(Palette.paprika)
                        .disabled(dinner.saving.contains(log.nightID))
                        .accessibilityHint("Takes you off as the cook for this dinner")
                }
            } else {
                Text("\(cook.firstName) cooked the \(dish)").font(.foonBody)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if thanks.contains(where: { $0.fromMemberID == me.id }) {
                    Label("Thanked", systemImage: "checkmark").font(.foonCaption).foregroundStyle(Palette.herb)
                } else {
                    Button("Thanks, chef") { Task { await dinner.thankTheChef(log) } }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.paprika)
                        .disabled(dinner.saving.contains(log.nightID))
                        .accessibilityHint("Thanks \(cook.firstName) for dinner")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cardSurface))
    }

    /// What the cook sees: warm with or without thanks yet, never a count of zero.
    static func cookLine(thanks: Int, dish: String) -> String {
        switch thanks {
        case 0: String(localized: "Thanks for cooking the \(dish)")
        case 1: String(localized: "Thanked once for the \(dish)")
        case 2: String(localized: "Thanked twice for the \(dish)")
        default: String(localized: "Thanked \(thanks) times for the \(dish)")
        }
    }
}

/// Pass the phone: everyone home rates on this phone in about 20 seconds. You and profiles without an account of their
/// own can be rated (or marked not home) here; anyone with their own account rates on theirs, shown read-only.
struct PassThePhoneSheet: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(HouseholdStore.self) private var household
    @Environment(\.dismiss) private var dismiss
    let nightID: UUID
    let me: Member

    private var night: WeekNight? { dinner.nights.first { $0.id == nightID } }

    private var home: [Member] {
        guard let night else { return [] }
        return DinnerPrompts.whoRates(among: household.visibleMembers.filter { night.attendance[$0.id] == true })
    }

    var body: some View {
        NavigationStack {
            List {
                let raters = DinnerPrompts.raters(home: home, me: me.id)
                Section {
                    ForEach(raters) { member in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                MemberAvatar(member: member, size: 32)
                                Text(member.firstName).font(.foonHeadline)
                                Spacer()
                                Button("Wasn't home") {
                                    Task { await dinner.notHome(nightID: nightID, memberID: member.id) }
                                }
                                .font(.foonCaption)
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(member.firstName) wasn't home")
                            }
                            ReactionRow(selected: dinner.log(for: nightID)?.reaction(of: member.id)?.kind,
                                        disabled: dinner.saving.contains(nightID)) { kind in
                                Task { await dinner.react(nightID: nightID, memberID: member.id, kind) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    if let message = dinner.errorMessage {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Rate the food, not the cook. Changes are fine for a day.")
                    }
                }
                let others = home.filter { member in !raters.contains { $0.id == member.id } }
                if !others.isEmpty {
                    Section("On their own phones") {
                        ForEach(others) { member in
                            LabeledContent(member.firstName,
                                           value: dinner.log(for: nightID)?.reaction(of: member.id)?.kind.title
                                               ?? String(localized: "Not yet"))
                        }
                    }
                }
            }
            .navigationTitle("Pass the phone")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { dinner.clearError() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

/// "We had something else": a dish from the library or a quick pick.
struct HadInsteadSheet: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(LibraryStore.self) private var library
    @Environment(HouseholdStore.self) private var household
    @Environment(WeekStore.self) private var week: WeekStore?
    @Environment(\.dismiss) private var dismiss
    let nightID: UUID
    @State private var search = ""

    private var meals: [LibraryMeal] {
        let inRotation = library.meals.filter(\.status.isInRotation).sorted { $0.name < $1.name }
        let typed = search.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? inRotation : inRotation.filter { $0.name.localizedStandardContains(typed) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = dinner.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
                if search.isEmpty {
                    Section("Quick picks") {
                        ForEach(QuickPick.allCases, id: \.self) { pick in
                            Button(DayCardText.quickPickLabel(pick)) { choose(.quickPick(pick)) }
                        }
                    }
                }
                Section("From your meals") {
                    ForEach(meals) { meal in
                        Button(meal.name) { choose(.meal(meal.id)) }
                    }
                }
            }
            .searchable(text: $search, prompt: Text("Search your meals"))
            .navigationTitle("What did you have?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .disabled(dinner.saving.contains(nightID))
            .onAppear { dinner.clearError() }
            // With the family, like every other library load, so allergy flags stay right everywhere.
            .task { if !library.hasLoaded { await library.load(members: household.members) } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
    }

    private func choose(_ instead: DinnerStore.Instead) {
        Task {
            if await dinner.hadInstead(nightID: nightID, instead) {
                // The server let go of a leftovers night or freezer dinner that depended on this one.
                await week?.refresh()
                dismiss()
            }
        }
    }
}

// MARK: - Previews

private let previewNight = WeekNight(
    id: UUID(), date: CalendarDay(Date()).adding(days: -1), effort: .normal, dinnerTime: "18:00", mealID: UUID(),
    mealName: "chili", quickPick: nil, locked: false,
    attendance: Dictionary(uniqueKeysWithValues: Member.sampleFamily.map { ($0.id, true) })
)

private let previewCookedLog = DinnerLog(
    id: UUID(), nightID: previewNight.id, date: previewNight.date, mealID: previewNight.mealID, mealName: "chili",
    quickPick: nil, cookedByMemberID: Member.sampleFamily[1].id
)

private struct DinnerPreview<Content: View>: View {
    var household = HouseholdStore.preview()
    var dinner = DinnerStore(householdID: Household.sample.id, client: .preview)
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(household)
            .environment(dinner)
            .environment(LibraryStore(householdID: Household.sample.id, client: .preview()))
            .task { await household.load() }
    }
}

#Preview("After dinner") {
    DinnerPreview {
        ScrollView {
            DinnerCard(prompt: DinnerPrompts.Prompt(night: previewNight, log: nil), me: Member.sampleFamily[0],
                       open: { _ in })
                .padding()
        }
        .background(Palette.cream)
    }
}

#Preview("After dinner, accessibility size") {
    DinnerPreview {
        ScrollView {
            DinnerCard(prompt: DinnerPrompts.Prompt(night: previewNight, log: nil), me: Member.sampleFamily[0],
                       open: { _ in })
                .padding()
        }
        .background(Palette.cream)
        .dynamicTypeSize(.accessibility2)
    }
}

#Preview("Leftovers and who cooked") {
    DinnerPreview {
        DinnerExtrasCard(prompt: DinnerPrompts.Prompt(night: previewNight, log: nil))
            .padding()
            .background(Palette.cream)
    }
}

#Preview("Thanks, chef") {
    DinnerPreview {
        VStack(spacing: 12) {
            ThanksChefCard(log: previewCookedLog, cook: Member.sampleFamily[1], me: Member.sampleFamily[0])
            ThanksChefCard(log: previewCookedLog, cook: Member.sampleFamily[1], me: Member.sampleFamily[1])
        }
        .padding()
        .background(Palette.cream)
    }
}

#Preview("Thanks, chef, accessibility size") {
    DinnerPreview {
        ThanksChefCard(log: previewCookedLog, cook: Member.sampleFamily[1], me: Member.sampleFamily[0])
            .padding()
            .background(Palette.cream)
            .dynamicTypeSize(.accessibility2)
    }
}

#Preview("Pass the phone") {
    DinnerPreview {
        PassThePhoneSheet(nightID: previewNight.id, me: Member.sampleFamily[0])
    }
}

#Preview("We had something else") {
    DinnerPreview {
        HadInsteadSheet(nightID: previewNight.id)
    }
}
