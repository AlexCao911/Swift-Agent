import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import LocalAgentLLMLocal
import Observation

@MainActor
@Observable
final class ModelCenterViewModel {
    private(set) var snapshot: ModelCenterSnapshot = .empty
    private(set) var selectedTarget: LLMTargetReference?
    private(set) var selectedModelID: String?
    private(set) var activeModel: ActiveModelSummary?
    var targetDefaults = GenerationConfiguration()
    private(set) var parameterNotice: String?
    private(set) var pendingMigrations: [LegacyLLMMigrationItem] = []
    private(set) var readinessIssues: [String]
    var migrationTargetSelections: [String: String] = [:]
    var errorMessage: String?
    var showingProviderEditor = false

    private let client: (any ModelCenterClient)?
    private let migration: (any LegacyLLMMigrationPresenting)?

    init(
        client: (any ModelCenterClient)? = nil,
        migration: (any LegacyLLMMigrationPresenting)? = nil,
        readinessIssues: [String] = []
    ) {
        self.client = client
        self.migration = migration
        self.readinessIssues = readinessIssues
    }

    func reload() async {
        guard let client else { return }
        do {
            snapshot = try await client.snapshot()
            pendingMigrations = try await migration?.pendingItems() ?? []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func syncActiveModel(
        for agent: ActiveAgentRevisionSelection
    ) -> ActiveModelSummary? {
        guard let binding = snapshot.activeBindings
            .filter({
                $0.configuration.agentProfileID == agent.profileId
                    && $0.configuration.agentProfileRevision
                        == agent.profileRevisionId
            })
            .sorted(by: {
                ($0.configuration.fallbackPriority ?? .max)
                    < ($1.configuration.fallbackPriority ?? .max)
            })
            .first,
              let target = snapshot.targets.first(where: {
                  $0.reference == binding.targetReference
              })
        else {
            activeModel = nil
            selectedTarget = nil
            selectedModelID = nil
            return nil
        }
        selectedTarget = target.reference
        switch target.kind {
        case let .local(installationID):
            let model = snapshot.localModels.first {
                $0.installation?.installationID == installationID
            }
            selectedModelID = model?.id
            activeModel = ActiveModelSummary(
                providerId: "local",
                modelId: target.modelID,
                displayName: model?.displayName ?? target.modelID,
                route: .localCpp(engineId: installationID),
                readiness: model?.installation?.state == .installed
                    ? .ready
                    : .unavailable(reason: "Model is not installed.")
            )
        case let .cloud(profileID, revision):
            let model = snapshot.cloudModels.first {
                $0.profileID == profileID
                    && $0.profileRevision == revision
                    && $0.modelID == target.modelID
            }
            selectedModelID = model.map(cloudModelID)
            activeModel = ActiveModelSummary(
                providerId: profileID,
                modelId: target.modelID,
                displayName: target.modelID,
                route: .cloud(providerId: profileID),
                readiness: model?.validation.isCurrent == true
                    ? .ready
                    : .unavailable(reason: "Provider validation is stale.")
            )
        }
        return activeModel
    }

    func observeUpdates() async {
        guard let client else { return }
        for await _ in client.updates {
            await reload()
        }
    }

    func selectModel(id: String) {
        guard let schema = parameterSchema(for: id) else { return }
        selectedModelID = id
        let supported = targetDefaults.parameters.filter { rawID, _ in
            schema.definitions[rawID]?.support == .supported
        }
        let removed = Set(targetDefaults.parameters.keys)
            .subtracting(supported.keys)
            .sorted()
        targetDefaults = GenerationConfiguration(parameters: supported)
        parameterNotice = removed.first.map {
            "\(parameterDisplayName($0)) is not supported by this model."
        }
    }

    func createTarget(modelID: String) async throws {
        guard let client else { return }
        let target = try makeTarget(modelID: modelID)
        try await client.publishTarget(target)
        selectedTarget = target.reference
        await reload()
    }

    private func makeTarget(modelID: String) throws -> LLMTargetRevision {
        selectModel(id: modelID)
        let target: LLMTargetRevision
        if let local = snapshot.localModels.first(where: { $0.id == modelID }),
           let installation = local.installation,
           installation.state == .installed,
           installation.catalogStatus == .current {
            let defaults = try LLMParameterSystem.resolve(
                modelDefaults: local.parameterDefaults,
                targetDefaults: targetDefaults,
                schema: local.parameterSchema
            )
            target = LLMTargetRevision(
                targetID: LLMTargetID(rawValue: UUID().uuidString.lowercased()),
                revision: 1,
                kind: .local(installationID: installation.installationID),
                modelID: local.modelRevision.modelID,
                defaultParameters: defaults
            )
        } else if let cloud = cloudModel(for: modelID) {
            let defaults = try LLMParameterSystem.resolve(
                targetDefaults: targetDefaults,
                schema: cloud.parameterSchema
            )
            target = LLMTargetRevision(
                targetID: LLMTargetID(rawValue: UUID().uuidString.lowercased()),
                revision: 1,
                kind: .cloud(
                    providerProfileID: cloud.profileID,
                    providerProfileRevision: cloud.profileRevision
                ),
                modelID: cloud.modelID,
                defaultParameters: defaults
            )
        } else {
            throw ModelCenterFailure("The selected model is not ready.")
        }
        return target
    }

    func activateModel(
        id modelID: String,
        for agent: ActiveAgentRevisionSelection
    ) async throws {
        guard let client else { return }
        let revision = try makeTarget(modelID: modelID)
        try await client.publishTarget(revision)
        try await client.activateTarget(
            revision,
            forAgentProfileID: agent.profileId,
            revision: agent.profileRevisionId
        )
        selectedTarget = revision.reference
        await reload()
    }

    func enqueueLocalModel(_ id: LocalModelRevisionID) async throws {
        try await client?.enqueueLocalModel(id)
    }

    func pauseLocalModel(installationID: String) async throws {
        try await client?.pauseLocalModel(installationID: installationID)
    }

    func resumeLocalModel(installationID: String) async throws {
        try await client?.resumeLocalModel(installationID: installationID)
    }

    func cancelLocalModel(installationID: String) async throws {
        try await client?.cancelLocalModel(installationID: installationID)
    }

    func deleteLocalModel(installationID: String) async throws {
        try await client?.deleteLocalModel(installationID: installationID)
    }

    var migrationTargets: [LLMTargetRevision] {
        AppModelCenterClient.availableTargetOptions(in: snapshot)
            .map(\.target)
            .sorted { migrationTargetKey($0) < migrationTargetKey($1) }
    }

    func migrate(_ item: LegacyLLMMigrationItem) async throws {
        guard let migration else { return }
        let selectedKey = migrationTargetSelections[item.sourceDigest]
        let target = migrationTargets.first {
            migrationTargetKey($0) == selectedKey
        }
        _ = try await migration.migrate(
            profileID: item.profileID,
            revision: item.revision,
            selectedTarget: target?.reference
        )
        readinessIssues.removeAll {
            $0 == "migration.target_selection_required"
                || $0 == "migration.binding_incomplete"
        }
        migrationTargetSelections[item.sourceDigest] = nil
        await reload()
    }

    func migrationTargetKey(_ target: LLMTargetRevision) -> String {
        "\(target.targetID.rawValue):\(target.revision)"
    }

    func validate(_ model: ModelCenterCloudModelState) async throws {
        try await client?.validateProviderModel(CloudModelSelection(
            profileID: model.profileID,
            profileRevision: model.profileRevision,
            modelID: model.modelID
        ))
    }

    func validateManual(
        _ modelID: String,
        for provider: ModelCenterCloudProviderState
    ) async throws {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelCenterFailure("Enter a model ID.")
        }
        try await client?.validateProviderModel(CloudModelSelection(
            profileID: provider.profileID,
            profileRevision: provider.revision,
            modelID: modelID
        ))
    }

    func archive(_ provider: ModelCenterCloudProviderState) async throws {
        try await client?.archiveProviderProfile(profileID: provider.profileID)
    }

    func parameterSchema(for id: String) -> LLMParameterSchema? {
        snapshot.localModels.first(where: { $0.id == id })?.parameterSchema
            ?? cloudModel(for: id)?.parameterSchema
    }

    func parameterValue(_ id: LLMParameterID) -> LLMParameterValue? {
        targetDefaults.value(for: id)
    }

    func setParameter(_ id: LLMParameterID, value: LLMParameterValue) {
        targetDefaults = targetDefaults.setting(id, to: value)
        parameterNotice = nil
    }

    func cloudModelID(_ model: ModelCenterCloudModelState) -> String {
        "cloud:\(model.profileID):\(model.profileRevision):\(model.modelID)"
    }

    func makeProviderEditor() -> ProviderProfileEditorViewModel? {
        client.map(ProviderProfileEditorViewModel.init(client:))
    }

    var unifiedModelOptions: [UnifiedModelOption] {
        UnifiedModelPickerProjection.options(in: snapshot)
    }

    private func cloudModel(for id: String) -> ModelCenterCloudModelState? {
        snapshot.cloudModels.first { cloudModelID($0) == id }
    }
}

private struct ModelCenterFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

private func parameterDisplayName(_ rawID: String) -> String {
    switch rawID {
    case LLMParameterID.samplingTemperature.rawValue: "Temperature"
    case LLMParameterID.samplingTopP.rawValue: "Top-p"
    case LLMParameterID.samplingTopK.rawValue: "Top-k"
    case LLMParameterID.reasoningEffort.rawValue: "Reasoning effort"
    default: rawID
    }
}
