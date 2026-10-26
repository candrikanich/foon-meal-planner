import Testing
@testable import Foon

struct AppTabTests {
    @Test func tabsAppearInSpecOrder() {
        #expect(AppTab.allCases.map(\.title) == ["This Week", "Library", "Lists", "Ideas", "Family"])
    }

    @Test func everyTabHasAnIcon() {
        #expect(AppTab.allCases.allSatisfy { !$0.systemImage.isEmpty })
    }
}
