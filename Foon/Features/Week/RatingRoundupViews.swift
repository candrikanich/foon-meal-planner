import SwiftUI

/// The weekly roundup a tap on "Rate this week's dinners" opens: the week's dishes this person was home for and hasn't rated,
/// each with the same four reactions as the card. About the food, never the cook.
struct RatingRoundupSheet: View {
    @Environment(DinnerStore.self) private var dinner
    @Environment(HouseholdStore.self) private var household
    @Environment(\.dismiss) private var dismiss
    let week: CalendarDay
    @State private var prompts: [DinnerPrompts.Prompt]?
    @State private var failed = false

    private var settings: HouseholdSettings { household.household?.planningSettings ?? HouseholdSettings() }

    var body: some View {
        NavigationStack {
            List {
                if let prompts {
                    if prompts.isEmpty {
                        Label("All rated. Thanks!", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.herb)
                    }
                    ForEach(prompts) { prompt in
                        Section(prompt.night.date.date(in: settings.dayCalendar)
                            .formatted(.dateTime.weekday(.wide).month().day())) {
                            row(prompt)
                        }
                    }
                } else if failed {
                    Text("Couldn't load this week's dinners. Check your connection and try again.")
                    Button("Try again") { Task { await load() } }
                } else {
                    ProgressView()
                }
                if let message = dinner.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }
            .navigationTitle("This week's dinners")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func row(_ prompt: DinnerPrompts.Prompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.dishName ?? String(localized: "Dinner")).font(.foonHeadline)
            HStack {
                ForEach(ReactionKind.allCases, id: \.self) { kind in
                    Button {
                        Task { await rate(prompt, kind) }
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage).labelStyle(.iconOnly).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.paprika)
                    .disabled(dinner.saving.contains(prompt.night.id))
                    .accessibilityLabel(kind.title)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let me = household.me else { return }
        failed = false
        prompts = await dinner.unrated(me: me.id, settings: settings, week: week)
        failed = prompts == nil
    }

    private func rate(_ prompt: DinnerPrompts.Prompt, _ kind: ReactionKind) async {
        guard let me = household.me else { return }
        if await dinner.react(nightID: prompt.night.id, memberID: me.id, kind) {
            prompts?.removeAll { $0.id == prompt.id }
        }
    }
}

/// "Want these back?": a while after rating went weekly, once, on This Week. Yes brings back each night's prompt.
struct RatingsBackCard: View {
    @Environment(ReminderStore.self) private var reminders
    @Environment(HouseholdStore.self) private var household

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Want dinner ratings back each night?", systemImage: "fork.knife")
                .font(.foonHeadline)
            Text("Lately it's been a weekly roundup, since the nightly ones went unanswered.")
                .font(.foonCaption)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
            .font(.foonCaption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.cardSurface))
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Yes, each night") {
            guard let context = household.reminderContext else { return }
            Task { await reminders.takeRatingsBack(for: context) }
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.paprika)
        Button("Keep it weekly") {
            if let me = household.me { reminders.keepRatingsWeekly(for: me.id) }
        }
        .buttonStyle(.bordered)
    }
}

#Preview("Want these back?") {
    RatingsBackCard()
        .padding()
        .environment(ReminderStore(householdID: Household.sample.id, client: .preview))
        .environment(HouseholdStore.preview())
}

#Preview("Roundup") {
    let store = HouseholdStore.preview()
    RatingRoundupSheet(week: CalendarDay(year: 2026, month: 11, day: 1))
        .environment(DinnerStore(householdID: Household.sample.id, client: .preview))
        .environment(store)
        .task { await store.load() }
}
