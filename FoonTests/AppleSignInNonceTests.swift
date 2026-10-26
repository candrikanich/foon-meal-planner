import Testing
@testable import Foon

struct AppleSignInNonceTests {
    @Test func makesNoncesOfTheRequestedLengthFromASafeAlphabet() {
        let nonce = AppleSignInNonce.make(length: 48)
        #expect(nonce.count == 48)
        #expect(nonce.allSatisfy { $0.isLetter || $0.isNumber || "-._".contains($0) })
    }

    @Test func noncesDoNotRepeat() {
        let nonces = Set((0..<50).map { _ in AppleSignInNonce.make() })
        #expect(nonces.count == 50)
    }

    @Test func hashesWithSHA256AsLowercaseHex() {
        #expect(AppleSignInNonce.sha256("abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
