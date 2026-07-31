import Foundation
import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore
import LocalAgentLLMLocal
import Testing
@testable import LocalAgentApp

@Suite("Model Center view model")
@MainActor
struct ModelCenterViewModelTests {
    @Test
    func selectingAModelCreatesOneImmutableTargetRevision() async throws {
        let client = ModelCenterClientSpy(snapshot: .fixture)
        let viewModel = ModelCenterViewModel(client: client)
        await viewModel.reload()
        let agent = ActiveAgentRevisionSelection(
            profileId: "agent-profile",
            profileRevisionId: 4,
            displayName: "Agent"
        )

        try await viewModel.activateModel(
            id: "local:official-1:1",
            for: agent
        )

        let published = await client.publishedTargets
        let activated = await client.activatedTargets
        #expect(published.count == 1)
        #expect(activated == [
            ActivatedModelTarget(
                agentProfileID: "agent-profile",
                agentProfileRevision: 4,
                target: try #require(published.first)
            ),
        ])
        #expect(viewModel.selectedTarget == published.first?.reference)
        #expect(published.first?.kind == .local(installationID: "installation-1"))
    }

    @Test
    func incompatibleParametersAreDroppedAndReportedOnModelChange() async {
        let client = ModelCenterClientSpy(snapshot: .fixture)
        let viewModel = ModelCenterViewModel(client: client)
        await viewModel.reload()
        viewModel.targetDefaults = GenerationConfiguration()
            .setting(.samplingTemperature, to: .decimal(0.7))

        viewModel.selectModel(id: "cloud:profile:1:reasoning-model")

        #expect(viewModel.targetDefaults.parameters.isEmpty)
        #expect(viewModel.parameterNotice == "Temperature is not supported by this model.")
    }

    @Test
    func localActionsDelegateWithoutChangingGlobalRuntimeProvider() async throws {
        let client = ModelCenterClientSpy(snapshot: .fixture)
        let viewModel = ModelCenterViewModel(client: client)

        try await viewModel.pauseLocalModel(installationID: "installation-1")
        try await viewModel.resumeLocalModel(installationID: "installation-1")
        try await viewModel.cancelLocalModel(installationID: "installation-1")
        try await viewModel.deleteLocalModel(installationID: "installation-1")

        #expect(await client.localActions == [
            "pause:installation-1",
            "resume:installation-1",
            "cancel:installation-1",
            "delete:installation-1",
        ])
    }

    @Test
    func pendingLegacyProfileCanSelectAnExactReadyTargetAndMigrate() async throws {
        let client = ModelCenterClientSpy(snapshot: .fixture)
        let migration = LegacyMigrationPresentingSpy()
        let viewModel = ModelCenterViewModel(
            client: client,
            migration: migration,
            readinessIssues: ["migration.target_selection_required"]
        )
        await viewModel.reload()
        let item = try #require(viewModel.pendingMigrations.first)
        let target = try #require(viewModel.migrationTargets.first)
        viewModel.migrationTargetSelections[item.sourceDigest] =
            viewModel.migrationTargetKey(target)

        try await viewModel.migrate(item)

        #expect(await migration.selectedTarget == target.reference)
        #expect(!viewModel.readinessIssues.contains(
            "migration.target_selection_required"
        ))
    }

    @Test
    func incompatibleInstalledModelCannotBecomeATarget() async {
        let client = ModelCenterClientSpy(snapshot: .incompatibleFixture)
        let viewModel = ModelCenterViewModel(client: client)
        await viewModel.reload()

        await #expect(throws: Error.self) {
            try await viewModel.createTarget(modelID: "local:official-1:1")
        }
        #expect(viewModel.migrationTargets.isEmpty)
        #expect(await client.publishedTargets.isEmpty)
    }

    @Test
    func activeModelLabelIsRestoredFromDurablePrimaryBinding() async throws {
        let current = ModelCenterSnapshot.fixture
        let target = try #require(current.targets.first)
        let configuration = AgentHostConfiguration(
            bindingID: "binding.primary",
            revision: 2,
            agentProfileID: "agent-profile",
            agentProfileRevision: 4,
            llmSlotID: "primary",
            requirementsHash: "requirements",
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            fallbackGroupID: "group",
            fallbackPriority: 0,
            parameterOverrides: GenerationConfiguration()
        )
        let snapshot = ModelCenterSnapshot(
            localModels: current.localModels,
            cloudProviders: current.cloudProviders,
            cloudModels: current.cloudModels,
            targets: current.targets,
            activeBindings: [
                ActiveAgentHostBinding(
                    configuration: configuration,
                    binding: HostBindingTuple(
                        bindingID: configuration.bindingID,
                        bindingRevision: configuration.revision,
                        bindingHash: "binding-hash"
                    )
                ),
            ],
            disk: current.disk
        )
        let viewModel = ModelCenterViewModel(
            client: ModelCenterClientSpy(snapshot: snapshot)
        )

        await viewModel.reload()
        let restored = viewModel.syncActiveModel(for: ActiveAgentRevisionSelection(
            profileId: "agent-profile",
            profileRevisionId: 4,
            displayName: "Agent"
        ))

        #expect(restored?.displayName == "Official One")
        #expect(restored?.route == .localCpp(engineId: "installation-1"))
        #expect(restored?.readiness == .ready)
        #expect(viewModel.selectedTarget == target.reference)
        #expect(viewModel.selectedModelID == "local:official-1:1")
    }
}

private actor LegacyMigrationPresentingSpy: LegacyLLMMigrationPresenting {
    private(set) var selectedTarget: LLMTargetReference?

    func pendingItems() async throws -> [LegacyLLMMigrationItem] {
        [
            LegacyLLMMigrationItem(
                profileID: "legacy",
                revision: 1,
                sourceDigest: "legacy-digest",
                displayName: "Legacy Agent",
                redactedModelHint: "old-model"
            ),
        ]
    }

    func migrate(
        profileID: String,
        revision: UInt64,
        selectedTarget: LLMTargetReference?
    ) async throws -> LegacyProfileMigrationRecordDTO {
        self.selectedTarget = selectedTarget
        return LegacyProfileMigrationRecordDTO(
            sourceProfileId: profileID,
            sourceRevision: revision,
            sourceDigest: "legacy-digest",
            state: .archived
        )
    }
}

actor ModelCenterClientSpy: ModelCenterClient {
    nonisolated let updates = AsyncStream<Void> { _ in }

    private let storedSnapshot: ModelCenterSnapshot
    private(set) var publishedTargets: [LLMTargetRevision] = []
    private(set) var activatedTargets: [ActivatedModelTarget] = []
    private(set) var localActions: [String] = []

    init(snapshot: ModelCenterSnapshot) {
        storedSnapshot = snapshot
    }

    func snapshot() async throws -> ModelCenterSnapshot {
        storedSnapshot
    }

    func enqueueLocalModel(_ id: LocalModelRevisionID) async throws {
        localActions.append("enqueue:\(id.modelID):\(id.revision)")
    }

    func pauseLocalModel(installationID: String) async throws {
        localActions.append("pause:\(installationID)")
    }

    func resumeLocalModel(installationID: String) async throws {
        localActions.append("resume:\(installationID)")
    }

    func cancelLocalModel(installationID: String) async throws {
        localActions.append("cancel:\(installationID)")
    }

    func deleteLocalModel(installationID: String) async throws {
        localActions.append("delete:\(installationID)")
    }

    func publishProviderProfile(_ draft: ProviderProfileProductDraft) async throws {}

    func authenticateProviderOAuth(
        presetID: ProviderPresetID
    ) async throws -> SecretBytes {
        SecretBytes(utf8: "oauth-test-credential")
    }

    func refreshProviderOAuth(
        profileID: String,
        profileRevision: UInt64
    ) async throws {}

    func logoutProviderOAuth(
        profileID: String,
        profileRevision: UInt64
    ) async throws {}

    func rotateProviderCredential(
        profileID: String,
        profileRevision: UInt64,
        replacement: SecretBytes
    ) async throws {}

    func archiveProviderProfile(profileID: String) async throws {}

    func validateProviderModel(_ selection: CloudModelSelection) async throws {}

    func publishTarget(_ target: LLMTargetRevision) async throws {
        publishedTargets.append(target)
    }

    func activateTarget(
        _ target: LLMTargetRevision,
        forAgentProfileID profileID: String,
        revision: UInt64
    ) async throws {
        activatedTargets.append(ActivatedModelTarget(
            agentProfileID: profileID,
            agentProfileRevision: revision,
            target: target
        ))
    }
}

struct ActivatedModelTarget: Equatable, Sendable {
    let agentProfileID: String
    let agentProfileRevision: UInt64
    let target: LLMTargetRevision
}

extension ModelCenterSnapshot {
    static var incompatibleFixture: Self {
        let current = fixture
        let localModels = current.localModels.map { model in
            LocalModelCenterState(
                modelRevision: model.modelRevision,
                displayName: model.displayName,
                requiredBytes: model.requiredBytes,
                parameterSchema: model.parameterSchema,
                parameterDefaults: model.parameterDefaults,
                installation: model.installation.map {
                    LocalModelProductState(
                        installationID: $0.installationID,
                        modelRevision: $0.modelRevision,
                        state: $0.state,
                        receivedBytes: $0.receivedBytes,
                        expectedBytes: $0.expectedBytes,
                        installedBytes: $0.installedBytes,
                        requiredBytes: $0.requiredBytes,
                        repairAction: $0.repairAction,
                        catalogStatus: .incompatible
                    )
                }
            )
        }
        return Self(
            localModels: localModels,
            cloudProviders: [],
            cloudModels: [],
            targets: current.targets,
            activeBindings: current.activeBindings,
            disk: current.disk
        )
    }

    static var fixture: Self {
        let temperature = LLMParameterSchema(definitions: [
            .decimal(
                .samplingTemperature,
                support: .supported,
                minimum: 0,
                maximum: 2
            ),
        ])
        let reasoning = LLMParameterSchema(definitions: [
            .choice(
                .reasoningEffort,
                support: .supported,
                choices: ["low", "medium", "high"]
            ),
        ])
        return ModelCenterSnapshot(
            localModels: [
                LocalModelCenterState(
                    modelRevision: LocalModelRevisionID(
                        modelID: "official-1",
                        revision: 1
                    ),
                    displayName: "Official One",
                    requiredBytes: 1_024,
                    parameterSchema: temperature,
                    parameterDefaults: GenerationConfiguration(),
                    installation: LocalModelProductState(
                        installationID: "installation-1",
                        modelRevision: LocalModelRevisionID(
                            modelID: "official-1",
                            revision: 1
                        ),
                        state: .installed,
                        receivedBytes: 1_024,
                        expectedBytes: 1_024,
                        installedBytes: 1_024,
                        requiredBytes: 1_024,
                        repairAction: .delete
                    )
                ),
            ],
            cloudProviders: [
                CloudProviderProductState(
                    profileID: "profile",
                    revision: 1,
                    presetID: .openAI,
                    displayName: "OpenAI",
                    displayOrigin: "https://api.openai.com:443",
                    baseURL: URL(string: "https://api.openai.com:443")!,
                    retentionMode: .statelessRequired,
                    validation: .unvalidated,
                    hasStoredCredential: true
                ),
            ],
            cloudModels: [
                CloudModelProductState(
                    profileID: "profile",
                    profileRevision: 1,
                    modelID: "reasoning-model",
                    modelRevision: nil,
                    capabilities: CapabilitySnapshot(capabilities: [:]),
                    parameterSchema: reasoning,
                    validation: .unvalidated
                ),
            ],
            targets: [
                LLMTargetRevision(
                    targetID: LLMTargetID(rawValue: "target.fixture"),
                    revision: 1,
                    kind: .local(installationID: "installation-1"),
                    modelID: "official-1",
                    defaultParameters: GenerationConfiguration()
                ),
            ],
            activeBindings: [],
            disk: LocalDiskProductState(
                availableImportantUsageBytes: 10_000,
                reservedBytes: 0,
                installedBytes: 1_024
            )
        )
    }
}
