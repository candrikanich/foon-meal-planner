import Foundation
import Observation

/// The household's subscription: what the server says, what StoreKit says on this device, and the purchase itself.
/// The server learns of a purchase from Apple's notification, so after a purchase or restore the store asks it again a
/// few times, and meanwhile shows the verified local transaction.
@Observable @MainActor
final class SubscriptionStore {
    private(set) var entitled: Bool?
    private(set) var server: ServerSubscription?
    private(set) var local: SubscriptionPlan?
    private(set) var offers: [StoreOffer] = []
    private(set) var isWorking = false
    private(set) var message: String?

    let householdID: UUID
    private let client: SubscriptionClient
    private let storeKit: StoreKitClient
    private let pause: @Sendable () async -> Void
    private let pollAttempts: Int

    init(householdID: UUID, client: SubscriptionClient, storeKit: StoreKitClient, pollAttempts: Int = 5,
         pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }) {
        self.householdID = householdID
        self.client = client
        self.storeKit = storeKit
        self.pollAttempts = pollAttempts
        self.pause = pause
    }

    var access: SubscriptionAccess {
        SubscriptionAccess.resolve(entitled: entitled, server: server, local: local)
    }

    /// Whether the household founded in the beta; unknown counts as not.
    var isFounding: Bool { server?.founding ?? false }

    /// The one gate. A planner's rights still apply on top; this only adds "and the household is paid up".
    func canEdit(asPlanner isPlanner: Bool) -> Bool {
        isPlanner && access.allowsEditing
    }

    /// On launch, on coming back to the foreground, and when a transaction arrives. Offline keeps what was known.
    func refresh() async {
        await refresh(keeping: nil)
    }

    /// `keeping` is a plan from a transaction just verified, which StoreKit's entitlements may not list yet.
    private func refresh(keeping justBought: SubscriptionPlan?) async {
        async let isEntitled = try? client.entitled(householdID)
        async let subscription = try? client.subscription(householdID)
        async let plan = storeKit.currentPlan(householdID)
        let (newEntitled, newServer, newLocal) = await (isEntitled, subscription, plan)
        entitled = newEntitled ?? entitled
        server = newServer ?? server
        local = newLocal ?? justBought
    }

    func loadOffers() async {
        let ids = FoonProducts.offered(founding: isFounding)
        do {
            offers = try await storeKit.offers(ids)
        } catch {
            offers = []
            message = String(localized: "Couldn't reach the App Store. Check your connection and try again.")
        }
    }

    func purchase(_ productID: String) async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            switch try await storeKit.purchase(productID, householdID) {
            case .purchased(let plan):
                local = plan
                await settle(keeping: plan)
            case .pending:
                message = String(localized: "Waiting for approval. Foon unlocks as soon as the App Store says yes.")
            case .cancelled:
                break
            }
        } catch {
            message = String(localized: "The purchase didn't go through, and you haven't been charged. Try again in a moment.")
        }
    }

    func restore() async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await storeKit.restore()
        } catch {
            message = String(localized: "Couldn't restore purchases. Check your connection and try again.")
            return
        }
        await refresh()
        if local == nil, !access.isSubscribed {
            message = String(localized: "No Foon subscription found on this Apple Account.")
        } else {
            await settle(keeping: nil)
        }
    }

    /// Asks the server a few times whether Apple's notification has landed; if it hasn't, the local transaction stands.
    private func settle(keeping justBought: SubscriptionPlan?) async {
        for _ in 0..<pollAttempts {
            await refresh(keeping: justBought)
            if server?.hasPlan == true, entitled == true { return }
            await pause()
        }
    }
}
