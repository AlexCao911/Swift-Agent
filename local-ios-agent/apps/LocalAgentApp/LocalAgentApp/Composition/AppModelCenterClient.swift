import Foundation
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore
import LocalAgentLLMLocal

typealias ModelCenterCloudProviderState = CloudProviderProductState
typealias ModelCenterCloudModelState = CloudModelProductState

struct LocalModelCenterState: Equatable, Identifiable, Sendable {
    let modelRevision: LocalModelRevisionID
    let displayName: String
    let requiredBytes: UInt64
    let parameterSchema: LLMParameterSchema
    let parameterDefaults: GenerationConfiguration
    let installation: LocalModelProductState?

    var id: String {
        "local:\(modelRevision.modelID):\(modelRevision.revision)"
    }
}

struct ModelCenterSnapshot: Equatable, Sendable {
    let localModels: [LocalModelCenterState]
    let cloudProviders: [ModelCenterCloudProviderState]
    let cloudModels: [ModelCenterCloudModelState]
    let targets: [LLMTargetRevision]
    let disk: LocalDiskProductState?

    static let empty = Self(
        localModels: [],
        cloudProviders: [],
        cloudModels: [],
        targets: [],
        disk: nil
    )
}

struct CloudModelSelection: Equatable, Sendable {
    let profileID: String
    let profileRevision: UInt64
    let modelID: String
}

struct ProviderProfileProductDraft: Sendable {
    let profileID: String?
    let replacingRevision: UInt64?
    let presetID: ProviderPresetID
    let displayName: String
    let baseURL: URL
    let retentionMode: ProviderRetentionMode
    let initialSecret: SecretBytes?
}

protocol ModelCenterClient: Sendable {
    var updates: AsyncStream<Void> { get }
    func snapshot() async throws -> ModelCenterSnapshot
    func enqueueLocalModel(_ id: LocalModelRevisionID) async throws
    func pauseLocalModel(installationID: String) async throws
    func resumeLocalModel(installationID: String) async throws
    func cancelLocalModel(installationID: String) async throws
    func deleteLocalModel(installationID: String) async throws
    func publishProviderProfile(_ draft: ProviderProfileProductDraft) async throws
    func rotateProviderCredential(
        profileID: String,
        profileRevision: UInt64,
        replacement: SecretBytes
    ) async throws
    func archiveProviderProfile(profileID: String) async throws
    func validateProviderModel(_ selection: CloudModelSelection) async throws
    func publishTarget(_ target: LLMTargetRevision) async throws
}

actor AppModelCenterClient: ModelCenterClient {
    nonisolated let updates: AsyncStream<Void>

    private let local: LocalLLMSubsystem
    private let cloud: CloudLLMSubsystem
    private let store: LLMStore
    private let updateContinuation: AsyncStream<Void>.Continuation

    init(local: LocalLLMSubsystem, cloud: CloudLLMSubsystem, store: LLMStore) {
        var continuation: AsyncStream<Void>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        updateContinuation = continuation
        self.local = local
        self.cloud = cloud
        self.store = store
        Task {
            for await _ in local.downloadStateChanges {
                continuation.yield()
            }
        }
    }

    func snapshot() async throws -> ModelCenterSnapshot {
        let installations = try await local.inventory()
        var localModels = local.compatibleModels()
            .map { manifest in
                LocalModelCenterState(
                    modelRevision: manifest.id,
                    displayName: manifest.displayName,
                    requiredBytes: manifest.installedByteSize,
                    parameterSchema: manifest.parameterSchema,
                    parameterDefaults: manifest.parameterDefaults,
                    installation: installations
                        .filter { $0.modelRevision == manifest.id }
                        .sorted { $0.installationID < $1.installationID }
                        .last
                )
            }
        let representedInstallations = Set(localModels.compactMap {
            $0.installation?.installationID
        })
        for installation in installations where
            !representedInstallations.contains(installation.installationID) {
            let manifest = local.acceptedCatalog.verified.models[installation.modelRevision]
            localModels.append(LocalModelCenterState(
                modelRevision: installation.modelRevision,
                displayName: manifest?.displayName
                    ?? "\(installation.modelRevision.modelID) (Previously Installed)",
                requiredBytes: installation.requiredBytes,
                parameterSchema: manifest?.parameterSchema
                    ?? LLMParameterSchema(definitions: []),
                parameterDefaults: manifest?.parameterDefaults
                    ?? GenerationConfiguration(),
                installation: installation
            ))
        }
        localModels.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
        }
        let providers = try await cloud.providerInventory()
        var cloudModels: [ModelCenterCloudModelState] = []
        for provider in providers {
            cloudModels += try await cloud.modelInventory(
                profileID: provider.profileID,
                profileRevision: provider.revision
            )
        }
        return ModelCenterSnapshot(
            localModels: localModels,
            cloudProviders: providers,
            cloudModels: cloudModels.sorted { $0.id < $1.id },
            targets: await store.targets(),
            disk: try await local.diskState()
        )
    }

    func enqueueLocalModel(_ id: LocalModelRevisionID) async throws {
        _ = try await local.enqueue(modelRevision: id)
        updateContinuation.yield()
    }

    func pauseLocalModel(installationID: String) async throws {
        try await local.pause(installationID: installationID)
        updateContinuation.yield()
    }

    func resumeLocalModel(installationID: String) async throws {
        try await local.resume(installationID: installationID)
        updateContinuation.yield()
    }

    func cancelLocalModel(installationID: String) async throws {
        try await local.cancel(installationID: installationID)
        updateContinuation.yield()
    }

    func deleteLocalModel(installationID: String) async throws {
        try await local.delete(installationID: installationID)
        updateContinuation.yield()
    }

    func publishProviderProfile(_ draft: ProviderProfileProductDraft) async throws {
        _ = try await cloud.publishProviderProfileRevision(
            profileID: draft.profileID,
            replacingRevision: draft.replacingRevision,
            presetID: draft.presetID,
            displayName: draft.displayName,
            baseURL: draft.baseURL,
            retentionMode: draft.retentionMode,
            initialSecret: draft.initialSecret
        )
        updateContinuation.yield()
    }

    func rotateProviderCredential(
        profileID: String,
        profileRevision: UInt64,
        replacement: SecretBytes
    ) async throws {
        try await cloud.rotateProviderCredential(
            profileID: profileID,
            profileRevision: profileRevision,
            replacement: replacement
        )
        updateContinuation.yield()
    }

    func archiveProviderProfile(profileID: String) async throws {
        try await cloud.archiveProviderProfile(profileID: profileID)
        updateContinuation.yield()
    }

    func validateProviderModel(_ selection: CloudModelSelection) async throws {
        _ = try await cloud.validation.validate(
            profileID: selection.profileID,
            profileRevision: selection.profileRevision,
            modelID: selection.modelID,
            adapterVersion: "1"
        )
        updateContinuation.yield()
    }

    func publishTarget(_ target: LLMTargetRevision) async throws {
        try await store.publishTarget(target)
        updateContinuation.yield()
    }
}

extension AppModelCenterClient: AgentLLMTargetCatalog {
    func targetOptions() async throws -> [AgentLLMTargetOption] {
        Self.availableTargetOptions(in: try await snapshot())
    }

    nonisolated static func availableTargetOptions(
        in state: ModelCenterSnapshot
    ) -> [AgentLLMTargetOption] {
        return state.targets.compactMap { target in
            let schema: LLMParameterSchema? = switch target.kind {
            case let .local(installationID):
                state.localModels.first {
                    $0.installation?.installationID == installationID
                        && $0.installation?.state == .installed
                        && $0.installation?.catalogStatus == .current
                        && $0.modelRevision.modelID == target.modelID
                }?.parameterSchema
            case let .cloud(profileID, revision):
                state.cloudModels.first {
                    $0.profileID == profileID
                        && $0.profileRevision == revision
                        && $0.modelID == target.modelID
                        && $0.validation.isCurrent
                }?.parameterSchema
            }
            return schema.map {
                AgentLLMTargetOption(target: target, parameterSchema: $0)
            }
        }
    }
}
