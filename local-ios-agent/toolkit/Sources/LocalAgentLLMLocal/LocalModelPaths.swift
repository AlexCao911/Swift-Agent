import Foundation
import LocalAgentLLMContracts

package struct LocalModelPaths: Sendable {
    package let root: URL
    package let stagingRoot: URL
    package let installationsRoot: URL
    package let trashRoot: URL
    package let resumeRoot: URL

    package init(
        root: URL,
        backupExclusion: any LocalBackupExclusionApplying = SystemLocalBackupExclusion()
    ) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw pathFailure("download.path_root_invalid", "local model root must be an absolute file URL")
        }
        self.root = root.standardizedFileURL
        stagingRoot = self.root.appending(path: "staging", directoryHint: .isDirectory)
        installationsRoot = self.root.appending(path: "installations", directoryHint: .isDirectory)
        trashRoot = self.root.appending(path: "trash", directoryHint: .isDirectory)
        resumeRoot = self.root.appending(path: "resume", directoryHint: .isDirectory)
        let directories = [self.root, stagingRoot, installationsRoot, trashRoot, resumeRoot]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try backupExclusion.excludeFromBackup(directories)
        try Self.requireOneVolume(directories)
    }

    package func stagingInstallation(_ installationID: String) throws -> URL {
        try childDirectory(installationID, under: stagingRoot)
    }

    package func finalInstallation(_ installationID: String) throws -> URL {
        try childDirectory(installationID, under: installationsRoot)
    }

    package func trashedInstallation(_ installationID: String) throws -> URL {
        try childDirectory(installationID, under: trashRoot)
    }

    package func trashOperation(_ operationID: String) throws -> URL {
        try childDirectory(operationID, under: trashRoot)
    }

    package func resumeState(_ installationID: String, artifactID: String) throws -> URL {
        let directory = try childDirectory(installationID, under: resumeRoot)
        try validateOpaqueComponent(artifactID)
        return try confined(directory.appending(path: "\(artifactID).resume"), under: directory)
    }

    package func stagingArtifact(
        installationID: String,
        relativePath: String
    ) throws -> URL {
        try artifact(installationID: installationID, relativePath: relativePath, under: stagingRoot)
    }

    package func installedArtifact(
        installationID: String,
        relativePath: String
    ) throws -> URL {
        try artifact(installationID: installationID, relativePath: relativePath, under: installationsRoot)
    }

    private func artifact(
        installationID: String,
        relativePath: String,
        under base: URL
    ) throws -> URL {
        let installation = try childDirectory(installationID, under: base)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\") else {
            throw traversalFailure()
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw traversalFailure()
        }
        return try confined(installation.appending(path: relativePath), under: installation)
    }

    private func childDirectory(_ component: String, under base: URL) throws -> URL {
        try validateOpaqueComponent(component)
        return try confined(base.appending(path: component, directoryHint: .isDirectory), under: base)
    }

    private func validateOpaqueComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".", component != "..",
              !component.contains("/"), !component.contains("\\"),
              !component.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw traversalFailure() }
    }

    private func confined(_ candidate: URL, under base: URL) throws -> URL {
        let lexicalBase = base.standardizedFileURL
        let lexicalCandidate = candidate.standardizedFileURL
        let lexicalPrefix = lexicalBase.path.hasSuffix("/") ? lexicalBase.path : lexicalBase.path + "/"
        guard lexicalCandidate.path.hasPrefix(lexicalPrefix) else { throw traversalFailure() }

        let resolvedBase = lexicalBase.resolvingSymlinksInPath()
        let prefix = resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
        let relative = lexicalCandidate.path.dropFirst(lexicalPrefix.count)
        var cursor = resolvedBase
        for component in relative.split(separator: "/") {
            cursor = cursor.appending(path: String(component)).resolvingSymlinksInPath()
            guard cursor.path.hasPrefix(prefix) else { throw traversalFailure() }
        }
        return lexicalCandidate
    }

    private static func requireOneVolume(_ directories: [URL]) throws {
        let identifiers = try directories.map {
            try $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        }
        guard let first = identifiers.first ?? nil,
              identifiers.dropFirst().allSatisfy({ candidate in
                  guard let candidate else { return false }
                  return first.isEqual(candidate)
              })
        else {
            throw pathFailure(
                "download.path_volume_mismatch",
                "local model staging and installation directories must share one volume"
            )
        }
    }
}

private func traversalFailure() -> LLMFailure {
    pathFailure("download.path_traversal", "local model path escapes its app-owned root")
}

private func pathFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
