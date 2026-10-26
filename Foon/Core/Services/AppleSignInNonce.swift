import CryptoKit
import Foundation

/// Replay protection for Sign in with Apple: Apple gets the hash in the request, Supabase gets the
/// raw value with the identity token and checks they match.
enum AppleSignInNonce {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

    static func make(length: Int = 32) -> String {
        // SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
