import SwiftUI

/// Tonight: the night's whole story on one card, with one main action. Matches Figma "Quiet Kitchen → This Week".
extension DayCard {
    var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroHeader
            if let busy { busyRow(busy) }
            heroMeal
            if !model.attendance.isEmpty { whoIsEating }
            heroCook
            if !groups.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) { warningLines(font: .subheadline.weight(.medium)) }
            }
            heroButtons
            if let rescue { rescueLink(rescue) }
        }
        .foonCard()
    }

    private var heroHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                heroDay
                Spacer(minLength: 8)
                effortControl
            }
            VStack(alignment: .leading, spacing: 8) {
                heroDay
                effortControl
            }
        }
    }

    private var heroDay: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DayCardText.dayLabel(for: model.date, today: today))
                .font(.foonHeadline)
                .foregroundStyle(Palette.paprika)
            Text(DayCardText.dateLabel(for: model.date)).font(.foonCaption).foregroundStyle(.secondary)
            if model.isLocked { lockMark }
        }
    }

    @ViewBuilder
    private var heroMeal: some View {
        switch model.slot {
        case .empty:
            Text("Nothing planned yet").font(.foonTitle).foregroundStyle(.secondary)
        case .meal(let name, let photoURL, let reason, let sides):
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.foonLargeTitle).foregroundStyle(Palette.ink)
                    if let sides = DayCardText.sidesLabel(sides) {
                        Text(sides).font(.foonBody).foregroundStyle(Palette.ink)
                    }
                    if let line = DayCardText.softLine(groups.notes + [reason]) {
                        Text(line).font(.foonCaption).foregroundStyle(Palette.herb)
                    }
                    servingNoteLines(font: .foonCaption)
                    prepLines(font: .foonCaption)
                }
                if let photoURL {
                    Spacer(minLength: 0)
                    MealThumbnail(url: photoURL)
                }
            }
        case .quickPick(let pick):
            VStack(alignment: .leading, spacing: 4) {
                Text(DayCardText.quickPickLabel(pick)).font(.foonLargeTitle).foregroundStyle(Palette.ink)
                if let note = model.leftoversNote { Text(note).font(.foonBody).foregroundStyle(.secondary) }
                prepLines(font: .foonCaption)
            }
        case .away:
            Text("Away").font(.foonLargeTitle).foregroundStyle(.secondary)
        }
    }

    private var whoIsEating: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("Who's eating").font(.foonBody).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                attendance(size: 36)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Who's eating").font(.foonBody).foregroundStyle(Palette.ink)
                attendance(size: 36)
            }
        }
    }

    @ViewBuilder
    private var heroCook: some View {
        if let cook = model.cook {
            VStack(alignment: .leading, spacing: 2) {
                Text(DayCardText.cookLabel(cook)).font(.foonHeadline).foregroundStyle(Palette.ink)
                if let jobs = jobsLine { Text(jobs).font(.foonCaption).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
        } else {
            if let offer {
                Button(offer.title, systemImage: "frying.pan", action: offer.claim)
                    .buttonStyle(.pill(.tinted))
                    .disabled(offer.isDisabled)
                    .accessibilityHint(String(localized: "Tells the family you're cooking this night"))
            }
            if let jobs = jobsLine { Text(jobs).font(.foonCaption).foregroundStyle(.secondary) }
        }
    }

    private var heroButtons: some View {
        let layout = usesStackedLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            primaryButton
            if model.slot != .empty, let swap = actions?.swap {
                Button("Swap", action: swap).buttonStyle(.pill(.tinted, fullWidth: usesStackedLayout))
            }
            moreMenu
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.slot {
        case .meal:
            if let openNight {
                Button("View meal", action: openNight).buttonStyle(.pill(.prominent, fullWidth: true))
            }
        case .quickPick:
            if let openNight {
                Button("View night", action: openNight).buttonStyle(.pill(.prominent, fullWidth: true))
            }
        case .empty:
            if let swap = actions?.swap {
                Button("Add meal", action: swap).buttonStyle(.pill(.prominent, fullWidth: true))
            } else if let openNight {
                Button("View night", action: openNight).buttonStyle(.pill(.prominent, fullWidth: true))
            }
        case .away:
            EmptyView()
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        if hasNightMenu || openRecipe != nil {
            Menu {
                if let openRecipe { Button("Recipe", systemImage: "book", action: openRecipe) }
                nightMenuItems(includeSwap: false)
            } label: {
                Text("More")
            }
            .buttonStyle(.pill(.tinted, fullWidth: usesStackedLayout))
            .accessibilityLabel(String(localized: "More actions for this night"))
        }
    }

    private func rescueLink(_ rescue: @escaping () -> Void) -> some View {
        Button("What can we make?", systemImage: "lifepreserver", action: rescue)
            .buttonStyle(.plain)
            .font(.foonCaption.weight(.semibold))
            .foregroundStyle(Palette.paprika)
            .frame(minHeight: Metrics.minTapHeight)
            .accessibilityLabel(String(localized: "What can we make tonight?"))
            .accessibilityHint(String(localized: "Shows a few quick ideas from what's in the house"))
    }
}
