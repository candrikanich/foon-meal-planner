import Foundation
import FoundationModels
import Testing
@testable import Foon

/// AI wording for the Tonight rescue (#60): the model rephrases the code why-lines, and only that. The model is
/// stubbed: CI and the simulator usually lack Apple Intelligence.
@MainActor
struct RescueWordingTests {
    private static let nora = Member.sampleFamily[3]

    private static func idea(_ title: String, why: String, kind: TonightRescue.Idea.Kind? = nil,
                             flaggedFor member: Member? = nil, note: String? = nil) -> TonightRescue.Idea {
        let mealID = UUID()
        let flags = member.map { member in
            [AllergyFlag(trigger: .allergen(.peanuts), members: [.init(id: member.id, firstName: member.firstName)],
                         ingredients: ["peanut butter"])]
        } ?? []
        return TonightRescue.Idea(kind: kind ?? .quickDish(mealID: mealID), title: title, why: why, minutes: 20,
                                  isEstimate: false, allergies: AllergyCheck(flags: flags, note: note),
                                  swapChoice: .meal(id: mealID, name: title))
    }

    private static let draw = [
        idea("Chili", why: "Leftover Chili from Sunday · 2 days old"),
        idea("Pad thai", why: "Backup dinner · 15 min", kind: .backup(mealID: UUID()), flaggedFor: nora,
             note: AllergyMatcher.outOfDateNote),
        idea("Takeout", why: "Nothing to cook", kind: .quickPick(.takeout))
    ]

    nonisolated private static let answer = GeneratedRescueWording(lines: [
        "Sunday's chili, ready to warm up", "A cozy noodle night", "Let someone else do the cooking"
    ])

    private func ai(timeout: Duration = .seconds(5),
                    respond: @escaping @Sendable (String, String, GenerationSchema) async throws -> GeneratedContent)
        -> AIService {
        AIService(availability: { .available }, respond: respond, timeout: timeout)
    }

    // MARK: What the model sees

    @Test func thePromptHasEachIdeasTitleKindAndLineAndTheTime() {
        let prompt = RescueWording.prompt(Self.draw, minutes: 30)

        #expect(prompt.contains("30 minutes"))
        #expect(prompt.contains("1. Chili (quick dish): Leftover Chili from Sunday · 2 days old"))
        #expect(prompt.contains("2. Pad thai (backup dinner): Backup dinner · 15 min"))
        #expect(prompt.contains("3. Takeout (quick pick): Nothing to cook"))
    }

    @Test func thePromptHasNoAllergiesOrMembersEvenWhenAnIdeaIsFlagged() {
        let prompt = RescueWording.prompt(Self.draw, minutes: 20)
        let instructions = RescueWording.instructions(language: Locale.Language(identifier: "en"))

        for text in [prompt, instructions] {
            #expect(!text.contains(Self.nora.firstName))
            #expect(!text.localizedCaseInsensitiveContains("peanut"))
            #expect(!text.contains(AllergyMatcher.outOfDateNote))
            for allergyText in Self.draw[1].allergies.texts { #expect(!text.contains(allergyText)) }
        }
    }

    @Test func theInstructionsAskForTheDevicesLanguageAndKeepToTheFood() {
        let spanish = RescueWording.instructions(language: Locale.Language(identifier: "es"))

        #expect(spanish.contains("Spanish"))
        #expect(spanish.contains("never about whoever cooks"))
        #expect(spanish.localizedCaseInsensitiveContains("calories"))
    }

    // MARK: Validation

    @Test func goodLinesAreTrimmedAndKept() {
        #expect(RescueWording.validated(["  Sunday's chili  ", "Cozy noodles", "No cooking"], count: 3)
            == ["Sunday's chili", "Cozy noodles", "No cooking"])
    }

    @Test func aDigitALongLineOrAnEmptyLineKeepsThatIdeasCodeLine() {
        let long = String(repeating: "a", count: RescueWording.maxLength + 1)
        let exact = String(repeating: "a", count: RescueWording.maxLength)

        #expect(RescueWording.validated(["Ready in 10 minutes", "Cozy noodles", exact], count: 3)
            == [nil, "Cozy noodles", exact])
        #expect(RescueWording.validated([long, " ", "Two\nlines"], count: 3) == [nil, nil, nil])
        #expect(RescueWording.validated(["Ready in ५ minutes"], count: 1) == [nil])
    }

    @Test func theWrongNumberOfLinesKeepsEveryCodeLine() {
        #expect(RescueWording.validated(["One", "Two"], count: 3) == [nil, nil, nil])
        #expect(RescueWording.validated(["One", "Two", "Three", "Four"], count: 3) == [nil, nil, nil])
    }

    @Test func linesAreMatchedToIdeasByPosition() {
        let wording = RescueWording.wording(["Warm it up", "Ready in 5", "No cooking"], for: Self.draw)

        #expect(wording == [Self.draw[0].id: "Warm it up", Self.draw[2].id: "No cooking"])
    }

    // MARK: The store

    @Test func anAnswerIsShownOnlyForTheDrawItWasFor() async {
        let store = RescueWordingStore(ai: ai { _, _, _ in Self.answer.generatedContent })

        await store.word(Self.draw, minutes: 20)

        #expect(store.lines(for: Self.draw) == [
            Self.draw[0].id: "Sunday's chili, ready to warm up",
            Self.draw[1].id: "A cozy noodle night",
            Self.draw[2].id: "Let someone else do the cooking"
        ])
        let redrawn = [Self.idea("Tacos", why: "Due for a turn · 25 min")] + Self.draw.prefix(2)
        #expect(store.lines(for: redrawn).isEmpty)
        #expect(store.lines(for: Array(Self.draw.reversed())).isEmpty)
    }

    @Test func anIdeaWhoseCodeLineChangedIsADifferentDraw() async {
        let store = RescueWordingStore(ai: ai { _, _, _ in Self.answer.generatedContent })
        await store.word(Self.draw, minutes: 20)

        let old = Self.draw[1]
        let changed = TonightRescue.Idea(kind: old.kind, title: old.title,
                                         why: "Backup dinner, everything's in · 15 min", minutes: old.minutes,
                                         isEstimate: old.isEstimate, allergies: old.allergies,
                                         swapChoice: old.swapChoice)

        #expect(store.lines(for: [Self.draw[0], changed, Self.draw[2]]).isEmpty)
    }

    @Test func aDrawAlreadyAnsweredIsNotAskedAgain() async {
        let calls = Calls()
        let store = RescueWordingStore(ai: ai { _, _, _ in
            await calls.add()
            return Self.answer.generatedContent
        })

        await store.word(Self.draw, minutes: 20)
        await store.word(Self.draw, minutes: 30)

        #expect(await calls.count == 1)
    }

    @Test func unavailableTimedOutOrFailedLeavesTheCodeLines() async {
        let unavailable = RescueWordingStore(ai: .none)
        let slow = RescueWordingStore(ai: ai(timeout: .milliseconds(50)) { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return Self.answer.generatedContent
        })
        let failing = RescueWordingStore(ai: ai { _, _, _ in throw CancellationError() })
        let misshapen = RescueWordingStore(ai: ai { _, _, _ in
            GeneratedRecipe(name: "x", servings: 1, ingredients: [], steps: [], prepSteps: []).generatedContent
        })

        for store in [unavailable, slow, failing, misshapen] {
            await store.word(Self.draw, minutes: 20)
            #expect(store.lines(for: Self.draw).isEmpty)
        }
    }

    @Test func nothingToWordMeansNoCall() async {
        let calls = Calls()
        let store = RescueWordingStore(ai: ai { _, _, _ in
            await calls.add()
            return Self.answer.generatedContent
        })

        await store.word([], minutes: 20)

        #expect(await calls.count == 0)
    }
}

private actor Calls {
    private(set) var count = 0
    func add() { count += 1 }
}
