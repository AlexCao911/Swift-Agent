import CryptoKit
import Foundation
import LocalAgentLLMContracts

package protocol LocalModelConfigValidator: Sendable {
    func validate(
        manifest: LocalModelRevisionManifest,
        artifactPathsByRole: [LocalModelArtifactRole: URL]
    ) throws
}

package enum LocalModelInstallationCrashPoint: String, CaseIterable, Sendable {
    case afterPromotionIntent = "after-promotion-intent"
    case afterFilesystemRename = "after-filesystem-rename"
}

package struct LocalModelInstaller: Sendable {
    private let store: LocalModelStore
    private let paths: LocalModelPaths
    private let validator: any LocalModelConfigValidator
    private let backupExclusion: any LocalBackupExclusionApplying
    private let crashPointForTesting: LocalModelInstallationCrashPoint?

    package init(
        store: LocalModelStore,
        paths: LocalModelPaths,
        validator: any LocalModelConfigValidator,
        backupExclusion: any LocalBackupExclusionApplying = SystemLocalBackupExclusion(),
        crashPointForTesting: LocalModelInstallationCrashPoint? = nil
    ) {
        self.store = store
        self.paths = paths
        self.validator = validator
        self.backupExclusion = backupExclusion
        self.crashPointForTesting = crashPointForTesting
    }

    package func verifyAndInstall(
        installationID: String,
        manifest: LocalModelRevisionManifest
    ) throws {
        guard let installation = try store.installationRecord(installationID: installationID),
              installation.state == .verifying,
              installation.modelRevision == manifest.id
        else {
            throw installFailure(
                "installation.interrupted",
                "installation is not at the signed verifying revision"
            )
        }
        let staging = try paths.stagingInstallation(installationID)
        do {
            try verifyDirectory(staging, manifest: manifest)
        } catch let failure as LLMFailure {
            try markVerificationFailure(installationID: installationID, code: failure.code)
            throw failure
        } catch {
            let failure = checksumFailure("artifact could not be read for verification")
            try markVerificationFailure(installationID: installationID, code: failure.code)
            throw failure
        }
        let operation = try store.createFilesystemOperation(
            operationID: "promote-\(UUID().uuidString.lowercased())",
            installationID: installationID,
            kind: .promoteInstallation
        )
        try injectCrash(.afterPromotionIntent)
        try resumePromotion(operationID: operation.operationID, manifest: manifest)
    }

    package func resumePromotion(
        operationID: String,
        manifest: LocalModelRevisionManifest
    ) throws {
        guard let operation = try store.unfinishedFilesystemOperations().first(where: {
            $0.operationID == operationID && $0.kind == .promoteInstallation
        }),
            let installation = try store.installationRecord(
                installationID: operation.installationID
            ),
            installation.state == .verifying,
            installation.modelRevision == manifest.id
        else { return }

        let staging = try paths.stagingInstallation(operation.installationID)
        let final = try paths.finalInstallation(operation.installationID)
        let stagingExists = FileManager.default.fileExists(atPath: staging.path)
        let finalExists = FileManager.default.fileExists(atPath: final.path)
        guard stagingExists != finalExists else {
            try store.failPromotion(
                operationID: operationID,
                failureCode: "installation.interrupted"
            )
            throw installFailure(
                "installation.interrupted",
                "promotion has missing or conflicting filesystem state"
            )
        }

        let verificationRoot = finalExists ? final : staging
        do {
            try verifyDirectory(verificationRoot, manifest: manifest)
        } catch let failure as LLMFailure {
            if finalExists { try quarantine(final, installationID: operation.installationID) }
            try store.failPromotion(operationID: operationID, failureCode: failure.code)
            throw failure
        } catch {
            let failure = checksumFailure("artifact could not be read for verification")
            if finalExists { try quarantine(final, installationID: operation.installationID) }
            try store.failPromotion(operationID: operationID, failureCode: failure.code)
            throw failure
        }

        if stagingExists {
            try FileManager.default.moveItem(at: staging, to: final)
            try injectCrash(.afterFilesystemRename)
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
        try backupExclusion.excludeFromBackup([final])
        try store.completePromotion(operationID: operationID)
    }

    package func verifyDirectory(
        _ root: URL,
        manifest: LocalModelRevisionManifest
    ) throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw checksumFailure("staging directory is missing")
        }
        let expectedPaths = Set(manifest.artifacts.map(\.relativePath))
        let actualPaths = try regularFilePaths(under: root)
        guard actualPaths == expectedPaths else {
            throw checksumFailure("staging file set does not match the signed manifest")
        }

        var pathsByRole: [LocalModelArtifactRole: URL] = [:]
        for artifact in manifest.artifacts {
            guard pathsByRole[artifact.role] == nil else {
                throw checksumFailure("manifest contains duplicate artifact roles")
            }
            let url = root.appending(path: artifact.relativePath)
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize.flatMap(UInt64.init(exactly:)) == artifact.byteSize,
                  try sha256Hex(of: url) == artifact.artifactSHA256.lowercased()
            else { throw checksumFailure("artifact size or SHA-256 does not match") }
            pathsByRole[artifact.role] = url
        }
        guard manifest.loadTemplate.requiredArtifactRoles.isSubset(of: Set(pathsByRole.keys)) else {
            throw checksumFailure("required artifact role is missing")
        }
        do {
            try validator.validate(manifest: manifest, artifactPathsByRole: pathsByRole)
        } catch {
            throw installFailure(
                "installation.engine_incompatible",
                "native engine rejected the signed model configuration"
            )
        }
    }

    private func markVerificationFailure(
        installationID: String,
        code: String
    ) throws {
        guard let installation = try store.installationSummary(installationID: installationID),
              installation.state == .verifying
        else { return }
        _ = try store.transitionInstallation(
            installationID: installationID,
            expectedStateRevision: installation.stateRevision,
            to: .failed,
            failureCode: code
        )
        try store.releaseDiskReservation(installationID: installationID)
    }

    private func quarantine(_ final: URL, installationID: String) throws {
        let trash = try paths.trashedInstallation(installationID)
        if FileManager.default.fileExists(atPath: trash.path) {
            try FileManager.default.removeItem(at: trash)
        }
        try FileManager.default.moveItem(at: final, to: trash)
        try FileManager.default.removeItem(at: trash)
    }

    private func injectCrash(_ point: LocalModelInstallationCrashPoint) throws {
        guard crashPointForTesting == point else { return }
        throw installFailure(
            "installation.interrupted",
            "injected promotion crash at \(point.rawValue)"
        )
    }
}

private func regularFilePaths(under root: URL) throws -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [],
        errorHandler: { _, _ in false }
    ) else { throw checksumFailure("staging directory cannot be enumerated") }
    let prefix = root.standardizedFileURL.path + "/"
    var result: Set<String> = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        if values.isDirectory == true, values.isSymbolicLink != true { continue }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.standardizedFileURL.path.hasPrefix(prefix)
        else { throw checksumFailure("staging contains a non-regular file") }
        result.insert(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
    }
    return result
}

private func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func checksumFailure(_ message: String) -> LLMFailure {
    installFailure("installation.checksum_mismatch", message)
}

private func installFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
