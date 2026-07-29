import XCTest
@testable import LocalAgentApp

final class ISHEnvironmentPolicyTests: XCTestCase {
    func testGuestEnvironmentContainsNoCredentialNames() {
        let forbiddenFragments = [
            "api_key",
            "apikey",
            "authorization",
            "bearer",
            "oauth",
            "token",
        ]

        let serialized = ISHEnvironmentPolicy.guestEnvironment
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
            .lowercased()

        for forbidden in forbiddenFragments {
            XCTAssertFalse(serialized.contains(forbidden), forbidden)
        }
    }
}
