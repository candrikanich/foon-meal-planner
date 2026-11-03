import AppIntents

/// "Request a dinner" (#62): a named idea from you, as on the Ideas tab. Anyone in the family may, kids too. Needs a
/// connection, as Ideas does.
struct RequestMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Request a Dinner"
    static let description = IntentDescription("Asks your family's planner for a dinner.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Dinner", requestValueDialog: "What would you like for dinner?")
    var dinner: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Online anyway, so the household comes from the server rather than this phone's cache.
        guard let client = IntentHousehold.signedInClient, let userID = client.auth.currentUser?.id else {
            return .result(dialog: "\(IntentHousehold.unavailable)")
        }
        do {
            let households = HouseholdClient.live(client)
            guard let household = try await households.myHousehold(),
                  let me = try await households.members(household.id).first(where: { $0.userID == userID })
            else {
                return .result(dialog: IntentDialog(LocalizedStringResource("Open Foon first to join your family.",
                                                                            comment: "Siri: no household for this account")))
            }
            guard let request = NewRequest.build(kind: .name, from: me.id, mealID: nil, title: dinner, link: "",
                                                 note: "", date: nil) else {
                return .result(dialog: "That's a long name. Try a shorter one.")
            }
            _ = try await IdeasClient.live(client).make(household.id, request)
            return .result(dialog: "Asked for \(request.title ?? dinner). It's on the Ideas tab.")
        } catch {
            return .result(dialog: "Couldn't reach Foon. Try again.")
        }
    }
}
