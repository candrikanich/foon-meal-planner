import Foundation

/// The last "may this household change things" answer, kept in the App Group so Siri's intents (which have no
/// `SubscriptionStore`) can honor the read-only gate. Unknown is allowed, as everywhere else.
enum EditingAllowed {
    private static let key = "foon.editingAllowed"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppGroup.id) }

    static func decide(stored: Bool?) -> Bool { stored ?? true }

    static var current: Bool { decide(stored: defaults?.object(forKey: key) as? Bool) }

    static func save(_ allowed: Bool) { defaults?.set(allowed, forKey: key) }

    /// For sign-out: the next person on this device starts from "unknown".
    static func clear() { defaults?.removeObject(forKey: key) }
}
