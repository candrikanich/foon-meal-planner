import Foundation
import StoreKit

/// A product as the paywall shows it. Prices and trials come from StoreKit, never from our own strings.
struct StoreOffer: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let price: String
    /// "month" or "year", for "$5.99 / month".
    let period: String
    /// "1-month free trial", only when this Apple account still gets the introductory offer.
    let trial: String?
}

enum PurchaseOutcome: Equatable, Sendable {
    case purchased(SubscriptionPlan)
    /// Ask to Buy or a payment that needs approval: it arrives later through `Transaction.updates`.
    case pending
    case cancelled
    /// The transaction is for another household's id: this Apple Account already subscribes elsewhere.
    case otherHousehold
}

enum StorePurchaseError: Error, Equatable {
    case unknownProduct
    case unverified
}

/// StoreKit 2, as closures so tests and previews can swap it out.
struct StoreKitClient: Sendable {
    var offers: @Sendable (_ productIDs: [String]) async throws -> [StoreOffer]
    /// Buys the product with the household's id as `appAccountToken`: the server finds the household by it.
    var purchase: @Sendable (_ productID: String, _ householdID: UUID) async throws -> PurchaseOutcome
    /// Asks the App Store for this Apple account's purchases again (`AppStore.sync()`).
    var restore: @Sendable () async throws -> Void
    /// A verified, unexpired subscription bought for this household, from `Transaction.currentEntitlements`.
    var currentPlan: @Sendable (_ householdID: UUID) async -> SubscriptionPlan?
}

extension Notification.Name {
    /// Posted when a verified Foon transaction arrives outside a purchase (a renewal, Ask to Buy approved, a refund).
    static let foonTransactionUpdated = Notification.Name("foon.transactionUpdated")
}

extension StoreKitClient {
    static let live = StoreKitClient(
        offers: { ids in
            let products = try await Product.products(for: ids)
            var offers: [StoreOffer] = []
            for id in ids {
                guard let product = products.first(where: { $0.id == id }), let subscription = product.subscription else {
                    continue
                }
                let eligible = await subscription.isEligibleForIntroOffer
                let trial = eligible ? subscription.introductoryOffer.flatMap(trialTitle) : nil
                offers.append(StoreOffer(id: id, name: product.displayName, price: product.displayPrice,
                                         period: periodTitle(subscription.subscriptionPeriod), trial: trial))
            }
            return offers
        },
        purchase: { id, householdID in
            guard let product = try await Product.products(for: [id]).first else { throw StorePurchaseError.unknownProduct }
            switch try await product.purchase(options: [.appAccountToken(householdID)]) {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { throw StorePurchaseError.unverified }
                await transaction.finish()
                let plan = SubscriptionPlan(productID: transaction.productID, expiresAt: transaction.expirationDate,
                                            autoRenews: nil)
                return .verified(plan, token: transaction.appAccountToken, household: householdID)
            case .pending: return .pending
            case .userCancelled: return .cancelled
            @unknown default: return .cancelled
            }
        },
        restore: { try await AppStore.sync() },
        currentPlan: { householdID in
            var best: Transaction?
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      FoonProducts.all.contains(transaction.productID),
                      transaction.revocationDate == nil,
                      transaction.appAccountToken == householdID,
                      transaction.expirationDate.map({ $0 > .now }) ?? true
                else { continue }
                if (transaction.expirationDate ?? .distantFuture) > (best?.expirationDate ?? .distantPast) { best = transaction }
            }
            return best.map { SubscriptionPlan(productID: $0.productID, expiresAt: $0.expirationDate, autoRenews: nil) }
        })

    static let preview = StoreKitClient(
        offers: { ids in StoreOffer.samples.filter { ids.contains($0.id) } },
        purchase: { _, _ in .cancelled },
        restore: {},
        currentPlan: { _ in nil })

    private static func periodTitle(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: String(localized: "day", comment: "Paywall: price period, as in $5.99 / month")
        case .week: String(localized: "week", comment: "Paywall: price period, as in $5.99 / month")
        case .month: String(localized: "month", comment: "Paywall: price period, as in $5.99 / month")
        case .year: String(localized: "year", comment: "Paywall: price period, as in $5.99 / month")
        @unknown default: ""
        }
    }

    private static func trialTitle(_ offer: Product.SubscriptionOffer) -> String? {
        guard offer.paymentMode == .freeTrial else { return nil }
        let count = offer.period.value
        switch offer.period.unit {
        case .day: return String(localized: "\(count)-day free trial", comment: "Paywall: the introductory free trial")
        case .week: return String(localized: "\(count)-week free trial", comment: "Paywall: the introductory free trial")
        case .month: return String(localized: "\(count)-month free trial", comment: "Paywall: the introductory free trial")
        case .year: return String(localized: "\(count)-year free trial", comment: "Paywall: the introductory free trial")
        @unknown default: return nil
        }
    }
}

extension StoreOffer {
    /// The trial with what it turns into, so nobody has to guess the price after it ends (App Review 3.1.2, #282).
    var trialThenPrice: String? {
        trial.map {
            String(localized: "\($0), then \(price) a \(period)",
                   comment: "Paywall: the free trial, then the renewal price, as in 1-month free trial, then $5.99 a month")
        }
    }

    static let samples = [
        StoreOffer(id: FoonProducts.monthly, name: "Foon Family Monthly", price: "$5.99", period: "month",
                   trial: "1-month free trial"),
        StoreOffer(id: FoonProducts.annual, name: "Foon Family Annual", price: "$49.99", period: "year",
                   trial: "1-month free trial"),
        StoreOffer(id: FoonProducts.founding, name: "Foon Founding Family", price: "$24.99", period: "year", trial: nil)
    ]
}

/// Finishes the transactions that arrive while the app runs: renewals, approved Ask to Buy, and ones a purchase on
/// another device or a restore brings in. Started at launch, since StoreKit expects something listening all the time.
enum StoreListener {
    static func start() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result, FoonProducts.all.contains(transaction.productID) else { continue }
                await transaction.finish()
                await MainActor.run { NotificationCenter.default.post(name: .foonTransactionUpdated, object: nil) }
            }
        }
    }
}
