import SwiftUI

/// One night of the week (docs/spec.md → Day cards): effort chip, attendance avatars, the meal with
/// its reason chip, badges, and inline lock, shuffle, and swap. The same card serves This Week and
/// planning. Members get the read-only variant: pass no actions.
struct DayCard: View {
    /// What the planner can do on a card. Lock, shuffle, and swap appear once they're wired up.
    struct Actions {
        var toggleAttendance: (UUID) -> Void
        var cycleEffort: () -> Void
        var toggleLock: (() -> Void)? = nil
        var shuffle: (() -> Void)? = nil
        var swap: (() -> Void)? = nil
        /// Opens the night's detail; a real button so VoiceOver can reach it on an editable card.
        var open: (() -> Void)? = nil

        var hasNightActions: Bool { toggleLock != nil || shuffle != nil || swap != nil || open != nil }
    }

    /// "I'll cook Thursday": for anyone, so it's separate from what planners can do.
    struct ClaimOffer {
        let title: String
        var isDisabled = false
        let claim: () -> Void
    }

    let model: DayCardModel
    var today = CalendarDay(Date())
    var actions: Actions?
    var offer: ClaimOffer? = nil

    private var isTonight: Bool { model.date == today }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            mealSlot
            if !model.badges.isEmpty { badges }
            if !model.attendance.isEmpty { attendance }
            if let cook = model.cook { cookRow(cook) } else if let offer { claimButton(offer) }
            if !model.jobs.isEmpty { jobs }
            if let actions, actions.hasNightActions { actionRow(actions) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.cardSurface))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isTonight ? Palette.paprika : .clear, lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .accessibilityElement(children: actions == nil && offer == nil ? .ignore : .contain)
        .accessibilityLabel(DayCardText.accessibilitySummary(model, today: today))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(DayCardText.dayLabel(for: model.date, today: today))
                .font(.foonHeadline)
                .foregroundStyle(isTonight ? Palette.paprika : Palette.ink)
            Text(DayCardText.dateLabel(for: model.date))
                .font(.foonCaption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.slot == .away {
                EmptyView()
            } else if let actions {
                Button(action: actions.cycleEffort) { effortChip }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Effort: \(DayCardText.effortLabel(model.effort))"))
                    .accessibilityHint(String(localized: "Changes the night's effort"))
            } else {
                effortChip
            }
        }
    }

    private var effortChip: some View {
        Chip(text: DayCardText.effortLabel(model.effort), systemImage: effortSymbol,
             tint: model.effort == .event ? Palette.paprika : .secondary)
    }

    private var effortSymbol: String {
        switch model.effort {
        case .normal: "fork.knife"
        case .rushed: "hare"
        case .full: "clock"
        case .event: "party.popper"
        }
    }

    @ViewBuilder
    private var mealSlot: some View {
        switch model.slot {
        case .empty:
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(.tertiary)
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "plus").foregroundStyle(.tertiary))
                Text("Nothing planned yet").font(.foonBody).foregroundStyle(.secondary)
            }
        case .meal(let name, let photoURL, let reason, let sides):
            HStack(spacing: 12) {
                MealThumbnail(url: photoURL)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.foonTitle).foregroundStyle(Palette.ink).lineLimit(2)
                    if let sides = DayCardText.sidesLabel(sides) {
                        Text(sides).font(.foonCaption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    ForEach(model.servingNotes, id: \.self) { note in
                        Label(note, systemImage: "fork.knife")
                            .font(.foonCaption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if let reason { Chip(text: reason, systemImage: "sparkles") }
                }
            }
        case .quickPick(let pick):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.paprika.opacity(0.14))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: pick.systemImage).font(.title2).foregroundStyle(Palette.paprika))
                VStack(alignment: .leading, spacing: 4) {
                    Text(DayCardText.quickPickLabel(pick)).font(.foonTitle).foregroundStyle(Palette.ink)
                    if let note = model.leftoversNote {
                        Text(note).font(.foonCaption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        case .away:
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.herb.opacity(0.14))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "airplane").font(.title2).foregroundStyle(Palette.herb))
                Text("Away").font(.foonTitle).foregroundStyle(.secondary)
            }
        }
    }

    private var badges: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badgeChips }
            VStack(alignment: .leading, spacing: 6) { badgeChips }
        }
    }

    @ViewBuilder
    private var badgeChips: some View {
        ForEach(model.badges, id: \.self) { badge in
            switch badge {
            case .allergy:
                Chip(text: DayCardText.badgeLabel(badge), systemImage: "exclamationmark.triangle.fill", tint: Palette.caution)
            case .allergyUnchecked:
                Chip(text: DayCardText.badgeLabel(badge), systemImage: "questionmark.circle", tint: Palette.caution)
            case .tradition:
                Chip(text: DayCardText.badgeLabel(badge), systemImage: "repeat", tint: Palette.paprika)
            case .request:
                Chip(text: DayCardText.badgeLabel(badge), systemImage: "hand.raised.fill", tint: Palette.herb)
            case .prep:
                Chip(text: DayCardText.badgeLabel(badge), systemImage: "timer", tint: .secondary)
            case .equipment:
                Chip(text: DayCardText.badgeLabel(badge), systemImage: "frying.pan", tint: Palette.paprika)
            case .foodRule:
                Chip(text: DayCardText.badgeLabel(badge), systemImage: "fork.knife", tint: Palette.paprika)
            case .startCooking:
                Chip(text: DayCardText.badgeLabel(badge), systemImage: "flame", tint: .secondary)
            case .doubled:
                Chip(text: DayCardText.badgeLabel(badge), systemImage: "square.on.square", tint: Palette.herb)
            }
        }
    }

    private var attendance: some View {
        let shown = DayCardText.visibleAttendees(model.attendance)
        return HStack(spacing: -6) {
            ForEach(shown.visible) { attendee in
                let avatar = MemberAvatar(member: .fixture(id: attendee.memberID, firstName: attendee.firstName,
                                                            avatar: attendee.avatar), size: 32)
                    .opacity(attendee.isHome ? 1 : 0.35)
                    .overlay(alignment: .bottomTrailing) {
                        if !attendee.isHome {
                            Image(systemName: "moon.zzz.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                if let actions {
                    Button { actions.toggleAttendance(attendee.memberID) } label: { avatar }
                        .buttonStyle(.plain)
                        .accessibilityLabel(attendee.isHome
                            ? String(localized: "\(attendee.firstName), home")
                            : String(localized: "\(attendee.firstName), away"))
                        .accessibilityHint(String(localized: "Toggles whether they're home this night"))
                } else {
                    avatar
                }
            }
            if shown.hidden > 0 {
                let more = Text("+\(shown.hidden)")
                    .font(.foonCaption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, minHeight: 32)
                    .background(Circle().fill(.fill.tertiary))
                if let open = actions?.open {
                    Button(action: open) { more }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "\(shown.hidden) more people"))
                        .accessibilityHint(String(localized: "Opens the night to see everyone"))
                } else {
                    more.accessibilityHidden(true)
                }
            }
        }
    }

    private func cookRow(_ cook: DayCardModel.Cook) -> some View {
        HStack(spacing: 8) {
            MemberAvatar(member: .fixture(id: cook.memberID, firstName: cook.firstName, avatar: cook.avatar), size: 28)
            Text(DayCardText.cookLabel(cook))
                .font(.foonCaption)
                .foregroundStyle(Palette.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private func claimButton(_ offer: ClaimOffer) -> some View {
        Button(offer.title, systemImage: "frying.pan", action: offer.claim)
            .buttonStyle(.bordered)
            .tint(Palette.paprika)
            .controlSize(.small)
            .disabled(offer.isDisabled)
            .accessibilityHint(String(localized: "Tells the family you're cooking this night"))
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.jobs, id: \.self) { job in
                Label(DayCardText.jobLabel(job), systemImage: "checklist")
                    .font(.foonCaption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private func actionRow(_ actions: Actions) -> some View {
        HStack(spacing: 8) {
            Spacer()
            if let toggleLock = actions.toggleLock {
                Button(action: toggleLock) {
                    Image(systemName: model.isLocked ? "lock.fill" : "lock.open")
                }
                .accessibilityLabel(model.isLocked ? String(localized: "Unlock night") : String(localized: "Lock night"))
            }
            if let shuffle = actions.shuffle {
                Button(action: shuffle) { Image(systemName: model.slot == .empty ? "wand.and.stars" : "shuffle") }
                    .disabled(model.isLocked)
                    .accessibilityLabel(model.slot == .empty
                        ? String(localized: "Pick for me") : String(localized: "Shuffle this night"))
            }
            if let swap = actions.swap {
                Button(action: swap) { Image(systemName: "arrow.triangle.2.circlepath") }
                    .accessibilityLabel(String(localized: "Swap this night"))
            }
            if let open = actions.open {
                Button(action: open) { Image(systemName: "info.circle") }
                    .accessibilityLabel(String(localized: "Open night"))
            }
        }
        .buttonStyle(.bordered)
        .tint(Palette.paprika)
        .controlSize(.small)
    }
}

/// A meal's photo, or a warm placeholder tile until there is one.
struct MealThumbnail: View {
    let url: URL?
    var size: CGFloat = 56

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.herb.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                if let url {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                } else {
                    Image(systemName: "fork.knife").font(.title2).foregroundStyle(Palette.herb)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

private enum DayCardPreview {
    static let today = CalendarDay(Date())
    static let family: [DayCardModel.Attendee] = [
        .init(memberID: UUID(), firstName: "Ann", avatar: "🦉", isHome: true),
        .init(memberID: UUID(), firstName: "Ben", avatar: "🐻", isHome: true),
        .init(memberID: UUID(), firstName: "Owen", avatar: "🦊", isHome: false),
        .init(memberID: UUID(), firstName: "Nora", avatar: "🐢", isHome: true)
    ]
    static var actions: DayCard.Actions {
        DayCard.Actions(toggleAttendance: { _ in }, cycleEffort: {}, toggleLock: {}, shuffle: {}, swap: {})
    }
}

#Preview("States") {
    ScrollView {
        VStack(spacing: 16) {
            DayCard(model: .init(date: DayCardPreview.today, effort: .normal, slot: .empty,
                                 attendance: DayCardPreview.family, badges: [], isLocked: false),
                    actions: DayCardPreview.actions)
            DayCard(model: .init(date: DayCardPreview.today.adding(days: 1), effort: .rushed,
                                 slot: .meal(name: "Tacos", photoURL: nil, reason: "Nora's favorite"),
                                 attendance: DayCardPreview.family, badges: [.tradition("Taco Tuesday")], isLocked: false),
                    actions: DayCardPreview.actions)
            DayCard(model: .init(date: DayCardPreview.today.adding(days: 2), effort: .full,
                                 slot: .meal(name: "Pot roast", photoURL: nil, reason: "Haven't had it in 7 weeks",
                                             sides: ["mashed potatoes", "green beans"]),
                                 attendance: DayCardPreview.family,
                                 badges: [.equipment("Usually uses a grill"),
                                          .startCooking("Start cooking at 5:00 PM for 6:00 PM dinner"),
                                          .prep("Thaw tonight")],
                                 isLocked: true,
                                 servingNotes: ["Nora: keep everything separate before mixing", "Owen: no gravy"]),
                    actions: DayCardPreview.actions)
            DayCard(model: .init(date: DayCardPreview.today.adding(days: 3), effort: .event,
                                 slot: .quickPick(.eatOut), attendance: DayCardPreview.family,
                                 badges: [], isLocked: true),
                    actions: DayCardPreview.actions)
            DayCard(model: .init(date: DayCardPreview.today.adding(days: 5), effort: .normal,
                                 slot: .meal(name: "Chili", photoURL: nil, reason: "Due for a turn"),
                                 attendance: DayCardPreview.family, badges: [.doubled("Doubled: leftovers Friday")],
                                 isLocked: true),
                    actions: DayCardPreview.actions)
            DayCard(model: .init(date: DayCardPreview.today.adding(days: 6), effort: .rushed, slot: .quickPick(.leftovers),
                                 attendance: DayCardPreview.family, badges: [.allergy("Contains milk (Nora)")],
                                 isLocked: true, leftoversNote: "From Thursday's Chili"),
                    actions: DayCardPreview.actions)
            DayCard(model: .init(date: DayCardPreview.today.adding(days: 4), effort: .normal,
                                 slot: .meal(name: "Homemade mac and cheese", photoURL: nil, reason: "Owen's request"),
                                 attendance: DayCardPreview.family,
                                 badges: [.allergy("Contains milk (Nora)"), .request(from: "Owen")], isLocked: false),
                    actions: DayCardPreview.actions)
        }
        .padding()
    }
    .background(Palette.cream)
}

#Preview("Who's cooking, and jobs") {
    let family = Member.sampleFamily
    ScrollView {
        VStack(spacing: 16) {
            DayCard(model: .init(date: DayCardPreview.today.adding(days: 1), effort: .normal,
                                 slot: .meal(name: "Tacos", photoURL: nil, reason: nil),
                                 attendance: DayCardPreview.family, badges: [], isLocked: false),
                    offer: DayCard.ClaimOffer(title: "I'll cook tomorrow") {})
            DayCard(model: .init(date: DayCardPreview.today.adding(days: 2), effort: .normal,
                                 slot: .meal(name: "Chili", photoURL: nil, reason: nil),
                                 attendance: DayCardPreview.family, badges: [], isLocked: false,
                                 cook: .init(member: family[1], isYou: false, tense: .willCook),
                                 jobs: [.init(title: "Set the table", firstName: "Nora"),
                                        .init(title: "Do the dishes", firstName: "Owen")]))
            DayCard(model: .init(date: DayCardPreview.today.adding(days: 3), effort: .normal, slot: .empty,
                                 attendance: DayCardPreview.family, badges: [], isLocked: false,
                                 cook: .init(member: family[0], isYou: true, tense: .willCook)))
        }
        .padding()
    }
    .background(Palette.cream)
}

#Preview("Big family") {
    let family = (0..<10).map { index in
        DayCardModel.Attendee(memberID: UUID(), firstName: "Kid \(index)", avatar: ["🦊", "🐻", "🐢", "🦉"][index % 4],
                              isHome: index != 8)
    }
    DayCard(model: .init(date: DayCardPreview.today, effort: .normal,
                         slot: .meal(name: "Spaghetti", photoURL: nil, reason: "Due for a turn", sides: ["garlic bread"]),
                         attendance: family, badges: [], isLocked: false),
            actions: DayCard.Actions(toggleAttendance: { _ in }, cycleEffort: {}, open: {}))
        .padding()
        .background(Palette.cream)
}

#Preview("Read-only (member)") {
    DayCard(model: .init(date: DayCardPreview.today, effort: .rushed,
                         slot: .meal(name: "Tacos", photoURL: nil, reason: "Nora's favorite"),
                         attendance: DayCardPreview.family, badges: [.allergy("Contains milk (Nora)")], isLocked: true))
        .padding()
        .background(Palette.cream)
}
