import Foundation

/// A dish swapped onto a night of an approved week, and what's missing for it (docs/spec.md → Pivots). The weekly list only
/// changes when someone taps Update the list, so gaps go straight on the quick list.
enum PivotGaps {
    /// What the list has open that bears on a gap.
    struct OpenLine: Equatable, Sendable {
        let itemID: UUID
        let note: String?
        var quantity: String?
        var isPivot = false
        /// On the quick list and marked for tonight: there's nothing a tonight swap could raise.
        var isTonight = false
        /// The week a pivot line was for. It says nothing about any other week.
        var planID: UUID?
    }

    /// Something to put on the quick list. It's news when the shopper would see a change in where it stands, a new line or one
    /// that's now for tonight, rather than only a note joining a line that's already there.
    struct Gap: Equatable, Sendable {
        let line: WeeklyList.Line
        let isNews: Bool
    }

    enum Outcome: Equatable, Sendable {
        /// The night's over or has no dish: nothing to buy.
        case nothing
        /// What's in stock, or in the dish, or who it's for isn't known. Not the same as nothing missing, so it has to be said.
        case couldntCheck
        /// `check`: already listed, with some other amount than this dish needs. The line keeps its own, so the shopper is told.
        case add([Gap], check: [WeeklyList.Line])
    }

    /// The whole decision for one swap. Who's home comes from `DoubleIt.listNight`, the same as the weekly list, so whoever eats
    /// the leftovers counts for its allergy notes.
    static func outcome(night: WeekNight, in layout: WeekLayout, logged: Set<UUID>, canTrustStock: Bool, canTrustLibrary: Bool,
                        library: [LibraryMeal], stock: [UUID: StockState], allergies: [MemberAllergies], open: [OpenLine],
                        today: CalendarDay) -> Outcome {
        guard !logged.contains(night.id), let mealID = night.mealID else { return .nothing }
        guard canTrustStock, canTrustLibrary, let meal = library.first(where: { $0.id == mealID }),
              !ShoppingLines.hasUnknownSide(meal, library: library) else { return .couldntCheck }
        let listNight = DoubleIt.listNight(night, in: layout, library: library, allergies: allergies)
        return .add(gaps(for: listNight, library: library, stock: stock, allergies: allergies, open: open,
                         tonight: night.date == today),
                    check: amountsToCheck(for: listNight, library: library, stock: stock, open: open))
    }

    /// The night's ingredients and sides that aren't in stock or listed already. An item already listed still comes through when
    /// it carries an allergy note no line of it has, since a shopper reading the older line wouldn't know, or when the dish is
    /// tonight's and it isn't marked for tonight yet.
    static func gaps(for night: WeeklyList.Night, library: [LibraryMeal], stock: [UUID: StockState],
                     allergies: [MemberAllergies], open: [OpenLine], tonight: Bool) -> [Gap] {
        WeeklyList.build(nights: [night], library: library, stock: stock, allergies: allergies).compactMap { line in
            let listed = open.filter { $0.itemID == line.itemID }
            let raised = tonight && !listed.contains(where: \.isTonight)
            if listed.isEmpty || raised { return Gap(line: line, isNews: true) }
            return listed.contains { ListNotes.covers($0.note, line.note) } ? nil : Gap(line: line, isNews: false)
        }
    }

    static func amountsToCheck(for night: WeeklyList.Night, library: [LibraryMeal], stock: [UUID: StockState],
                               open: [OpenLine]) -> [WeeklyList.Line] {
        WeeklyList.build(nights: [night], library: library, stock: stock).filter { line in
            let listed = open.filter { $0.itemID == line.itemID }
            return line.quantity != nil && !listed.isEmpty && !listed.contains { $0.quantity == line.quantity }
        }
    }

    /// Update the list after a pivot: what a pivot listed for this week doesn't go on the weekly list as well, unless the weekly
    /// line says more: another amount (doubled, or another night needs it too) or an allergy note.
    static func weekly(_ lines: [WeeklyList.Line], open: [OpenLine], planID: UUID?) -> [WeeklyList.Line] {
        lines.filter { line in
            !open.contains {
                $0.isPivot && $0.planID != nil && $0.planID == planID && $0.itemID == line.itemID && $0.quantity == line.quantity
                    && ListNotes.covers($0.note, line.note)
            }
        }
    }

    /// What This Week says after a swap: everything that changed on the list, and anything to look at.
    static func summary(gaps: [Gap], check: [WeeklyList.Line], tonight: Bool) -> String? {
        let noted = gaps.filter { !$0.isNews && $0.line.note != nil }.map(\.line.name)
        let amounts = check.map { String(localized: "\($0.name) (\($0.quantity ?? ""))", comment: "After a swap: an item and the amount the dish needs") }
        let parts = [
            message(names: gaps.filter(\.isNews).map(\.line.name), tonight: tonight),
            noted.isEmpty ? nil : String(localized: "Added an allergy note to \(noted.formatted(.list(type: .and))).",
                                         comment: "After a swap: an item already listed gained an allergy note"),
            amounts.isEmpty ? nil : String(localized: "Already listed, so check the amount: \(amounts.formatted(.list(type: .and))).",
                                           comment: "After a swap: already on the list with another amount than the dish needs")
        ]
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    static func message(names: [String], tonight: Bool) -> String? {
        guard !names.isEmpty else { return nil }
        let list = names.formatted(.list(type: .and))
        return tonight ? String(localized: "Added \(list) to the list for tonight.", comment: "After a swap: what's missing for tonight's dish")
                       : String(localized: "Added \(list) to the quick list.", comment: "After a swap: what's missing for that night's dish")
    }

    static var couldntCheckMessage: String {
        String(localized: "Couldn't check what this dish needs. Look over the list before you shop.",
               comment: "After a swap, when stock or the dish couldn't be read")
    }
}
