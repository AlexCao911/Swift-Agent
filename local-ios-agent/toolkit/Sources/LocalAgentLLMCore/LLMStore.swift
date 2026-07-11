import Foundation

public enum StoredHostBindingState: String, Codable, Equatable, Sendable {
    case staged
    case active
}

struct StoredHostBindingRecord: Codable, Equatable, Sendable {
    let request: HostBindingStageRequest
    let receipt: HostBindingStagingReceipt
    var state: StoredHostBindingState
}

private struct LLMStoreDocument: Codable, Equatable, Sendable {
    var schemaVersion: UInt64 = 1
    var hostBindings: [String: StoredHostBindingRecord] = [:]
}

public actor LLMStore {
    private let fileURL: URL?
    private var document: LLMStoreDocument
    private var injectedPersistenceFailure = false

    public static func inMemory() -> LLMStore {
        try! LLMStore(fileURL: nil)
    }

    public init(fileURL: URL) throws {
        try self.init(fileURL: Optional(fileURL))
    }

    private init(fileURL: URL?) throws {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            document = try JSONDecoder().decode(LLMStoreDocument.self, from: data)
        } else {
            document = LLMStoreDocument()
        }
    }

    func stage(_ record: StoredHostBindingRecord) throws -> HostBindingStagingReceipt {
        let token = record.request.operationToken
        if let existing = document.hostBindings[token] {
            guard existing.request == record.request, existing.receipt == record.receipt else {
                throw HostBindingSagaError(
                    code: "host_binding.idempotency_conflict",
                    message: "operation token was replayed with different staging input"
                )
            }
            return existing.receipt
        }
        let previous = document
        document.hostBindings[token] = record
        do {
            try persist()
        } catch {
            document = previous
            throw error
        }
        return record.receipt
    }

    func activate(token: String, binding: HostBindingTuple) throws {
        guard var record = document.hostBindings[token] else {
            throw HostBindingSagaError(
                code: "host_binding.staged_binding_not_found",
                message: "no staged host binding exists for the operation token"
            )
        }
        guard record.receipt.binding == binding else {
            throw HostBindingSagaError(
                code: "host_binding.binding_mismatch",
                message: "activation tuple differs from the staged binding tuple"
            )
        }
        if record.state == .active { return }
        let previous = document
        record.state = .active
        document.hostBindings[token] = record
        do {
            try persist()
        } catch {
            document = previous
            throw error
        }
    }

    func record(token: String) -> StoredHostBindingRecord? {
        document.hostBindings[token]
    }

    public func bindingState(token: String) -> StoredHostBindingState? {
        document.hostBindings[token]?.state
    }

    func failNextPersistenceForTesting() {
        injectedPersistenceFailure = true
    }

    private func persist() throws {
        if injectedPersistenceFailure {
            injectedPersistenceFailure = false
            throw HostBindingSagaError(
                code: "llm_store.injected_persistence_failure",
                message: "injected LLM store persistence failure"
            )
        }
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: [.atomic])
    }
}
