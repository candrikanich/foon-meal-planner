import AppIntents
import SwiftData

/// "Add milk to the list" (#62): on the quick list as whenever, so nobody gets a push. Known items go on offline too.
struct AddToListIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to the List"
    static let description = IntentDescription("Puts things on your family's quick list.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Items", requestValueDialog: "What should go on the list?")
    var items: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let household = IntentHousehold.current() else { return .result(dialog: "\(IntentHousehold.signedOut)") }
        let names = IngredientParser.parse(items).map(\.name)
        guard !names.isEmpty else { return .result(dialog: "Nothing to add.") }
        let sync = household.sync
        let known = (try? household.context.fetch(FetchDescriptor<CachedItem>())) ?? []
        let result = await QuickListAdder.add(names, items: known, householdID: household.id,
                                              itemClient: .live(household.client), sync: sync)
        return .result(dialog: "\(result.spoken(waitingForSignal: sync.isOffline))")
    }
}
