import Foundation

/// Foon's subscription products (#66). The ids and groups match `Foon/Foon.storekit` and
/// `supabase/functions/app-store-notifications/products.ts`; App Store Connect has the final say.
enum FoonProducts {
    static let monthly = "foon.family.monthly"
    static let annual = "foon.family.annual"
    static let founding = "foon.family.founding"

    /// The Foon Family group, then the Foon Founding Family group.
    static let all = [monthly, annual, founding]

    /// What a household is offered. A founding household sees only its own price, instead of the standard ones: the
    /// founding group is separate so a standard subscriber can't switch to it from Settings, and offering both would
    /// only tempt founders into the dearer plans.
    static func offered(founding isFounding: Bool) -> [String] {
        isFounding ? [founding] : [monthly, annual]
    }
}

/// A subscription that is doing the household good, from the server's row or from a verified StoreKit transaction.
struct SubscriptionPlan: Equatable, Sendable {
    var productID: String
    var expiresAt: Date?
    var autoRenews: Bool?
}

/// What the server says about the household's subscription (`households` columns the client may read).
struct ServerSubscription: Equatable, Sendable {
    /// `none`, `trial`, `active`, `lapsed` or `cancelled`.
    var status: String
    var founding: Bool
    var plan: SubscriptionPlan?

    init(status: String, founding: Bool, plan: SubscriptionPlan? = nil) {
        self.status = status
        self.founding = founding
        self.plan = plan
    }

    /// A trial, an active subscription, or one in billing retry: the cases where the server still counts the plan.
    var hasPlan: Bool { ["trial", "active", "lapsed"].contains(status) && plan != nil }
}

/// Where the household stands, for the Family screen and for the read-only gate.
enum SubscriptionAccess: Equatable, Sendable {
    /// Nothing heard yet (offline, or still loading). Never blocks anything.
    case checking
    /// Entitled with no subscription: billing isn't enforced yet.
    case freeBeta
    case subscribed(SubscriptionPlan)
    /// Billing is on and nothing grants access: the household is read-only.
    case lapsed

    /// `entitled` is `household_entitled`; `local` is a verified StoreKit transaction for this household, trusted until
    /// the server catches up with Apple's notification (and ignored once the server has a plan of its own).
    static func resolve(entitled: Bool?, server: ServerSubscription?, local: SubscriptionPlan?) -> SubscriptionAccess {
        if let server, server.hasPlan, let plan = server.plan, entitled == true { return .subscribed(plan) }
        if let local { return .subscribed(local) }
        switch entitled {
        case true: return .freeBeta
        case false: return .lapsed
        case nil: return .checking
        }
    }

    /// The one gate for everything a lapsed household can't change. Unknown is allowed: offline never locks a family out.
    var allowsEditing: Bool { self != .lapsed }

    var isSubscribed: Bool {
        if case .subscribed = self { true } else { false }
    }
}

extension PurchaseOutcome {
    /// A verified transaction counts for this household only if it carries this household's id. Another token means
    /// this Apple Account already subscribes for a different household, whose notifications go there, not here.
    static func verified(_ plan: SubscriptionPlan, token: UUID?, household: UUID) -> PurchaseOutcome {
        token == household ? .purchased(plan) : .otherHousehold
    }
}

/// What the subscription section offers, from who is looking.
enum PaywallMode: Equatable, Sendable {
    /// The owner can buy these, in this order.
    case buy(productIDs: [String])
    /// The owner already subscribes: Manage subscription and Restore.
    case manage
    /// Anyone else: no buy buttons, just who to ask.
    case askOwner

    static func resolve(isOwner: Bool, founding: Bool, access: SubscriptionAccess) -> PaywallMode {
        guard isOwner else { return .askOwner }
        return access.isSubscribed ? .manage : .buy(productIDs: FoonProducts.offered(founding: founding))
    }
}
