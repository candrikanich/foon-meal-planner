import AppIntents

/// Siri phrases (#62). Apple needs the app's name in each.
struct FoonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatsForDinnerIntent(), phrases: [
            "What's for dinner in \(.applicationName)",
            "Ask \(.applicationName) what's for dinner",
            "What's \(.applicationName) tonight",
        ], shortTitle: "Tonight's Dinner", systemImageName: "fork.knife")
        AppShortcut(intent: AddToListIntent(), phrases: [
            "Add to the \(.applicationName) list",
            "Add something to \(.applicationName)",
        ], shortTitle: "Add to List", systemImageName: "cart.badge.plus")
        AppShortcut(intent: RequestMealIntent(), phrases: [
            "Request a dinner in \(.applicationName)",
            "Ask \(.applicationName) for a dinner",
        ], shortTitle: "Request a Dinner", systemImageName: "lightbulb")
    }
}
