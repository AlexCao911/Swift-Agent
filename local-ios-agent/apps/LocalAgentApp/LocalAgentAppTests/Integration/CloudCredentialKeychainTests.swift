import Foundation
import LocalAgentLLMCloud
import Security
import Testing

@Suite("Cloud credential Keychain integration")
struct CloudCredentialKeychainTests {
    @Test("generation account is device-only, non-synchronizable, and promotable")
    func generationAccountHasExactSecurityAttributes() async throws {
        let nonce = UUID().uuidString
        let service = "com.alexandercou.local-agent.tests.\(nonce)"
        let credentialRef = "credential-\(nonce)"
        let operationID = "operation-\(nonce)"
        let staged = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: 1,
            operationID: operationID
        )
        let final = CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: 1
        )
        defer {
            SecItemDelete(keychainQuery(service: service, account: staged, synchronizable: false))
            SecItemDelete(keychainQuery(service: service, account: final, synchronizable: false))
        }
        let vault = SecurityCredentialVault(service: service)
        let secret = SecretBytes(utf8: UUID().uuidString)

        try await vault.writeStaged(
            credentialRef: credentialRef,
            generation: 1,
            operationID: operationID,
            secret: secret
        )
        try await vault.promoteStaged(
            credentialRef: credentialRef,
            generation: 1,
            operationID: operationID
        )

        var item: CFTypeRef?
        var query = keychainDictionary(
            service: service,
            account: final,
            synchronizable: false
        )
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        let attributes = try #require(item as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        #expect(SecItemCopyMatching(
            keychainQuery(service: service, account: final, synchronizable: true),
            nil
        ) == errSecItemNotFound)
        #expect(SecItemCopyMatching(
            keychainQuery(service: service, account: staged, synchronizable: false),
            nil
        ) == errSecItemNotFound)
    }
}

private func keychainDictionary(
    service: String,
    account: String,
    synchronizable: Bool
) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
    ]
}

private func keychainQuery(
    service: String,
    account: String,
    synchronizable: Bool
) -> CFDictionary {
    keychainDictionary(
        service: service,
        account: account,
        synchronizable: synchronizable
    ) as CFDictionary
}
