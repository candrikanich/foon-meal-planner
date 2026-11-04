import Foundation
import Synchronization
import Testing
@testable import Foon

/// A mutable value the `@Sendable` fakes can share with the test.
private final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: @Sendable (inout sending Value) -> sending R) -> R { mutex.withLock(body) }
}

struct SubscriptionAccessTests {
    private let plan = SubscriptionPlan(productID: FoonProducts.annual, expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                                        autoRenews: true)

    @Test func foundingHouseholdsAreOfferedOnlyTheFoundingPrice() {
        #expect(FoonProducts.offered(founding: true) == [FoonProducts.founding])
    }

    @Test func otherHouseholdsAreOfferedMonthlyAndAnnualNeverFounding() {
        let offered = FoonProducts.offered(founding: false)
        #expect(offered == [FoonProducts.monthly, FoonProducts.annual])
        #expect(!offered.contains(FoonProducts.founding))
    }

    @Test func theIdsMatchTheServersAndTheLocalStoreConfig() throws {
        let config = try String(contentsOfFile: Self.path("Foon/Foon.storekit"), encoding: .utf8)
        for id in FoonProducts.all { #expect(config.contains("\"\(id)\""), "\(id) is in Foon.storekit") }
        let server = try String(contentsOfFile: Self.path("supabase/functions/app-store-notifications/products.ts"), encoding: .utf8)
        for id in FoonProducts.all { #expect(server.contains("\"\(id)\""), "\(id) is in products.ts") }
    }

    @Test func notEnforcedWithNoSubscriptionIsTheFreeBeta() {
        let server = ServerSubscription(status: "none", founding: true)
        #expect(SubscriptionAccess.resolve(entitled: true, server: server, local: nil) == .freeBeta)
    }

    @Test func aSubscriptionTheServerKnowsIsShown() {
        let server = ServerSubscription(status: "active", founding: false, plan: plan)
        #expect(SubscriptionAccess.resolve(entitled: true, server: server, local: nil) == .subscribed(plan))
    }

    @Test func notEntitledWithNothingLocalIsLapsed() {
        let server = ServerSubscription(status: "cancelled", founding: false, plan: plan)
        #expect(SubscriptionAccess.resolve(entitled: false, server: server, local: nil) == .lapsed)
    }

    @Test func aVerifiedLocalTransactionCoversTheGapUntilTheServerCatchesUp() {
        let server = ServerSubscription(status: "none", founding: false)
        #expect(SubscriptionAccess.resolve(entitled: false, server: server, local: plan) == .subscribed(plan))
    }

    @Test func nothingKnownYetIsCheckingAndNeverBlocks() {
        let access = SubscriptionAccess.resolve(entitled: nil, server: nil, local: nil)
        #expect(access == .checking)
        #expect(access.allowsEditing)
    }

    @Test func onlyLapsedBlocksEditing() {
        #expect(!SubscriptionAccess.lapsed.allowsEditing)
        #expect(SubscriptionAccess.freeBeta.allowsEditing)
        #expect(SubscriptionAccess.subscribed(plan).allowsEditing)
    }

    @Test func aCancelledRowDoesNotCountAsAPlan() {
        #expect(!ServerSubscription(status: "cancelled", founding: false, plan: plan).hasPlan)
        #expect(ServerSubscription(status: "lapsed", founding: false, plan: plan).hasPlan, "billing retry keeps access")
    }

    @Test func onlyTheOwnerGetsBuyButtons() {
        #expect(PaywallMode.resolve(isOwner: false, founding: false, access: .lapsed) == .askOwner)
        #expect(PaywallMode.resolve(isOwner: false, founding: true, access: .freeBeta) == .askOwner)
        #expect(PaywallMode.resolve(isOwner: true, founding: false, access: .lapsed)
                == .buy(productIDs: [FoonProducts.monthly, FoonProducts.annual]))
        #expect(PaywallMode.resolve(isOwner: true, founding: true, access: .lapsed) == .buy(productIDs: [FoonProducts.founding]))
    }

    @Test func anOwnerWhoSubscribesManagesInstead() {
        #expect(PaywallMode.resolve(isOwner: true, founding: false, access: .subscribed(plan)) == .manage)
    }

    private static func path(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: relative).path
    }
}

@MainActor
struct SubscriptionStoreTests {
    private let household = UUID()
    private let plan = SubscriptionPlan(productID: FoonProducts.monthly, expiresAt: Date(timeIntervalSinceNow: 86_400),
                                        autoRenews: nil)

    private func storeKit(purchase: PurchaseOutcome = .cancelled, current: SubscriptionPlan? = nil,
                          asked: Locked<[UUID]> = Locked([])) -> StoreKitClient {
        StoreKitClient(offers: { _ in [] },
                       purchase: { _, householdID in
                           asked.withLock { $0.append(householdID) }
                           return purchase
                       },
                       restore: {},
                       currentPlan: { _ in current })
    }

    @Test func aPurchaseNamesTheHouseholdAndShowsTheLocalTransactionWhileTheServerLags() async {
        let asked = Locked<[UUID]>([])
        let store = SubscriptionStore(
            householdID: household,
            client: .preview(entitled: false, subscription: ServerSubscription(status: "none", founding: false)),
            storeKit: storeKit(purchase: .purchased(plan), asked: asked), pollAttempts: 3, pause: {})
        await store.purchase(FoonProducts.monthly)
        #expect(asked.withLock { $0 } == [household], "the server matches the notification on this token")
        #expect(store.access == .subscribed(plan))
        #expect(store.access.allowsEditing)
    }

    @Test func thePollStopsOnceTheServerHasThePlan() async {
        let calls = Locked(0)
        let known = ServerSubscription(status: "trial", founding: false, plan: plan)
        let client = SubscriptionClient(
            entitled: { _ in true },
            subscription: { _ in
                calls.withLock { $0 += 1 }
                return calls.withLock { $0 } >= 2 ? known : ServerSubscription(status: "none", founding: false)
            })
        let store = SubscriptionStore(householdID: household, client: client,
                                      storeKit: storeKit(purchase: .purchased(plan)), pollAttempts: 5, pause: {})
        await store.purchase(FoonProducts.monthly)
        #expect(calls.withLock { $0 } == 2)
        #expect(store.server == known)
    }

    @Test func aCancelledPurchaseChangesNothingAndSaysNothing() async {
        let store = SubscriptionStore(householdID: household, client: .preview(), storeKit: storeKit(purchase: .cancelled),
                                      pollAttempts: 1, pause: {})
        await store.purchase(FoonProducts.monthly)
        #expect(store.message == nil)
        #expect(store.local == nil)
    }

    @Test func aPurchaseWaitingForApprovalSaysSo() async {
        let store = SubscriptionStore(householdID: household, client: .preview(), storeKit: storeKit(purchase: .pending),
                                      pollAttempts: 1, pause: {})
        await store.purchase(FoonProducts.monthly)
        #expect(store.message != nil)
    }

    @Test func offlineKeepsWhatWasKnown() async {
        let online = Locked(true)
        let client = SubscriptionClient(
            entitled: { _ in
                if online.withLock({ $0 }) { return false }
                throw URLError(.notConnectedToInternet)
            },
            subscription: { _ in ServerSubscription(status: "none", founding: false) })
        let store = SubscriptionStore(householdID: household, client: client, storeKit: storeKit(), pollAttempts: 1, pause: {})
        await store.refresh()
        #expect(store.access == .lapsed)
        online.withLock { $0 = false }
        await store.refresh()
        #expect(store.access == .lapsed, "a failed read doesn't unlock or forget")
    }

    @Test func aLapsedHouseholdCannotEditEvenAsAPlanner() async {
        let store = SubscriptionStore(householdID: household, client: .preview(entitled: false), storeKit: storeKit(),
                                      pollAttempts: 1, pause: {})
        await store.refresh()
        #expect(!store.canEdit(asPlanner: true))
        #expect(!store.canEdit(asPlanner: false))
    }

    @Test func anEntitledHouseholdStillNeedsPlannerRights() async {
        let store = SubscriptionStore(householdID: household, client: .preview(entitled: true), storeKit: storeKit(),
                                      pollAttempts: 1, pause: {})
        await store.refresh()
        #expect(store.canEdit(asPlanner: true))
        #expect(!store.canEdit(asPlanner: false))
    }
}
