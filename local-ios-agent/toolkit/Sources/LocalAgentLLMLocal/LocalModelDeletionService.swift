import Foundation
import LocalAgentLLMContracts

package enum LocalModelDeletionCrashPoint: String, Sendable {
    case afterTrashMove = "after-trash-move"
}

package struct LocalModelDeletionService: Sendable {
    private let store: LocalModelStore
    private let paths: LocalModelPaths
    private let crashPointForTesting: LocalModelDeletionCrashPoint?

    package init(
        store: LocalModelStore,
        paths: LocalModelPaths,
        crashPointForTesting: LocalModelDeletionCrashPoint? = nil
    ) {
        self.store = store
        self.paths = paths
        self.crashPointForTesting = crashPointForTesting
    }

    package func delete(installationID: String) throws {
        guard let operation = try store.beginDeletion(
            operationID: "delete-\(UUID().uuidString.lowercased())",
            installationID: installationID
        ) else { return }
        try resumeDeletion(operationID: operation.operationID)
    }

    package func resumeDeletion(operationID: String) throws {
        guard let operation = try store.unfinishedFilesystemOperations().first(where: {
            $0.operationID == operationID && $0.kind == .deleteInstallation
        }) else { return }
        let final = try paths.finalInstallation(operation.installationID)
        let trash = try paths.trashOperation(operation.operationID)
        let finalExists = FileManager.default.fileExists(atPath: final.path)
        let trashExists = FileManager.default.fileExists(atPath: trash.path)
        guard !(finalExists && trashExists) else {
            throw deletionFailure(
                "deletion.filesystem_conflict",
                "model exists in both installed and trash locations"
            )
        }
        if finalExists {
            try FileManager.default.moveItem(at: final, to: trash)
            try injectCrash(.afterTrashMove)
        }
        let refreshed = try store.unfinishedFilesystemOperations().first {
            $0.operationID == operationID
        }
        if refreshed?.state == .pending {
            try store.transitionFilesystemOperation(
                operationID: operationID,
                from: .pending,
                to: .filesystemApplied
            )
        }
        try store.completeDeletionOperation(operationID: operationID)
        if FileManager.default.fileExists(atPath: trash.path) {
            try FileManager.default.removeItem(at: trash)
        }
    }

    private func injectCrash(_ point: LocalModelDeletionCrashPoint) throws {
        guard crashPointForTesting == point else { return }
        throw deletionFailure(
            "deletion.interrupted",
            "injected deletion crash at \(point.rawValue)"
        )
    }
}

private func deletionFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
