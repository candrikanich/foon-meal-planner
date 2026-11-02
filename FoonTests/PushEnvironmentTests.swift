import Foundation
import Testing
@testable import Foon

struct PushEnvironmentTests {
    private func profile(_ entitlements: String) -> Data {
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Entitlements</key>"
            + "<dict>\(entitlements)</dict></dict></plist>"
        return Data([0x30, 0x82, 0x01]) + Data(plist.utf8) + Data([0x00, 0xff])
    }

    @Test func developmentProfileIsSandbox() {
        let data = profile("<key>aps-environment</key><string>development</string>")
        #expect(PushRegistration.apsEnvironment(fromProfile: data) == "sandbox")
    }

    @Test func macDevelopmentKeyIsSandbox() {
        let data = profile("<key>com.apple.developer.aps-environment</key><string>development</string>")
        #expect(PushRegistration.apsEnvironment(fromProfile: data) == "sandbox")
    }

    @Test func productionProfileIsProduction() {
        let data = profile("<key>aps-environment</key><string>production</string>")
        #expect(PushRegistration.apsEnvironment(fromProfile: data) == "production")
    }

    @Test func noProfileIsProduction() {
        #expect(PushRegistration.apsEnvironment(fromProfile: nil) == "production")
    }

    @Test func garbageIsProduction() {
        #expect(PushRegistration.apsEnvironment(fromProfile: Data([1, 2, 3])) == "production")
        #expect(PushRegistration.apsEnvironment(fromProfile: Data("<?xml nope</plist>".utf8)) == "production")
    }
}
