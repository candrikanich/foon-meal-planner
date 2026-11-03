import Foundation

/// The one-time tips (docs/spec.md → Tips). Each teaches where something is, so it shows before first use.
/// The AI pick's tip lands with the AI pick itself (car 6), offered only where the on-device model is available.
enum FoonTip: Hashable, CaseIterable {
    case shareToFoon
    case storeMode
}

enum TipRules {
    /// The Mac has no share extension yet, and store mode opens only while there's something to buy or a trip to
    /// finish, so a tip never points at something that isn't there.
    static func eligible(onMac: Bool, canShop: Bool) -> Set<FoonTip> {
        var tips: Set<FoonTip> = []
        if !onMac { tips.insert(.shareToFoon) }
        if canShop { tips.insert(.storeMode) }
        return tips
    }
}

/// "Show tips again": TipKit can only clear its store before it's configured, so the request waits for the next
/// launch.
enum TipReset {
    static let pendingKey = "tips.resetPending"

    static func request(_ defaults: UserDefaults) {
        defaults.set(true, forKey: pendingKey)
    }

    static func isPending(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: pendingKey)
    }

    /// At launch: whether to clear the store first. The request is used up either way.
    static func takePending(_ defaults: UserDefaults) -> Bool {
        let pending = isPending(defaults)
        defaults.removeObject(forKey: pendingKey)
        return pending
    }
}
