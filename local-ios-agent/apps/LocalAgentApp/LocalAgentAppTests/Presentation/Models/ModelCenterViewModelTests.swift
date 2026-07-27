import Foundation
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

        try await viewModel.createTarget(modelID: "local:official-1:1")

        let published = await client.publishedTargets
        #expect(published.count == 1)
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
}

actor ModelCenterClientSpy: ModelCenterClient {
    nonisolated let updates = AsyncStream<Void> { _ in }

    private let storedSnapshot: ModelCenterSnapshot
    private(set) var publishedTargets: [LLMTargetRevision] = []
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
}

extension ModelCenterSnapshot {
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
            targets: [],
            disk: LocalDiskProductState(
                availableImportantUsageBytes: 10_000,
                reservedBytes: 0,
                installedBytes: 1_024
            )
        )
    }
}
