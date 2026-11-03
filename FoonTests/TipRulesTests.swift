import Foundation
import Testing
@testable import Foon

struct TipRulesTests {
    @Test func phonesOfferTheShareTipAndTheStoreTipWhileThereIsSomethingToBuy() {
        #expect(TipRules.eligible(onMac: false, canShop: true) == [.shareToFoon, .storeMode])
    }

    @Test func theStoreTipWaitsUntilShopCanOpen() {
        #expect(TipRules.eligible(onMac: false, canShop: false) == [.shareToFoon])
    }

    @Test func theMacHasNoShareExtensionSoNoShareTip() {
        #expect(TipRules.eligible(onMac: true, canShop: true) == [.storeMode])
        #expect(TipRules.eligible(onMac: true, canShop: false).isEmpty)
    }

    @Test func nothingIsPendingUntilAsked() throws {
        let defaults = try Self.scratchDefaults()
        #expect(!TipReset.isPending(defaults))
        #expect(!TipReset.takePending(defaults))
    }

    @Test func aRequestIsTakenOnceAtTheNextLaunch() throws {
        let defaults = try Self.scratchDefaults()
        TipReset.request(defaults)
        #expect(TipReset.isPending(defaults))
        #expect(TipReset.takePending(defaults))
        #expect(!TipReset.isPending(defaults))
        #expect(!TipReset.takePending(defaults))
    }

    private static func scratchDefaults() throws -> UserDefaults {
        let name = "TipRulesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
