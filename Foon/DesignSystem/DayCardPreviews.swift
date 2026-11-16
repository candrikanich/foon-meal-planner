import SwiftUI

private extension DayCardModel {
    var hasDish: Bool {
        if case .meal = slot { true } else { false }
    }
}

@MainActor
private enum DayCardPreview {
    static let today = CalendarDay(Date())
    static let family: [DayCardModel.Attendee] = [
        .init(memberID: UUID(), firstName: "Ann", avatar: "🦉", isHome: true),
        .init(memberID: UUID(), firstName: "Ben", avatar: "🐻", isHome: true),
        .init(memberID: UUID(), firstName: "Owen", avatar: "🦊", isHome: false),
        .init(memberID: UUID(), firstName: "Nora", avatar: "🐢", isHome: true)
    ]
    static let cook = DayCardModel.Cook(member: Member.sampleFamily[0], isYou: false, tense: .willCook)
    static let jobs: [DayCardModel.JobLine] = [.init(title: "Set the table", firstName: "Nora"),
                                               .init(title: "Do the dishes", firstName: "Owen")]

    /// `start` nil is a prep step alone; a nil `prep` is the cook window alone.
    static func prepLine(_ prep: String?, start: Int?, dinner: Int, estimate: Bool = false) -> DayCardModel.Badge {
        let window = start.map { StartCooking(cookMinutes: dinner - $0, isEstimate: estimate, startMinute: $0,
                                              dinnerMinute: dinner) }
        return .prepLine(PrepLine.make(prep: prep, start: window, locale: Locale(identifier: "en_US")) ?? PrepLine(""))
    }

    static let prepLineCases: [DayCardModel] = [
        night(0, slot: .meal(name: "Pot roast", reason: nil), badges: [prepLine("Thaw tonight", start: 15 * 60, dinner: 18 * 60)]),
        night(1, slot: .meal(name: "Grilled chicken", reason: nil), badges: [prepLine("Marinate · 4 hours ahead", start: nil, dinner: 0)]),
        night(2, slot: .meal(name: "Tacos", reason: nil), badges: [prepLine(nil, start: 17 * 60 + 30, dinner: 18 * 60, estimate: true)]),
        night(3, slot: .meal(name: "Chili", reason: nil), badges: [prepLine(nil, start: 9 * 60, dinner: 18 * 60, estimate: true)]),
        night(4, slot: .meal(name: "Pasta", reason: nil))
    ]

    static var actions: DayCard.Actions {
        DayCard.Actions(toggleAttendance: { _ in }, setEffort: { _ in }, toggleLock: {}, shuffle: {}, swap: {}, open: {})
    }

    static func night(_ offset: Int, effort: NightEffort = .normal, slot: DayCardModel.Slot,
                      badges: [DayCardModel.Badge] = [], locked: Bool = false, notes: [String] = [],
                      leftovers: String? = nil, cook: DayCardModel.Cook? = nil,
                      jobs: [DayCardModel.JobLine] = []) -> DayCardModel {
        DayCardModel(date: today.adding(days: offset), effort: effort, slot: slot, attendance: family, badges: badges,
                     isLocked: locked, servingNotes: notes, leftoversNote: leftovers, cook: cook, jobs: jobs)
    }

    static let tacos = night(0, effort: .rushed, slot: .meal(name: "Tacos", reason: "Nora's favorite",
                                                              sides: ["rice", "black beans"]),
                             badges: [.tradition("Taco Tuesday"), .allergy("Contains milk (Nora)")],
                             cook: cook, jobs: jobs)
    static let potRoast = night(1, effort: .full,
                                slot: .meal(name: "Pot roast", reason: "Haven't had it in 7 weeks",
                                            sides: ["mashed potatoes", "green beans"]),
                                badges: [prepLine("Thaw tonight", start: 15 * 60, dinner: 18 * 60)],
                                locked: true, notes: ["Nora: keep everything separate before mixing"])
    static let empty = night(2, slot: .empty)
    static let crab = night(3, effort: .event, slot: .meal(name: "Crab legs", reason: nil),
                            badges: [.request(from: "Nora"), .equipment("Usually uses a grill")])
    static let eatOut = night(4, effort: .event, slot: .quickPick(.eatOut), locked: true)
    static let leftovers = night(5, effort: .rushed, slot: .quickPick(.leftovers), badges: [.allergy("Contains milk (Nora)")],
                                 leftovers: "From Thursday's Chili")
    static let away = night(6, slot: .away)
    static let longText = night(
        1, slot: .meal(name: "Slow-roasted shoulder of lamb with preserved lemon and olives", reason: nil,
                       sides: ["herbed couscous", "charred broccolini", "yogurt and mint sauce"]),
        badges: [.allergy("Contains tree nuts (Nora) and sesame (Owen)"), prepLine("Marinate the lamb the night before", start: nil, dinner: 0)])

    static func board<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 0) { content() }.padding()
        }
        .background(Palette.cream)
    }

    static func rows(_ models: [DayCardModel]) -> some View {
        ForEach(Array(models.enumerated()), id: \.offset) { index, model in
            if index > 0 { Divider() }
            DayCard(model: model, actions: actions, openRecipe: model.hasDish ? {} : nil, openNight: {})
        }
    }
}

#Preview("Tonight, planner") {
    DayCardPreview.board {
        DayCard(model: DayCardPreview.tacos, actions: DayCardPreview.actions, openRecipe: {}, openNight: {})
    }
}

#Preview("Tonight, member") {
    DayCardPreview.board {
        DayCard(model: DayCardPreview.tacos, openNight: {})
    }
}

#Preview("Tonight, rescue and busy evening") {
    DayCardPreview.board {
        DayCard(model: DayCardPreview.tacos, actions: DayCardPreview.actions, rescue: {},
                busy: .init(markRushed: {}, dismiss: {}), openNight: {})
    }
}

#Preview("Tonight, nobody cooking yet") {
    DayCardPreview.board {
        DayCard(model: DayCardPreview.night(0, slot: .meal(name: "Chili", reason: "Due for a turn")),
                actions: DayCardPreview.actions, offer: .init(title: "I'll cook tonight") {}, openNight: {})
    }
}

#Preview("Tonight, empty, quick pick and away") {
    DayCardPreview.board {
        VStack(spacing: 16) {
            DayCard(model: DayCardPreview.night(0, slot: .empty), actions: DayCardPreview.actions, rescue: {})
            DayCard(model: DayCardPreview.night(0, effort: .event, slot: .quickPick(.eatOut), locked: true),
                    actions: DayCardPreview.actions, openNight: {})
            DayCard(model: DayCardPreview.night(0, slot: .away))
        }
    }
}

#Preview("Later nights") {
    DayCardPreview.board {
        DayCardPreview.rows([DayCardPreview.potRoast, DayCardPreview.empty, DayCardPreview.crab, DayCardPreview.eatOut,
                             DayCardPreview.leftovers, DayCardPreview.away])
    }
}

#Preview("Later nights, member, claim") {
    DayCardPreview.board {
        DayCard(model: DayCardPreview.potRoast, offer: .init(title: "I'll cook tomorrow") {}, openRecipe: {},
                openNight: {})
        Divider()
        DayCard(model: DayCardPreview.night(2, slot: .meal(name: "Chili", reason: nil),
                                            cook: DayCardPreview.cook, jobs: DayCardPreview.jobs), openNight: {})
        Divider()
        DayCard(model: DayCardPreview.empty)
    }
}

#Preview("Later nights, dark") {
    DayCardPreview.board {
        DayCardPreview.rows([DayCardPreview.potRoast, DayCardPreview.empty, DayCardPreview.crab])
    }
    .preferredColorScheme(.dark)
}

#Preview("Tonight and nights, AX3") {
    DayCardPreview.board {
        DayCard(model: DayCardPreview.tacos, actions: DayCardPreview.actions, openRecipe: {}, openNight: {})
        DayCardPreview.rows([DayCardPreview.potRoast, DayCardPreview.empty])
    }
    .dynamicTypeSize(.accessibility3)
}

#Preview("Long text") {
    DayCardPreview.board {
        DayCard(model: DayCardPreview.night(0, slot: .meal(name: "Slow-roasted shoulder of lamb with preserved lemon",
                                                           reason: "Haven't had it in 12 weeks",
                                                           sides: ["herbed couscous", "charred broccolini"]),
                                            badges: [.allergy("Contains tree nuts (Nora) and sesame (Owen)")],
                                            cook: DayCardPreview.cook, jobs: DayCardPreview.jobs),
                actions: DayCardPreview.actions, openNight: {})
        DayCardPreview.rows([DayCardPreview.longText])
    }
}

#Preview("Big family") {
    let family = (0..<10).map { index in
        DayCardModel.Attendee(memberID: UUID(), firstName: "Kid \(index)", avatar: ["🦊", "🐻", "🐢", "🦉"][index % 4],
                              isHome: index != 8)
    }
    DayCardPreview.board {
        DayCard(model: .init(date: DayCardPreview.today, effort: .normal,
                             slot: .meal(name: "Spaghetti", reason: "Due for a turn", sides: ["garlic bread"]),
                             attendance: family, badges: [], isLocked: false),
                actions: DayCardPreview.actions, openNight: {})
    }
}

#Preview("Prep line: both, prep only, times only, slow cooker, none") {
    DayCardPreview.board { DayCardPreview.rows(DayCardPreview.prepLineCases) }
}

#Preview("Prep line, AX3") {
    DayCardPreview.board { DayCardPreview.rows(DayCardPreview.prepLineCases) }
        .dynamicTypeSize(.accessibility3)
}
