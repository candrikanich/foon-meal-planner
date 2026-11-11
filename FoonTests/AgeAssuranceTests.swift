import Foundation
import Testing
@testable import Foon

/// Apple's age range becomes one band for `redeem_invite` (#88).
struct AgeBandTests {
    @Test(arguments: [
        // The ranges Foon's gates (13, 16, 18) give.
        (nil, 12, AgeBand.under13), (13, 15, .from13To15), (16, 17, .from16To17), (18, nil, .adult),
        // Gates the system widened for local rules: the youngest band a minor could be, and adult only at 18 or over.
        (13, 17, .from13To15), (nil, 15, .under13), (21, nil, .adult),
        // Nothing says which side of 18 they're on.
        (nil, nil, .unknown), (16, nil, .unknown), (nil, 20, .unknown),
    ] as [(Int?, Int?, AgeBand)])
    func mapsTheRangeToABand(lower: Int?, upper: Int?, expected: AgeBand) {
        #expect(AgeBand(lowerBound: lower, upperBound: upper) == expected)
    }

    @Test func rawValuesMatchTheDatabaseEnum() {
        #expect(AgeBand.allCases.map(\.rawValue) == ["under_13", "13_15", "16_17", "adult", "unknown"])
    }

    @Test func onlyTheThreeYoungBandsAreMinors() {
        #expect(AgeBand.allCases.filter(\.isMinor) == [.under13, .from13To15, .from16To17])
    }

    @MainActor
    @Test func theJoinSendsTheBand() async {
        var client = HouseholdClient.preview(household: nil, members: [])
        client.redeemInvite = { _, ageBand in
            #expect(ageBand == .from13To15)
            return .ageMismatch
        }
        let store = HouseholdStore(userID: UUID(), client: client)
        await store.load()
        await store.redeem("THESM-7KQ4-M9XP", ageBand: .from13To15)
        #expect(store.phase == .needsHousehold)
        #expect(store.errorMessage == RedeemResult.ageMismatch.message)
    }
}

/// Which significant changes still need a parent's OK or an adult's acknowledgment (#88).
struct SignificantChangeTests {
    private let photos = SignificantChange(id: "2027-photos", introducedIn: "40", summary: "Photos.")
    private let rating = SignificantChange(id: "2027-rating", introducedIn: "52", summary: "Age rating.")

    @Test func nothingQualifiesYet() {
        #expect(SignificantChange.all.isEmpty, "adding one starts asking parents: update docs/spec.md with it")
    }

    @Test func aChangeFromBeforeTheInstallIsntShown() {
        let pending = SignificantChange.pending([photos, rating], handled: [], originalAppVersion: "45")
        #expect(pending == [rating])
    }

    @Test func buildNumbersCompareAsNumbers() {
        #expect(SignificantChange.pending([photos], handled: [], originalAppVersion: "9") == [photos])
    }

    @Test func aHandledChangeIsntShownAgain() {
        #expect(SignificantChange.pending([photos, rating], handled: ["2027-photos"], originalAppVersion: nil) == [rating])
    }

    @Test func theInstallingBuildItselfDoesntAsk() {
        #expect(SignificantChange.pending([rating], handled: [], originalAppVersion: "52").isEmpty)
    }

    @Test func theLedgerRemembers() throws {
        let defaults = try #require(UserDefaults(suiteName: "SignificantChangeTests-\(UUID())"))
        let ledger = SignificantChangeLedger(defaults: defaults)
        ledger.markHandled([photos])
        ledger.markHandled([rating])
        #expect(ledger.handled == ["2027-photos", "2027-rating"])
    }

    @Test func theSummaryKeepsTheOrder() {
        #expect(SignificantChange.summary(of: [photos, rating]) == "Photos.\n\nAge rating.")
    }
}
