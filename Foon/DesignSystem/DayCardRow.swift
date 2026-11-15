import SwiftUI

/// A night that isn't tonight: day, date and effort on the left, the meal beside it. Stacks at accessibility sizes.
extension DayCard {
    var row: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let busy { busyRow(busy) }
            let layout = usesStackedLayout
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
            layout {
                RowDayColumn(card: self)
                rowContent
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                rowTitle
                Spacer(minLength: 8)
                rowTrailingActions
            }
            rowDetails
            if let away = DayCardText.awayLine(model.attendance) {
                Text(away).font(.foonCaption).foregroundStyle(.secondary)
            }
            rowCook
        }
    }

    @ViewBuilder
    private var rowTitle: some View {
        switch model.slot {
        case .empty:
            Text("Nothing planned yet").font(.foonHeadline).foregroundStyle(Palette.ink)
        case .meal(let name, _, _, _):
            Text(name).font(.foonHeadline).foregroundStyle(Palette.ink)
        case .quickPick(let pick):
            Text(DayCardText.quickPickLabel(pick)).font(.foonHeadline).foregroundStyle(Palette.ink)
        case .away:
            Text("Away").font(.foonHeadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var rowDetails: some View {
        switch model.slot {
        case .meal(_, _, _, let sides):
            if let sides = DayCardText.sidesLabel(sides) { Text(sides).font(.foonBody).foregroundStyle(Palette.ink) }
            if let line = DayCardText.softLine(groups.notes) {
                Text(line).font(.foonCaption).foregroundStyle(Palette.herb)
            }
            servingNoteLines(font: .foonCaption)
            warningLines(font: .foonCaption)
            prepLines(font: .foonCaption)
        case .quickPick:
            if let note = model.leftoversNote { Text(note).font(.foonBody).foregroundStyle(.secondary) }
            warningLines(font: .foonCaption)
        case .empty:
            if let swap = actions?.swap {
                Button("Add meal", action: swap).buttonStyle(RowLinkStyle())
            }
        case .away:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rowCook: some View {
        if let cook = model.cook {
            Text(DayCardText.cookLabel(cook)).font(.foonCaption).foregroundStyle(Palette.ink)
            if let jobs = jobsLine { Text(jobs).font(.foonCaption).foregroundStyle(.secondary) }
        } else if let offer {
            Button(offer.title, action: offer.claim)
                .buttonStyle(RowLinkStyle())
                .disabled(offer.isDisabled)
                .accessibilityHint(String(localized: "Tells the family you're cooking this night"))
        }
    }

    @ViewBuilder
    private var rowTrailingActions: some View {
        if let openRecipe {
            Button("Recipe", action: openRecipe)
                .buttonStyle(RowLinkStyle())
                .accessibilityLabel(String(localized: "Open the recipe"))
                .accessibilityHint(String(localized: "Shows the dish's ingredients and steps"))
        }
        if actions?.swap != nil || hasNightMenu {
            Menu {
                nightMenuItems(includeSwap: true)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Palette.paprika)
                    .frame(minWidth: Metrics.minTapHeight, minHeight: Metrics.minTapHeight)
                    .contentShape(.rect)
            }
            .accessibilityLabel(String(localized: "More actions for this night"))
        }
    }
}

/// The day, its date and its effort: the left column of a row.
private struct RowDayColumn: View {
    let card: DayCard
    @ScaledMetric private var width: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DayCardText.dayLabel(for: card.model.date, today: card.today))
                .font(.foonHeadline)
                .foregroundStyle(Palette.ink)
            HStack(spacing: 6) {
                Text(DayCardText.dateLabel(for: card.model.date)).font(.foonCaption).foregroundStyle(.secondary)
                if card.model.isLocked { card.lockMark }
            }
            card.effortControl
        }
        .frame(width: card.usesStackedLayout ? nil : width, alignment: .leading)
    }
}

/// Paprika text with a full-size tap area: "Recipe", "Add meal", "I'll cook Thursday".
private struct RowLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.foonCaption.weight(.semibold))
            .foregroundStyle(Palette.paprika)
            .frame(minHeight: Metrics.minTapHeight)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
