import Foundation
import LocalAgentBridge

public enum NativeAttachmentAccessState: String, Codable, Sendable, Equatable {
    case available
    case needsUserReselection = "needs_user_reselection"
    case unavailable
}

public struct NativeAttachmentRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sourceFamily: String
    public var contentType: String
    public var displayName: String
    public var accessState: NativeAttachmentAccessState
    public var sizeBytes: Int
    public var sensitivity: SensitivityDTO
    public var trustLevel: NativeToolTrustLevel

    public init(
        id: String,
        sourceFamily: String,
        contentType: String,
        displayName: String,
        accessState: NativeAttachmentAccessState,
        sizeBytes: Int,
        sensitivity: SensitivityDTO,
        trustLevel: NativeToolTrustLevel
    ) {
        self.id = id
        self.sourceFamily = sourceFamily
        self.contentType = contentType
        self.displayName = displayName
        self.accessState = accessState
        self.sizeBytes = sizeBytes
        self.sensitivity = sensitivity
        self.trustLevel = trustLevel
    }
}

public actor InMemoryNativeAttachmentStore {
    private var records: [String: NativeAttachmentRecord] = [:]

    public init() {}

    public func put(_ record: NativeAttachmentRecord) {
        records[record.id] = record
    }

    public func get(_ id: String) -> NativeAttachmentRecord? {
        records[id]
    }

    public func markNeedsUserReselection(_ id: String) {
        guard var record = records[id] else {
            return
        }
        record.accessState = .needsUserReselection
        records[id] = record
    }
}
