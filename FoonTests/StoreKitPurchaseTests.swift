import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Foon

/// The live StoreKit client against Foon.storekit in a test session: no Apple servers, no sandbox account.
///
/// Off by default: scripts/test.sh builds unsigned for macOS (CODE_SIGNING_ALLOWED=NO), and there StoreKit's test session
/// loads no products at all (`Product.products(for:)` comes back empty), so these can't pass. Run them from Xcode on a
/// signed destination with FOON_STOREKIT_TESTS=1 in the scheme's test environment.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FOON_STOREKIT_TESTS"] != nil))
struct StoreKitPurchaseTests {
    private let household = UUID()

    private func session() throws -> SKTestSession {
        let config = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Foon/Foon.storekit")
        let session = try SKTestSession(contentsOf: config)
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    @Test func theProductsLoadWithTheirTrial() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let offers = try await StoreKitClient.live.offers(FoonProducts.all)
        #expect(Set(offers.map(\.id)) == Set(FoonProducts.all))
        #expect(offers.first { $0.id == FoonProducts.monthly }?.trial != nil)
        #expect(offers.first { $0.id == FoonProducts.founding }?.trial == nil)
    }

    @Test func aPurchaseForAHouseholdIsFoundByItsToken() async throws {
        let session = try session()
        let outcome = try await StoreKitClient.live.purchase(FoonProducts.annual, household)
        guard case .purchased(let plan) = outcome else {
            Issue.record("expected a purchase, got \(outcome)")
            return
        }
        #expect(plan.productID == FoonProducts.annual)
        #expect(await StoreKitClient.live.currentPlan(household)?.productID == FoonProducts.annual)
        #expect(await StoreKitClient.live.currentPlan(UUID()) == nil, "another household's token doesn't unlock this one")
        session.clearTransactions()
    }

    @Test func anExpiredSubscriptionStopsCounting() async throws {
        let session = try session()
        _ = try await StoreKitClient.live.purchase(FoonProducts.monthly, household)
        try session.expireSubscription(productIdentifier: FoonProducts.monthly)
        #expect(await StoreKitClient.live.currentPlan(household) == nil)
        session.clearTransactions()
    }

    @Test func aRefundStopsCounting() async throws {
        let session = try session()
        _ = try await StoreKitClient.live.purchase(FoonProducts.monthly, household)
        let transaction = try #require(session.allTransactions().first { $0.productIdentifier == FoonProducts.monthly })
        try session.refundTransaction(identifier: UInt(transaction.identifier))
        #expect(await StoreKitClient.live.currentPlan(household) == nil)
        session.clearTransactions()
    }

    @Test func aRenewalKeepsTheHouseholdEntitled() async throws {
        let session = try session()
        _ = try await StoreKitClient.live.purchase(FoonProducts.monthly, household)
        try session.forceRenewalOfSubscription(productIdentifier: FoonProducts.monthly)
        #expect(await StoreKitClient.live.currentPlan(household)?.productID == FoonProducts.monthly)
        session.clearTransactions()
    }
}
