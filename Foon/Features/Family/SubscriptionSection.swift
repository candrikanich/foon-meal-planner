import StoreKit
import SwiftUI

/// What the household's subscription looks like, in the owner's words or everyone else's (docs/spec.md → Payments).
enum SubscriptionCopy {
    static func productName(_ id: String) -> String {
        switch id {
        case FoonProducts.monthly: String(localized: "Foon Family, monthly")
        case FoonProducts.annual: String(localized: "Foon Family, yearly")
        case FoonProducts.founding: String(localized: "Foon Founding Family")
        default: String(localized: "Foon Family")
        }
    }

    /// One line for the Family header, owner only.
    static func status(_ access: SubscriptionAccess) -> String? {
        switch access {
        case .checking: nil
        case .freeBeta: String(localized: "Free during the beta")
        case .lapsed: String(localized: "Needs a subscription")
        case .subscribed(let plan):
            if let end = plan.expiresAt {
                plan.autoRenews == false
                    ? String(localized: "\(productName(plan.productID)) · ends \(end.formatted(date: .abbreviated, time: .omitted))")
                    : String(localized: "\(productName(plan.productID)) · renews \(end.formatted(date: .abbreviated, time: .omitted))")
            } else {
                productName(plan.productID)
            }
        }
    }

    /// Whether Apple keeps charging after the household is deleted: a plan that hasn't been set to end. Foon can't cancel
    /// an App Store subscription for anyone, so the delete screens say so (#283).
    static func billingContinues(_ access: SubscriptionAccess) -> Bool {
        guard case .subscribed(let plan) = access else { return false }
        return plan.autoRenews != false
    }
}

/// On the owner's delete screens: deleting the household doesn't cancel the subscription, which Apple bills (#283).
struct BillingContinuesSection: View {
    @Environment(SubscriptionStore.self) private var subscription: SubscriptionStore?

    var body: some View {
        if let subscription, SubscriptionCopy.billingContinues(subscription.access) {
            Section {
                ManageSubscriptionButton()
            } header: {
                Text("Subscription")
            } footer: {
                Text("Deleting doesn't cancel your subscription. Apple keeps billing it until you cancel it in Manage subscription, or in Settings under your Apple Account, Subscriptions.")
            }
        }
    }
}

/// Opens Apple's subscription management: a sheet on iPhone and iPad, the App Store account page on the Mac.
struct ManageSubscriptionButton: View {
    @State private var managing = false

    var body: some View {
        #if os(iOS)
        Button("Manage subscription", systemImage: "creditcard") { managing = true }
            .manageSubscriptionsSheet(isPresented: $managing)
        #else
        Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
        #endif
    }
}

/// The owner's header line: Founding Family badge and the subscription status.
struct SubscriptionHeaderLine: View {
    @Environment(SubscriptionStore.self) private var subscription

    var body: some View {
        if subscription.isFounding || SubscriptionCopy.status(subscription.access) != nil {
            HStack(spacing: 8) {
                if subscription.isFounding {
                    Chip(text: String(localized: "Founding Family"), systemImage: "star.fill", tint: Palette.paprika)
                }
                if let status = SubscriptionCopy.status(subscription.access) {
                    Text(status).font(.foonCaption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Subscription, in Family. Only the owner buys; everyone else sees who to ask. Restore and Manage are the owner's too.
struct SubscriptionSection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(SubscriptionStore.self) private var subscription

    private var isOwner: Bool { store.household?.owner == store.userID }

    private var ownerName: String {
        store.members.first { $0.userID == store.household?.owner }?.firstName ?? String(localized: "the owner")
    }

    private var mode: PaywallMode {
        .resolve(isOwner: isOwner, founding: subscription.isFounding, access: subscription.access)
    }

    var body: some View {
        Section {
            switch mode {
            case .askOwner: askOwnerRows
            case .manage: manageRows
            case .buy: buyRows
            }
            if let message = subscription.message {
                Text(message).font(.footnote).foregroundStyle(Palette.caution)
            }
        } header: {
            Text("Subscription")
        } footer: {
            footer
        }
        .task(id: subscription.isFounding) {
            if case .buy = mode { await subscription.loadOffers() }
        }
    }

    @ViewBuilder
    private var askOwnerRows: some View {
        switch subscription.access {
        case .lapsed:
            Label("Ask \(ownerName) to unlock Foon", systemImage: "lock")
                .font(.foonHeadline)
        case .subscribed(let plan):
            Label("\(SubscriptionCopy.productName(plan.productID)), from \(ownerName)", systemImage: "checkmark.seal")
        case .freeBeta, .checking:
            Label("Free during the beta", systemImage: "gift")
        }
    }

    @ViewBuilder
    private var manageRows: some View {
        if let status = SubscriptionCopy.status(subscription.access) {
            Label(status, systemImage: "checkmark.seal")
        }
        ManageSubscriptionButton()
        restoreButton
    }

    @ViewBuilder
    private var buyRows: some View {
        switch subscription.access {
        case .freeBeta:
            Label("Free during the beta", systemImage: "gift").font(.foonHeadline)
        case .lapsed:
            Label("Unlock Foon", systemImage: "lock.open").font(.foonHeadline)
        default:
            EmptyView()
        }
        ForEach(subscription.offers) { offer in
            Button {
                Task { await subscription.purchase(offer.id) }
            } label: {
                OfferRow(offer: offer)
            }
            .disabled(subscription.isWorking)
        }
        restoreButton
    }

    private var restoreButton: some View {
        Button("Restore purchases", systemImage: "arrow.clockwise") {
            Task { await subscription.restore() }
        }
        .disabled(subscription.isWorking)
    }

    @ViewBuilder
    private var footer: some View {
        switch mode {
        case .askOwner:
            if subscription.access == .lapsed {
                Text("Until then you can still see everything and export or delete your data.")
            } else {
                Text("One subscription covers the whole family. \(ownerName) looks after it.")
            }
        case .manage:
            Text("One subscription covers the whole family. Apple holds your payment details; Foon never sees them.")
        case .buy:
            switch subscription.access {
            case .freeBeta:
                Text("Foon is free for every family while we test it. If you'd like to subscribe early, you can. Nothing is charged until any trial ends.")
            default:
                Text("One subscription covers the whole family. Until then you can still see everything and export or delete your data. Cancel anytime in Settings.")
            }
        }
    }
}

private struct OfferRow: View {
    let offer: StoreOffer

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.name).font(.foonHeadline)
                if let trial = offer.trial {
                    Text(trial).font(.foonCaption).foregroundStyle(Palette.herb)
                }
            }
            Spacer(minLength: 8)
            Text("\(offer.price) / \(offer.period)").font(.subheadline).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Subscribes your family")
    }

    private var label: String {
        [offer.name, String(localized: "\(offer.price) per \(offer.period)", comment: "VoiceOver: a plan's price, as in $5.99 per month"),
         offer.trial].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Shown at the top of every tab when the household has lapsed: a gentle way to say view-only, and who can fix it.
struct LapsedBanner: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(SubscriptionStore.self) private var subscription
    @Environment(\.showTab) private var showTab

    private var isOwner: Bool { store.household?.owner == store.userID }

    private var ownerName: String {
        store.members.first { $0.userID == store.household?.owner }?.firstName ?? String(localized: "the owner")
    }

    var body: some View {
        if subscription.access == .lapsed {
            HStack(spacing: 12) {
                Image(systemName: "lock").accessibilityHidden(true)
                Text("Foon is view-only for now. Everything is still here.")
                    .font(.foonBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isOwner {
                    Button("Unlock") { showTab(.family) }.buttonStyle(.borderedProminent)
                } else {
                    Text("Ask \(ownerName)").font(.foonCaption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Palette.cardSurface)
            .accessibilityElement(children: .contain)
        }
    }
}

#Preview("Owner, beta") {
    let store = HouseholdStore.preview()
    List { SubscriptionSection() }
        .environment(store)
        .environment(SubscriptionStore(householdID: Household.sample.id, client: .preview(), storeKit: .preview))
        .task { await store.load() }
}

#Preview("Owner, lapsed") {
    let store = HouseholdStore.preview()
    let subscription = SubscriptionStore(
        householdID: Household.sample.id,
        client: .preview(entitled: false, subscription: ServerSubscription(status: "cancelled", founding: false)),
        storeKit: .preview)
    VStack(spacing: 0) {
        LapsedBanner()
        List { SubscriptionSection() }
    }
    .environment(store)
    .environment(subscription)
    .task { await store.load(); await subscription.refresh() }
}

#Preview("Founding household, not the owner") {
    let store = HouseholdStore(userID: UUID(), client: .preview(household: .sample))
    let subscription = SubscriptionStore(
        householdID: Household.sample.id,
        client: .preview(entitled: false, subscription: ServerSubscription(status: "none", founding: true)),
        storeKit: .preview)
    List { SubscriptionSection() }
        .environment(store)
        .environment(subscription)
        .task { await store.load(); await subscription.refresh() }
}
