import Foundation

/// What the app shares with its extensions: the share sheet's inbox, and the answers waiting to be sent, which the
/// after-dinner card writes too.
enum AppGroup {
    /// Foon's group, or Foon QA's in the Staging build (docs/foon-qa.md). The build setting `FOON_APP_GROUP` puts it in
    /// the entitlements and in each target's Info.plist, so the app and its extensions always agree with what's signed.
    static let id = Bundle.main.object(forInfoDictionaryKey: "FoonAppGroup") as? String ?? production

    static let production = "group.com.andrikanich.foon"
}
