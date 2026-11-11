import Foundation

/// A change to Foon that Apple's age-assurance rules call significant (#88): for example an age-rating change, or a
/// significant change to the Terms of Use or Privacy Policy (Texas §121.053). Where the law asks for it, a minor needs
/// a parent's OK again through PermissionKit, and an adult sees Apple's acknowledgment; see `SignificantChangeGate`.
struct SignificantChange: Identifiable, Hashable, Sendable {
    /// Stable for good: it's how the device remembers the change was handled.
    let id: String
    /// The build that brings it (`CFBundleVersion`, which is what `AppTransaction.originalAppVersion` holds on iOS).
    /// Someone who installed this build or a later one never sees it.
    let introducedIn: String
    /// What changed, in a sentence or two a parent reads on their own device. Use `String(localized:)`.
    let summary: String

    /// Every significant change so far. Empty until one qualifies, so nothing is asked; add one here (and say so in
    /// docs/spec.md) only when a change does.
    static let all: [SignificantChange] = []

    /// The changes this person still has to see: not handled on this device, and newer than the build they first
    /// installed. Without an original build (no App Store receipt yet), every unhandled change counts.
    static func pending(_ changes: [SignificantChange], handled: Set<String>,
                        originalAppVersion: String?) -> [SignificantChange] {
        changes.filter { change in
            guard !handled.contains(change.id) else { return false }
            guard let originalAppVersion else { return true }
            return change.introducedIn.compare(originalAppVersion, options: .numeric) == .orderedDescending
        }
    }

    /// One text for Apple's sheet and the parent's question, oldest change first.
    static func summary(of changes: [SignificantChange]) -> String {
        changes.map(\.summary).joined(separator: "\n\n")
    }
}

/// Which significant changes this device has handled: a parent approved, or the adult acknowledged, or none of the
/// rules applied where they are.
struct SignificantChangeLedger {
    static let key = "significantChanges.handled"
    var defaults: UserDefaults = .standard

    var handled: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func markHandled(_ changes: [SignificantChange]) {
        defaults.set(Array(handled.union(changes.map(\.id))).sorted(), forKey: Self.key)
    }
}
