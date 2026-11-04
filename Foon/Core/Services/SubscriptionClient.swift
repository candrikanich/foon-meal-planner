import Foundation
import Supabase

/// The household's subscription as the server knows it. The server learns from Apple's notifications, never from the app.
struct SubscriptionClient: Sendable {
    /// `household_entitled`: billing isn't enforced yet, or a subscription grants access.
    var entitled: @Sendable (_ householdID: UUID) async throws -> Bool
    var subscription: @Sendable (_ householdID: UUID) async throws -> ServerSubscription
}

extension SubscriptionClient {
    private struct EntitledParams: Encodable {
        let targetHousehold: UUID

        enum CodingKeys: String, CodingKey { case targetHousehold = "target_household" }
    }

    private struct Row: Decodable {
        let founding: Bool
        let subscriptionStatus: String
        let subscriptionProductId: String?
        let subscriptionExpiresAt: Date?
        let subscriptionAutoRenew: Bool?

        enum CodingKeys: String, CodingKey {
            case founding
            case subscriptionStatus = "subscription_status"
            case subscriptionProductId = "subscription_product_id"
            case subscriptionExpiresAt = "subscription_expires_at"
            case subscriptionAutoRenew = "subscription_auto_renew"
        }

        var value: ServerSubscription {
            ServerSubscription(
                status: subscriptionStatus, founding: founding,
                plan: subscriptionProductId.map {
                    SubscriptionPlan(productID: $0, expiresAt: subscriptionExpiresAt, autoRenews: subscriptionAutoRenew)
                })
        }
    }

    static func live(_ client: SupabaseClient) -> SubscriptionClient {
        SubscriptionClient(
            entitled: { householdID in
                try await client.rpc("household_entitled", params: EntitledParams(targetHousehold: householdID))
                    .execute().value
            },
            subscription: { householdID in
                let row: Row = try await client.from("households")
                    .select("founding, subscription_status, subscription_product_id, subscription_expires_at, subscription_auto_renew")
                    .eq("id", value: householdID)
                    .single()
                    .execute()
                    .value
                return row.value
            })
    }

    static func preview(entitled: Bool = true,
                        subscription: ServerSubscription = ServerSubscription(status: "none", founding: false)) -> SubscriptionClient {
        SubscriptionClient(entitled: { _ in entitled }, subscription: { _ in subscription })
    }
}
