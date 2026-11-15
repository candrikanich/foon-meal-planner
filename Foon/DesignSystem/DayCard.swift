import SwiftUI

/// One night of the week (docs/spec.md → Day cards). Tonight is a hero card with the night's whole story; every
/// other night is a quiet row. Planners shape a night from its card; members get the same words read-only (pass no
/// actions). The variants live in DayCardHero.swift and DayCardRow.swift.
struct DayCard: View {
    /// What the planner can do on a card. Lock, shuffle, and swap appear once they're wired up.
    struct Actions {
        var toggleAttendance: (UUID) -> Void
        var setEffort: (NightEffort) -> Void
        var toggleLock: (() -> Void)? = nil
        var shuffle: (() -> Void)? = nil
        var swap: (() -> Void)? = nil
        /// Opens the night's detail; a real button so VoiceOver can reach it on an editable card.
        var open: (() -> Void)? = nil
    }

    /// "I'll cook Thursday": for anyone, so it's separate from what planners can do.
    struct ClaimOffer {
        let title: String
        var isDisabled = false
        let claim: () -> Void
    }

    /// Calendar awareness (#64): the calendar looks busy around dinner. Planners only, and only ever a suggestion.
    struct BusySuggestion {
        let markRushed: () -> Void
        let dismiss: () -> Void
    }

    let model: DayCardModel
    var today = CalendarDay(Date())
    var actions: Actions?
    var offer: ClaimOffer? = nil
    /// "What can we make?" on tonight's card: anyone can look, so it's apart from the planner's actions.
    var rescue: (() -> Void)? = nil
    var busy: BusySuggestion? = nil
    /// Opens the dish's recipe (#267): for whoever's cooking, so anyone gets it, not just planners.
    var openRecipe: (() -> Void)? = nil
    /// Opens the night's detail: "View meal" on tonight, and the tap for VoiceOver on a row, which can't carry an
    /// action itself once it holds buttons. Nil on an away night, which has nothing to open.
    var openNight: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    var isTonight: Bool { model.date == today }
    var usesStackedLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    var groups: DayCardText.BadgeGroups { DayCardText.groupBadges(model.badges) }

    /// Nothing to tap, so VoiceOver reads the card as one summary.
    private var isReadOnly: Bool {
        actions == nil && offer == nil && rescue == nil && busy == nil && openRecipe == nil && openNight == nil
    }

    var body: some View {
        Group {
            if isTonight { hero } else { row }
        }
        .accessibilityElement(children: isReadOnly ? .ignore : .contain)
        .accessibilityLabel(DayCardText.accessibilitySummary(model, today: today))
    }
}

