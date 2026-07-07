import Foundation

public enum PendingInteractionKind: String, Codable, Sendable, Equatable {
    case filePicker = "file_picker"
    case photosPicker = "photos_picker"
    case documentScanner = "document_scanner"
    case systemConfirmation = "system_confirmation"
}

public enum PendingInteractionState: String, Codable, Sendable, Equatable {
    case requested
    case awaitingUserAction = "awaiting_user_action"
    case presentingSystemUI = "presenting_system_ui"
    case completed
    case cancelledByUser = "cancelled_by_user"
    case interrupted
    case needsRepair = "needs_repair"
    case expired
    case failed
}

public struct PendingUserInteractionRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var runId: String
    public var toolCallId: String
    public var manifestId: String
    public var interactionKind: PendingInteractionKind
    public var state: PendingInteractionState
    public var resumablePayloadSummary: String
    public var expiresAtMillis: UInt64?

    public init(
        id: String,
        runId: String,
        toolCallId: String,
        manifestId: String,
        interactionKind: PendingInteractionKind,
        state: PendingInteractionState,
        resumablePayloadSummary: String,
        expiresAtMillis: UInt64?
    ) {
        self.id = id
        self.runId = runId
        self.toolCallId = toolCallId
        self.manifestId = manifestId
        self.interactionKind = interactionKind
        self.state = state
        self.resumablePayloadSummary = resumablePayloadSummary
        self.expiresAtMillis = expiresAtMillis
    }
}

public protocol PendingUserInteractionStore: Sendable {
    func put(_ record: PendingUserInteractionRecord) async throws
    func pending(runId: String, toolCallId: String) async throws -> PendingUserInteractionRecord?
    func markState(_ state: PendingInteractionState, id: String) async throws
}

public actor InMemoryPendingUserInteractionStore: PendingUserInteractionStore {
    private var records: [String: PendingUserInteractionRecord] = [:]

    public init() {}

    public func put(_ record: PendingUserInteractionRecord) async throws {
        records[record.id] = record
    }

    public func pending(runId: String, toolCallId: String) async throws -> PendingUserInteractionRecord? {
        records.values.first { record in
            record.runId == runId && record.toolCallId == toolCallId
        }
    }

    public func markState(_ state: PendingInteractionState, id: String) async throws {
        guard var record = records[id] else {
            return
        }
        record.state = state
        records[id] = record
    }
}

public actor FileBackedPendingUserInteractionStore: PendingUserInteractionStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    public func put(_ record: PendingUserInteractionRecord) async throws {
        let data = try encoder.encode(record)
        try data.write(to: fileURL(for: record.id), options: [.atomic])
    }

    public func pending(runId: String, toolCallId: String) async throws -> PendingUserInteractionRecord? {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in urls where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            let record = try decoder.decode(PendingUserInteractionRecord.self, from: data)
            if record.runId == runId && record.toolCallId == toolCallId {
                return record
            }
        }
        return nil
    }

    public func markState(_ state: PendingInteractionState, id: String) async throws {
        let url = fileURL(for: id)
        let data = try Data(contentsOf: url)
        var record = try decoder.decode(PendingUserInteractionRecord.self, from: data)
        record.state = state
        try await put(record)
    }

    private func fileURL(for id: String) -> URL {
        directory.appending(path: "\(id).json")
    }
}

public enum PendingInteractionPresentationGate {
    public static func persistBeforePresenting(
        _ record: PendingUserInteractionRecord,
        store: any PendingUserInteractionStore,
        present: () async throws -> Void
    ) async throws {
        try await store.put(record)
        try await store.markState(.presentingSystemUI, id: record.id)
        try await present()
    }

    public static func complete(_ id: String, store: any PendingUserInteractionStore) async throws {
        try await store.markState(.completed, id: id)
    }

    public static func cancelByUser(_ id: String, store: any PendingUserInteractionStore) async throws {
        try await store.markState(.cancelledByUser, id: id)
    }
}
