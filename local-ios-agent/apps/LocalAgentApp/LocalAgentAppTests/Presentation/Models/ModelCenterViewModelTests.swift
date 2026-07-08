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
    func selectingReadyModelUpdatesShellActiveModel() async {
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

        await viewModel.select(rowId: "mock", shell: shell)

        #expect(shell.activeModel == ActiveModelSummary(
            providerId: "mock",
            modelId: "mock",
            displayName: "Mock",
            route: .cloud(providerId: "mock"),
            readiness: .ready
        ))
        #expect(viewModel.rows.first?.isActive == true)
    }

    @Test("reload loads runtime providers and active model")
    func reloadLoadsRuntimeProvidersAndActiveModel() async throws {
        let client = RecordingModelRoutingClient(
            profiles: [
                profile(id: "mock", displayName: "Mock", kind: .mock),
                profile(id: "local_llm", displayName: "Local LLM", kind: .localLLM),
            ],
            activeProvider: profile(id: "local_llm", displayName: "Local LLM", kind: .localLLM)
        )
        let viewModel = ModelCenterViewModel(routingClient: client)
        let shell = AppShellViewModel(
            readinessBanners: [
                GlobalReadinessBanner(
                    id: "missing_model",
                    kind: .missingModel,
                    title: "Choose a model",
                    message: "Select a ready local or cloud model before starting a run.",
                    route: .models
                ),
            ]
        )

        await viewModel.reload(shell: shell)

        #expect(viewModel.activeModel == ActiveModelSummary(
            providerId: "local_llm",
            modelId: "local_llm",
            displayName: "Local LLM",
            route: .localCpp(engineId: "local_llm"),
            readiness: .ready
        ))
        #expect(viewModel.rows.map(\.id) == ["local_llm", "mock"])
        #expect(viewModel.rows.first(where: { $0.id == "local_llm" })?.isActive == true)
        #expect(viewModel.rows.first(where: { $0.id == "local_llm" })?.readiness == .ready)
        #expect(shell.activeModel?.providerId == "local_llm")
        #expect(shell.readinessBanners.isEmpty)
    }

    @Test("selecting runtime model updates runtime provider and shell")
    func selectingRuntimeModelUpdatesRuntimeProviderAndShell() async throws {
        let client = RecordingModelRoutingClient(
            profiles: [
                profile(id: "mock", displayName: "Mock", kind: .mock),
                profile(id: "local_llm", displayName: "Local LLM", kind: .localLLM),
            ],
            activeProvider: profile(id: "mock", displayName: "Mock", kind: .mock)
        )
        let shell = AppShellViewModel()
        let viewModel = ModelCenterViewModel(routingClient: client)
        await viewModel.reload()

        await viewModel.select(rowId: "local_llm", shell: shell)

        #expect(await client.selectedProviderIds == ["local_llm"])
        #expect(shell.activeModel?.providerId == "local_llm")
        #expect(viewModel.rows.first(where: { $0.id == "local_llm" })?.isActive == true)
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

private actor RecordingModelRoutingClient: ModelRoutingClient {
    private let profiles: [ProviderProfileDTO]
    private var active: ProviderProfileDTO
    private(set) var selectedProviderIds: [String] = []

    init(profiles: [ProviderProfileDTO], activeProvider: ProviderProfileDTO) {
        self.profiles = profiles
        self.active = activeProvider
    }

    func providerProfiles() async throws -> [ProviderProfileDTO] {
        profiles
    }

    func activeProvider() async throws -> ProviderProfileDTO {
        active
    }

    func selectProvider(_ providerId: String) async throws {
        selectedProviderIds.append(providerId)
        if let profile = profiles.first(where: { $0.id == providerId }) {
            active = profile
        }
    }
}
