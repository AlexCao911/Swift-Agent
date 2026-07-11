import CryptoKit
import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Verified atomic local model installation")
struct LocalModelInstallerTests {
    @Test
    func validMultiArtifactPackageIsValidatedRenamedAndCommitted() throws {
        let fixture = try TestLocalInstallFixture()
        try fixture.prepareVerifyingInstallation()
        let installer = LocalModelInstaller(
            store: fixture.store,
            paths: fixture.paths,
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        try installer.verifyAndInstall(
            installationID: fixture.installationID,
            manifest: fixture.manifest
        )

        let storedSummary = try fixture.store.installationSummary(
            installationID: fixture.installationID
        )
        let summary = try #require(storedSummary)
        #expect(summary.state == .installed)
        #expect(FileManager.default.fileExists(
            atPath: try fixture.paths.finalInstallation(fixture.installationID).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: try fixture.paths.stagingInstallation(fixture.installationID).path
        ))
        #expect(fixture.validator.validatedRoles == Set(fixture.manifest.artifacts.map(\.role)))
        #expect(fixture.backup.urls.contains(try fixture.paths.finalInstallation(fixture.installationID)))
        #expect(try fixture.store.unfinishedFilesystemOperations().isEmpty)
    }

    @Test(arguments: [
        InstallCorruption.wrongSize,
        .oneBitHashMismatch,
        .missingArtifact,
        .unexpectedFile,
    ])
    func corruptOrUnexpectedFilesFailClosed(_ corruption: InstallCorruption) throws {
        let fixture = try TestLocalInstallFixture()
        try fixture.prepareVerifyingInstallation(corruption: corruption)
        let installer = LocalModelInstaller(
            store: fixture.store,
            paths: fixture.paths,
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        try expectInstallFailure("installation.checksum_mismatch") {
            try installer.verifyAndInstall(
                installationID: fixture.installationID,
                manifest: fixture.manifest
            )
        }

        let storedSummary = try fixture.store.installationSummary(
            installationID: fixture.installationID
        )
        let summary = try #require(storedSummary)
        #expect(summary.state == .failed)
        #expect(summary.failureCode == "installation.checksum_mismatch")
        #expect(!FileManager.default.fileExists(
            atPath: try fixture.paths.finalInstallation(fixture.installationID).path
        ))
        #expect(fixture.validator.callCount == 0)
    }

    @Test
    func engineIncompatibilityFailsBeforeRenameWithStableCode() throws {
        let fixture = try TestLocalInstallFixture()
        try fixture.prepareVerifyingInstallation()
        fixture.validator.shouldReject = true
        let installer = LocalModelInstaller(
            store: fixture.store,
            paths: fixture.paths,
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        try expectInstallFailure("installation.engine_incompatible") {
            try installer.verifyAndInstall(
                installationID: fixture.installationID,
                manifest: fixture.manifest
            )
        }

        let storedSummary = try fixture.store.installationSummary(
            installationID: fixture.installationID
        )
        let summary = try #require(storedSummary)
        #expect(summary.state == .failed)
        #expect(summary.failureCode == "installation.engine_incompatible")
        #expect(FileManager.default.fileExists(
            atPath: try fixture.paths.stagingInstallation(fixture.installationID).path
        ))
    }
}

enum InstallCorruption: Sendable {
    case wrongSize
    case oneBitHashMismatch
    case missingArtifact
    case unexpectedFile
}

final class TestLocalInstallFixture: @unchecked Sendable {
    let root: URL
    let paths: LocalModelPaths
    let store: LocalModelStore
    let validator = RecordingLocalModelValidator()
    let backup = RecordingInstallBackupExclusion()
    let installationID: String
    let manifest: LocalModelRevisionManifest
    let artifactData: [String: Data]

    init(installationID: String = "install-test") throws {
        self.installationID = installationID
        root = FileManager.default.temporaryDirectory
            .appending(path: "local-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = try LocalModelPaths(root: root, backupExclusion: RecordingInstallBackupExclusion())
        store = try LocalModelStore(
            fileURL: root.appending(path: "local-models.sqlite"),
            backupExclusion: RecordingInstallBackupExclusion()
        )
        let weights = Data("tiny-weights-v1".utf8)
        let tokenizer = Data("{\"version\":1}".utf8)
        artifactData = ["weights": weights, "tokenizer": tokenizer]
        manifest = try makeInstallManifest(weights: weights, tokenizer: tokenizer)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func prepareVerifyingInstallation(
        corruption: InstallCorruption? = nil
    ) throws {
        _ = try store.enqueueInstallation(
            installationID: installationID,
            modelRevision: manifest.id,
            rootPath: try paths.finalInstallation(installationID).path
        )
        let storedSummary = try store.installationSummary(installationID: installationID)
        var summary = try #require(storedSummary)
        summary = try store.transitionInstallation(
            installationID: installationID,
            expectedStateRevision: summary.stateRevision,
            to: .downloading
        )
        summary = try store.transitionInstallation(
            installationID: installationID,
            expectedStateRevision: summary.stateRevision,
            to: .verifying
        )
        _ = summary
        let staging = try paths.stagingInstallation(installationID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for artifact in manifest.artifacts {
            try store.recordArtifact(
                installationID: installationID,
                artifactID: artifact.artifactID,
                relativePath: artifact.relativePath,
                downloadURL: artifact.downloadURL,
                expectedBytes: artifact.byteSize,
                artifactSHA256: artifact.artifactSHA256
            )
            if corruption == .missingArtifact, artifact.artifactID == "tokenizer" { continue }
            var bytes = try #require(artifactData[artifact.artifactID])
            if corruption == .wrongSize, artifact.artifactID == "weights" {
                bytes.append(0)
            }
            if corruption == .oneBitHashMismatch, artifact.artifactID == "weights" {
                bytes[bytes.startIndex] ^= 1
            }
            let url = try paths.stagingArtifact(
                installationID: installationID,
                relativePath: artifact.relativePath
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: url)
        }
        if corruption == .unexpectedFile {
            try Data("surprise".utf8).write(to: staging.appending(path: "unexpected.bin"))
        }
    }
}

final class RecordingLocalModelValidator: LocalModelConfigValidator, @unchecked Sendable {
    private let lock = NSLock()
    var shouldReject = false
    private(set) var callCount = 0
    private(set) var validatedRoles: Set<LocalModelArtifactRole> = []

    func validate(
        manifest: LocalModelRevisionManifest,
        artifactPathsByRole: [LocalModelArtifactRole: URL]
    ) throws {
        try lock.withLock {
            callCount += 1
            validatedRoles = Set(artifactPathsByRole.keys)
            if shouldReject {
                throw LLMFailure(
                    code: "native.unsupported_model",
                    message: "private backend detail",
                    retryable: false
                )
            }
        }
    }
}

final class RecordingInstallBackupExclusion: LocalBackupExclusionApplying, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    func excludeFromBackup(_ urls: [URL]) throws {
        lock.withLock { self.urls.append(contentsOf: urls) }
    }
}

private func makeInstallManifest(
    weights: Data,
    tokenizer: Data
) throws -> LocalModelRevisionManifest {
    let base = try productionInstallManifest()
    let artifacts = [
        LocalModelArtifactManifest(
            artifactID: "weights",
            role: .weights,
            relativePath: "weights/model.gguf",
            downloadURL: URL(string: "https://example.com/model.gguf")!,
            byteSize: UInt64(weights.count),
            artifactSHA256: sha256Hex(weights)
        ),
        LocalModelArtifactManifest(
            artifactID: "tokenizer",
            role: .tokenizer,
            relativePath: "tokenizer.json",
            downloadURL: URL(string: "https://example.com/tokenizer.json")!,
            byteSize: UInt64(tokenizer.count),
            artifactSHA256: sha256Hex(tokenizer)
        ),
    ]
    return LocalModelRevisionManifest(
        id: LocalModelRevisionID(modelID: "install-test-model", revision: 1),
        displayName: base.displayName,
        family: base.family,
        engineID: base.engineID,
        modelFormat: base.modelFormat,
        artifacts: artifacts,
        installedByteSize: artifacts.reduce(0) { $0 + $1.byteSize },
        minimumOSMajor: base.minimumOSMajor,
        supportedDeviceClasses: base.supportedDeviceClasses,
        estimatedMemoryClass: base.estimatedMemoryClass,
        declaredCapabilities: base.declaredCapabilities,
        parameterSchema: base.parameterSchema,
        parameterDefaults: base.parameterDefaults,
        loadTemplate: base.loadTemplate,
        chatTemplate: base.chatTemplate,
        toolCallCodecID: base.toolCallCodecID
    )
}

private func productionInstallManifest() throws -> LocalModelRevisionManifest {
    let resources = try OfficialModelCatalogResources.loadBundled()
    return try #require(OfficialLocalModelCatalogVerifier.verify(
        envelope: resources.envelope,
        keyRing: resources.keyRing
    ).models.values.first)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func expectInstallFailure(
    _ code: String,
    operation: () throws -> Void
) throws {
    do {
        try operation()
        Issue.record("expected LLMFailure \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    }
}
