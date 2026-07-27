import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Local model paths and disk policy")
struct LocalDiskPolicyTests {
    @Test
    func preflightUsesRemainingBytesInstallOverheadAndMinimumReserve() async throws {
        let store = try LocalModelStore.inMemory()
        let manifest = try productionManifest()
        _ = try store.enqueueInstallation(
            installationID: "install-a",
            modelRevision: manifest.id,
            rootPath: "/private/models/install-a"
        )
        let policy = LocalDiskPolicy(store: store, root: URL(fileURLWithPath: "/private/models"))
        let volume = FixedVolume(bytes: UInt64.max)

        let reservation = try await policy.preflight(
            installationID: "install-a",
            manifest: manifest,
            completedArtifactBytes: 100,
            volume: volume
        )
        let reserve = max(512 * 1_024 * 1_024, manifest.installedByteSize / 10)
        let remaining = manifest.artifacts.reduce(0) { $0 + $1.byteSize } - 100
        #expect(reservation.reservedBytes == remaining + manifest.installedByteSize + reserve)
    }

    @Test
    func repeatedPreflightForOneInstallationReusesItsReservation() async throws {
        let store = try LocalModelStore.inMemory()
        let manifest = try productionManifest()
        _ = try store.enqueueInstallation(
            installationID: "install-retry",
            modelRevision: manifest.id,
            rootPath: "/private/models/install-retry"
        )
        let policy = LocalDiskPolicy(store: store, root: URL(fileURLWithPath: "/private/models"))
        let volume = FixedVolume(bytes: UInt64.max)

        let first = try await policy.preflight(
            installationID: "install-retry",
            manifest: manifest,
            completedArtifactBytes: 0,
            volume: volume
        )
        let second = try await policy.preflight(
            installationID: "install-retry",
            manifest: manifest,
            completedArtifactBytes: 0,
            volume: volume
        )

        #expect(second.reservationID == first.reservationID)
        #expect(try store.totalReservedBytes() == first.reservedBytes)
    }

    @Test
    func pathsAreStableConfinedOneVolumeAndBackupExcluded() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appending(path: "Models", directoryHint: .isDirectory)
        let recorder = PathBackupRecorder()
        let paths = try LocalModelPaths(root: root, backupExclusion: recorder)

        let roots = [paths.root, paths.stagingRoot, paths.installationsRoot, paths.trashRoot, paths.resumeRoot]
        #expect(Set(recorder.urls) == Set(roots))
        #expect(roots.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let volumeIDs = try roots.map {
            try $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        }
        #expect(Set(volumeIDs.compactMap { $0 }.map { String(describing: $0) }).count == 1)

        #expect(try paths.stagingInstallation("install-a").path.hasSuffix("/staging/install-a"))
        #expect(try paths.finalInstallation("install-a").path.hasSuffix("/installations/install-a"))
        #expect(try paths.trashedInstallation("install-a").path.hasSuffix("/trash/install-a"))
        #expect(try paths.resumeState("install-a", artifactID: "weights").path.hasSuffix("/resume/install-a/weights.resume"))

        for invalid in ["../escape", "/absolute", "a/b", "a\\b", ".", "..", ""] {
            try expectDiskFailure("download.path_traversal") {
                try paths.stagingInstallation(invalid)
            }
        }
        for invalid in ["../model.gguf", "/model.gguf", "a/../../model", "a//model", "a\\model"] {
            try expectDiskFailure("download.path_traversal") {
                try paths.stagingArtifact(installationID: "install-a", relativePath: invalid)
            }
        }
    }

    @Test
    func symlinkCannotEscapeStagingRoot() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let external = parent.appending(path: "external", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let paths = try LocalModelPaths(root: parent.appending(path: "Models"))
        let installation = try paths.stagingInstallation("install-a")
        try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installation.appending(path: "escape"),
            withDestinationURL: external
        )

        try expectDiskFailure("download.path_traversal") {
            try paths.stagingArtifact(
                installationID: "install-a",
                relativePath: "escape/model.gguf"
            )
        }
    }

    @Test
    func insufficientDiskFailsWithoutDeletingOrReserving() async throws {
        let store = try LocalModelStore.inMemory()
        let manifest = try productionManifest()
        let summary = try store.enqueueInstallation(
            installationID: "insufficient",
            modelRevision: manifest.id,
            rootPath: "/private/models/insufficient"
        )
        let policy = LocalDiskPolicy(store: store, root: URL(fileURLWithPath: "/private/models"))
        let requirement = try policy.requirement(manifest: manifest, completedArtifactBytes: 0)
        let available = requirement.totalRequiredBytes - 1

        do {
            _ = try await policy.preflight(
                installationID: summary.installationID,
                manifest: manifest,
                completedArtifactBytes: 0,
                volume: FixedVolume(bytes: available)
            )
            Issue.record("expected insufficient disk")
        } catch let error as LLMFailure {
            #expect(error.code == "download.insufficient_disk")
            #expect(error.message.contains("requiredBytes=\(requirement.totalRequiredBytes)"))
            #expect(error.message.contains("availableBytes=\(available)"))
        }
        #expect(try store.installationSummary(installationID: summary.installationID)?.state == .queued)
        #expect(try store.totalReservedBytes() == 0)
    }

    @Test
    func concurrentStoresCannotReserveTheSameFreeBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "local-models.sqlite")
        let firstStore = try LocalModelStore(fileURL: databaseURL, backupExclusion: PathBackupRecorder())
        let manifest = try productionManifest()
        _ = try firstStore.enqueueInstallation(
            installationID: "first",
            modelRevision: LocalModelRevisionID(modelID: "first-model", revision: 1),
            rootPath: "/private/models/first"
        )
        _ = try firstStore.enqueueInstallation(
            installationID: "second",
            modelRevision: LocalModelRevisionID(modelID: "second-model", revision: 1),
            rootPath: "/private/models/second"
        )
        let secondStore = try LocalModelStore(fileURL: databaseURL, backupExclusion: PathBackupRecorder())
        let firstPolicy = LocalDiskPolicy(store: firstStore, root: directory)
        let secondPolicy = LocalDiskPolicy(store: secondStore, root: directory)
        let required = try firstPolicy.requirement(
            manifest: manifest,
            completedArtifactBytes: 0
        ).totalRequiredBytes
        let volume = FixedVolume(bytes: required + required / 2)

        async let firstOutcome = reservationOutcome(
            policy: firstPolicy,
            installationID: "first",
            manifest: manifest,
            volume: volume
        )
        async let secondOutcome = reservationOutcome(
            policy: secondPolicy,
            installationID: "second",
            manifest: manifest,
            volume: volume
        )
        let outcomes = await [firstOutcome, secondOutcome]
        #expect(outcomes.filter { $0 == "success" }.count == 1)
        #expect(outcomes.filter { $0 == "download.insufficient_disk" }.count == 1)
        #expect(try firstStore.totalReservedBytes() == required)
    }

    @Test
    func reserveUsesTenPercentWhenItExceedsTheMinimum() throws {
        let store = try LocalModelStore.inMemory()
        let base = try productionManifest()
        let tenGiB: UInt64 = 10 * 1_024 * 1_024 * 1_024
        let manifest = copy(base, installedByteSize: tenGiB)
        let policy = LocalDiskPolicy(store: store, root: URL(fileURLWithPath: "/private/models"))
        let requirement = try policy.requirement(manifest: manifest, completedArtifactBytes: 0)
        #expect(requirement.safetyReserveBytes == tenGiB / 10)
    }
}

private struct FixedVolume: LocalVolumeCapacity {
    let bytes: UInt64
    func availableImportantUsageBytes(at root: URL) throws -> UInt64 { bytes }
}

private func productionManifest() throws -> LocalModelRevisionManifest {
    let resources = try OfficialModelCatalogResources.loadBundled()
    let catalog = try OfficialLocalModelCatalogVerifier.verify(
        envelope: resources.envelope,
        keyRing: resources.keyRing
    )
    return try #require(catalog.models[
        LocalModelRevisionID(modelID: "gemma-3-1b-it-q4", revision: 1)
    ])
}

private func copy(
    _ model: LocalModelRevisionManifest,
    installedByteSize: UInt64
) -> LocalModelRevisionManifest {
    LocalModelRevisionManifest(
        id: model.id,
        displayName: model.displayName,
        family: model.family,
        engineID: model.engineID,
        modelFormat: model.modelFormat,
        artifacts: model.artifacts,
        installedByteSize: installedByteSize,
        minimumOSMajor: model.minimumOSMajor,
        supportedDeviceClasses: model.supportedDeviceClasses,
        estimatedMemoryClass: model.estimatedMemoryClass,
        declaredCapabilities: model.declaredCapabilities,
        parameterSchema: model.parameterSchema,
        parameterDefaults: model.parameterDefaults,
        loadTemplate: model.loadTemplate,
        chatTemplate: model.chatTemplate,
        toolCallCodecID: model.toolCallCodecID
    )
}

private func expectDiskFailure<T>(_ code: String, _ operation: () throws -> T) throws {
    do {
        _ = try operation()
        Issue.record("expected LLMFailure \(code)")
    } catch let error as LLMFailure {
        #expect(error.code == code)
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "local-disk-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private final class PathBackupRecorder: LocalBackupExclusionApplying, @unchecked Sendable {
    private(set) var urls: [URL] = []
    func excludeFromBackup(_ urls: [URL]) throws { self.urls.append(contentsOf: urls) }
}

private func reservationOutcome(
    policy: LocalDiskPolicy,
    installationID: String,
    manifest: LocalModelRevisionManifest,
    volume: any LocalVolumeCapacity
) async -> String {
    do {
        _ = try await policy.preflight(
            installationID: installationID,
            manifest: manifest,
            completedArtifactBytes: 0,
            volume: volume
        )
        return "success"
    } catch let error as LLMFailure {
        return error.code
    } catch {
        return "unexpected"
    }
}
