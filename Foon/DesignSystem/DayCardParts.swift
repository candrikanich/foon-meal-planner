import SwiftUI

/// The pieces the hero and the rows share.
extension DayCard {
    /// A planner picks the effort from a menu; everyone else reads it. An away night has none.
    @ViewBuilder
    var effortControl: some View {
        if model.slot != .away {
            EffortMenu(effort: model.effort, onChange: actions.map { actions in { actions.setEffort($0) } })
        }
    }

    var lockMark: some View {
        Image(systemName: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "Locked"))
    }

    func attendance(size: CGFloat) -> some View {
        let shown = DayCardText.visibleAttendees(model.attendance)
        return HStack(spacing: 6) {
            ForEach(shown.visible) { attendee in
                let avatar = MemberAvatar(member: .fixture(id: attendee.memberID, firstName: attendee.firstName,
                                                            avatar: attendee.avatar), size: size)
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
                    .frame(minWidth: size, minHeight: size)
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

    var jobsLine: String? {
        DayCardText.softLine(model.jobs.map(DayCardText.jobLabel))
    }

    func busyRow(_ busy: BusySuggestion) -> some View {
        HStack(spacing: 8) {
            Button(action: busy.markRushed) {
                Label("Busy evening? Mark it rushed", systemImage: "calendar.badge.clock")
                    .font(.foonCaption)
            }
            .buttonStyle(.bordered)
            .tint(Palette.paprika)
            .controlSize(.small)
            .accessibilityHint(String(localized: "Changes the night's effort to rushed"))
            Spacer(minLength: 0)
            Button("Not this time", systemImage: "xmark", action: busy.dismiss)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.borderless)
                .tint(.secondary)
                .accessibilityLabel(String(localized: "Dismiss the busy evening suggestion"))
        }
    }

    func warningLines(font: Font) -> some View {
        ForEach(groups.warnings, id: \.self) { text in
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(font)
                .foregroundStyle(Palette.caution)
        }
    }

    func prepLines(font: Font) -> some View {
        ForEach(groups.prep, id: \.self) { text in
            Label(text, systemImage: "timer")
                .font(font)
                .foregroundStyle(.secondary)
        }
    }

    func servingNoteLines(font: Font) -> some View {
        ForEach(model.servingNotes, id: \.self) { note in
            Label(note, systemImage: "fork.knife")
                .font(font)
                .foregroundStyle(.secondary)
        }
    }

    /// Everything a planner can do to a night that has no button of its own on the card.
    @ViewBuilder
    func nightMenuItems(includeSwap: Bool) -> some View {
        if let actions {
            if includeSwap, let swap = actions.swap {
                Button("Swap", systemImage: "arrow.triangle.2.circlepath", action: swap)
            }
            if let shuffle = actions.shuffle {
                let isEmpty = model.slot == .empty
                Button(isEmpty ? String(localized: "Pick for me") : String(localized: "Shuffle this night"),
                       systemImage: isEmpty ? "wand.and.stars" : "shuffle", action: shuffle)
                    .disabled(model.isLocked)
            }
            if let toggleLock = actions.toggleLock {
                Button(model.isLocked ? String(localized: "Unlock night") : String(localized: "Lock night"),
                       systemImage: model.isLocked ? "lock.open" : "lock", action: toggleLock)
            }
        }
    }

    var hasNightMenu: Bool {
        guard let actions else { return false }
        return actions.shuffle != nil || actions.toggleLock != nil
    }
}
