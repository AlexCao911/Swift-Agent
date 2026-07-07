import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Model Center view model")
@MainActor
struct ModelCenterViewModelTests {
    @Test("no selected model creates missing model banner")
    func noSelectedModelCreatesMissingModelBanner() {
        let viewModel = ModelCenterViewModel()

        #expect(viewModel.missingModelBanner() == GlobalReadinessBanner(
            id: "missing_model",
            kind: .missingModel,
            title: "Choose a model",
            message: "Select a ready local or cloud model before starting a run.",
            route: .models
        ))
    }

    @Test("local model without downloaded weights is not ready")
    func localModelWithoutDownloadedWeightsIsNotReady() {
        let rows = ModelCenterProjection.project(
            profiles: [profile(id: "local_llm", displayName: "Local LLM", kind: .localLLM)],
            localModelAvailability: ["local_llm": false]
        )

        #expect(rows.first == ModelCenterRowState(
            id: "local_llm",
            displayName: "Local LLM",
            route: .localCpp(engineId: "local_llm"),
            readiness: .missingConfiguration(reason: "weights_missing"),
            isActive: false
        ))
    }

    @Test("cloud model without api key is not ready")
    func cloudModelWithoutAPIKeyIsNotReady() {
        let rows = ModelCenterProjection.project(
            profiles: [profile(id: "openai", displayName: "OpenAI", kind: .openAiCompatibleLocal)],
            cloudCredentialAvailability: ["openai": false]
        )

        #expect(rows.first?.route == .cloud(providerId: "openai"))
        #expect(rows.first?.readiness == .missingConfiguration(reason: "api_key_missing"))
    }

    @Test("selecting ready model updates shell active model")
    func selectingReadyModelUpdatesShellActiveModel() {
        let shell = AppShellViewModel()
        let viewModel = ModelCenterViewModel(
            rows: [
                ModelCenterRowState(
                    id: "mock",
                    displayName: "Mock",
                    route: .cloud(providerId: "mock"),
                    readiness: .ready,
                    isActive: false
                ),
            ]
        )

        viewModel.select(rowId: "mock", shell: shell)

        #expect(shell.activeModel == ActiveModelSummary(
            providerId: "mock",
            modelId: "mock",
            displayName: "Mock",
            route: .cloud(providerId: "mock"),
            readiness: .ready
        ))
        #expect(viewModel.rows.first?.isActive == true)
    }
}

private func profile(
    id: String,
    displayName: String,
    kind: ProviderKindDTO
) -> ProviderProfileDTO {
    ProviderProfileDTO(
        id: id,
        displayName: displayName,
        kind: kind,
        maxContextTokens: 4096
    )
}
