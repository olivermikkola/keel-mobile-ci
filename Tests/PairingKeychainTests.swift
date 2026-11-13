import XCTest
@testable import KeelMobile

final class PairingKeychainTests: XCTestCase {
    func testCredentialRoundTripUpdateAndForget() throws {
        let address = "https://\(UUID().uuidString.lowercased()).example"
        defer { try? PairingKeychain.remove(address: address) }
        XCTAssertEqual(PairingKeychain.load(address: address), "")
        var stage = "initial save"
        do {
            try PairingKeychain.save(token: "first-test-token", address: address)
            XCTAssertEqual(PairingKeychain.load(address: address), "first-test-token")
            stage = "update"
            try PairingKeychain.save(token: "replacement-test-token", address: address)
            XCTAssertEqual(PairingKeychain.load(address: address), "replacement-test-token")
            stage = "forget"
            try PairingKeychain.remove(address: address)
            XCTAssertEqual(PairingKeychain.load(address: address), "")
        } catch {
            let failure = error as NSError
            XCTFail("Real Keychain failed during \(stage): domain=\(failure.domain), OSStatus=\(failure.code). Check the test host's Keychain entitlements.")
        }
    }
}
