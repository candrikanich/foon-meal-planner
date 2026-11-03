import AppIntents

/// "What's for dinner?" (#62), from the Tonight widget's snapshot: what this phone last saw, with no network.
struct WhatsForDinnerIntent: AppIntent {
    static let title: LocalizedStringResource = "What's for Dinner"
    static let description = IntentDescription("Tells you tonight's dinner from your family's plan.")
    // A dish is something the family typed: a locked phone never says it (spec, Tonight widget).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard IntentHousehold.signedInClient != nil else { return .result(dialog: "\(IntentHousehold.unavailable)") }
        let answer = TonightAnswer.text(TonightFile.shared?.load(), now: .now)
        return .result(dialog: "\(answer)")
    }
}
