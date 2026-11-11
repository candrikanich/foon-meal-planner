#if canImport(DeclaredAgeRange)
@preconcurrency import DeclaredAgeRange
#endif
import SwiftUI

#if canImport(DeclaredAgeRange)
extension AgeBand {
    /// Asks Apple for the age range of the person signed in to this device: the system shows its own prompt, and
    /// Foon gets back a range, never a birthdate (#88). A decline, or a device or region that can't answer, is
    /// `.unknown`, which the server takes as no claim either way.
    @MainActor
    static func ask(_ requestAgeRange: DeclaredAgeRangeAction) async -> AgeBand {
        guard let response = try? await requestAgeRange(ageGates: ageGates.0, ageGates.1, ageGates.2),
              case .sharing(let range) = response else {
            return .unknown
        }
        return AgeBand(lowerBound: range.lowerBound, upperBound: range.upperBound)
    }
}
#endif
