import Foundation
import Testing
@testable import Foon

/// The wait while this device tidies a shared recipe (#256): what the card says as time passes, and that it only ever
/// says true things about the food and never how it's done.
struct TidyProgressTests {
    private let limit: Duration = .seconds(30)

    @Test func theMessageMovesOnAsTimePasses() {
        let stages = [0, 4.9, 5, 11.9, 12, 19.9, 20, 29, 60].map {
            TidyProgress.stage(after: .seconds($0), limit: limit)
        }
        #expect(stages == [.reading, .reading, .ingredients, .ingredients, .lotGoingOn, .lotGoingOn, .almostThere,
                           .almostThere, .almostThere])
    }

    @Test func almostThereComesOnlyWhenTheWaitIsNearlyOver() {
        let longer: Duration = .seconds(45)
        #expect(TidyProgress.stage(after: .seconds(34), limit: longer) == .lotGoingOn)
        #expect(TidyProgress.stage(after: .seconds(35), limit: longer) == .almostThere)
    }

    @Test func aShortLimitStillShowsEachMessageInOrder() {
        let short: Duration = .seconds(10)
        #expect(TidyProgress.stage(after: .seconds(12), limit: short) == .lotGoingOn)
        #expect(TidyProgress.stage(after: .seconds(13), limit: short) == .almostThere)
    }

    @Test func theCardWakesOnlyWhenTheMessageChanges() {
        #expect(TidyProgress.nextChange(after: .zero, limit: limit) == .seconds(5))
        #expect(TidyProgress.nextChange(after: .seconds(6), limit: limit) == .seconds(6))
        #expect(TidyProgress.nextChange(after: .seconds(12), limit: limit) == .seconds(8))
        #expect(TidyProgress.nextChange(after: .seconds(20), limit: limit) == nil)
        #expect(TidyProgress.nextChange(after: .seconds(90), limit: limit) == nil)
    }

    @Test func eachStageHasItsOwnMessage() {
        let messages = TidyProgress.Stage.allCases.map(TidyProgress.message)
        #expect(Set(messages).count == TidyProgress.Stage.allCases.count)
        #expect(TidyProgress.message(.reading) == String(localized: "Reading the recipe…"))
        #expect(TidyProgress.allCopy.contains(TidyProgress.skip))
        #expect(TidyProgress.allCopy.contains(TidyProgress.stubborn))
    }

    @Test func theCopyNeverSaysHowItsDoneOrPraisesTheFood() {
        let banned = ["AI", "Apple Intelligence", "model", "machine learning", "artificial", "delicious", "yummy",
                      "tasty"]
        for text in TidyProgress.allCopy {
            for word in banned {
                #expect(text.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) == nil,
                        "\(text) says \(word)")
            }
        }
    }

    @Test func theTimeoutLineSaysWhatShowsAndToCheckIt() {
        #expect(TidyProgress.stubborn.localizedCaseInsensitiveContains("check"))
    }
}
