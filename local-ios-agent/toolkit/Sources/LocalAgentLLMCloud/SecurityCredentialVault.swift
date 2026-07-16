import Foundation
import Security

public struct CredentialFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Mutable, non-Codable credential bytes. The backing buffer is copied on input,
/// accessed only through scoped copies, and zeroed before release. Synchronization
/// is intentionally narrow: callers may share the object, but never its storage.
public final class SecretBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8]

    public convenience init(utf8: String) {
        self.init(bytes: Data(utf8.utf8))
    }

    package init(bytes: Data) {
        storage = Array(bytes)
    }

    package func dataCopyForVault() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return Data(storage)
    }

    package func erase() {
        lock.lock()
        _ = storage.withUnsafeMutableBytes { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
        }
        storage.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    deinit {
        erase()
    }
}

public enum CredentialVaultAccount {
    public static func staged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) -> String {
        "credential/\(credentialRef)/generation/\(generation)/staged/\(operationID)"
    }

    public static func final(credentialRef: String, generation: UInt64) -> String {
        "credential/\(credentialRef)/generation/\(generation)"
    }
}

package protocol CredentialVault: Sendable {
    func writeStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String,
        secret: SecretBytes
    ) async throws

    func promoteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws

    func finalExists(credentialRef: String, generation: UInt64) async throws -> Bool

    func loadFinal(credentialRef: String, generation: UInt64) async throws -> SecretBytes

    func deleteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws

    func deleteFinal(credentialRef: String, generation: UInt64) async throws
}

public actor SecurityCredentialVault: CredentialVault {
    public let service: String

    public init(service: String = "com.alexandercou.local-agent.llm-provider-credentials") {
        self.service = service
    }

    public func writeStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String,
        secret: SecretBytes
    ) async throws {
        let account = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        var value = secret.dataCopyForVault()
        defer { eraseData(&value) }
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: value,
        ] as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard var existing = try copyData(account: account) else {
                throw credentialFailure(
                    "credential.operation_conflict",
                    "staged Keychain item could not be re-read"
                )
            }
            defer { eraseData(&existing) }
            guard constantTimeEqual(existing, value) else {
                throw credentialFailure(
                    "credential.operation_conflict",
                    "staged Keychain item already exists with different bytes"
                )
            }
            return
        }
        guard status == errSecSuccess else {
            throw keychainFailure("credential.keychain_write_failed", status)
        }
    }

    public func promoteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws {
        let staged = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        let final = CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )
        let stagedExists = try contains(account: staged)
        let finalExists = try contains(account: final)
        if finalExists, !stagedExists { return }
        guard stagedExists, !finalExists else {
            throw credentialFailure(
                "credential.operation_conflict",
                "Keychain promotion identities are ambiguous"
            )
        }
        let status = SecItemUpdate(
            baseQuery(account: staged) as CFDictionary,
            [kSecAttrAccount as String: final] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw keychainFailure("credential.keychain_promote_failed", status)
        }
    }

    public func loadFinal(
        credentialRef: String,
        generation: UInt64
    ) async throws -> SecretBytes {
        let account = CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )
        guard var value = try copyData(account: account) else {
            throw credentialFailure("credential.missing", "generation-pinned Keychain item is missing")
        }
        defer { eraseData(&value) }
        return SecretBytes(bytes: value)
    }

    public func finalExists(credentialRef: String, generation: UInt64) async throws -> Bool {
        try contains(account: CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        ))
    }

    public func deleteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws {
        try delete(account: CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        ))
    }

    public func deleteFinal(credentialRef: String, generation: UInt64) async throws {
        try delete(account: CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        ))
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func copyData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw keychainFailure("credential.keychain_read_failed", status)
        }
        return data
    }

    private func contains(account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw keychainFailure("credential.keychain_read_failed", status)
        }
        return true
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainFailure("credential.keychain_delete_failed", status)
        }
    }
}

private func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for (lhs, rhs) in zip(left, right) { difference |= lhs ^ rhs }
    return difference == 0
}

private func eraseData(_ data: inout Data) {
    if !data.isEmpty { data.resetBytes(in: data.startIndex..<data.endIndex) }
    data.removeAll(keepingCapacity: false)
}

private func credentialFailure(_ code: String, _ message: String) -> CredentialFailure {
    CredentialFailure(code: code, message: message)
}

private func keychainFailure(_ code: String, _ status: OSStatus) -> CredentialFailure {
    CredentialFailure(code: code, message: "Keychain operation failed with status \(status)")
}
