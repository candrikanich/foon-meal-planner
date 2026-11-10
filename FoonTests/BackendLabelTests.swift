import Foundation
import Testing
@testable import Foon

struct BackendLabelTests {
    @Test func productionSaysNothing() {
        #expect(BackendLabel.label(for: URL(string: "https://itnhdikhdsujklaimqqd.supabase.co")!) == nil)
        #expect(BackendLabel.label(for: URL(string: "https://ITNHDIKHDSUJKLAIMQQD.supabase.co/")!) == nil)
    }

    @Test func testBuildsSayWhichServer() {
        #expect(BackendLabel.label(for: URL(string: "https://cbftcssbnfdjjxoeflvj.supabase.co")!) == "Staging")
        #expect(BackendLabel.label(for: URL(string: "http://127.0.0.1:54321")!) == "Local")
        #expect(BackendLabel.label(for: URL(string: "http://localhost:54321")!) == "Local")
        #expect(BackendLabel.label(for: URL(string: "https://example.supabase.co")!) == "Test server")
    }
}
