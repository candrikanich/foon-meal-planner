import Foundation

/// The age range Apple's Declared Age Range API gives when someone claims a profile (#88). Mirrors the database's
/// `age_band`. Never a birthdate; `redeem_invite` uses it to refuse a minor's account claiming an adult's profile, and an
/// adult's account claiming a kid's, then keeps only kid or adult (Texas §121.055(b)).
enum AgeBand: String, Codable, Sendable, CaseIterable {
    case under13 = "under_13"
    case from13To15 = "13_15"
    case from16To17 = "16_17"
    case adult
    /// They declined to share, the device or region can't answer, or the range Apple gave doesn't fit one band.
    case unknown

    /// The gates Foon asks with, so the answer lands on one of the bands above.
    static let ageGates = (13, 16, 18)

    /// The band for the range Apple shared. A bound is nil where the range is open: under the first gate there's no
    /// lower bound, and over the last there's no upper bound. The system may widen the gates for local rules, so a
    /// range that spans bands takes the youngest band it could be when it's all under 18, and adult only when it's
    /// all 18 or over.
    init(lowerBound: Int?, upperBound: Int?) {
        if let lowerBound, lowerBound >= 18 {
            self = .adult
            return
        }
        guard let upperBound, upperBound < 18 else {
            // Both open, or a range that reaches past 18 from below it: it doesn't say which side they're on.
            self = .unknown
            return
        }
        switch lowerBound ?? 0 {
        case ..<13: self = .under13
        case ..<16: self = .from13To15
        default: self = .from16To17
        }
    }

    var isMinor: Bool {
        switch self {
        case .under13, .from13To15, .from16To17: true
        case .adult, .unknown: false
        }
    }
}
