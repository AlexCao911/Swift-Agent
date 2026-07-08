import Foundation
import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Rust runtime App integration")
struct RustRuntimeAppIntegrationTests {
    @Test("App bootstrapper defaults to local LLM when simulator config is present")
    func appBootstrapperDefaultsToLocalLLMWhenSimulatorConfigIsPresent() throws {
        let environment = [
            "LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON": #"{"backend":"llama_cpp","model_path":"/tmp/model.gguf"}"#,
        ]
        let providers = AppBootstrapper.simulatorProviders(environment: environment)

        #expect(AppBootstrapper.runtimeProviderId(environment: environment, providers: providers) == "local_llm")
        #expect(providers.count == 1)
        if case .localLLM(let model, _, let maxContextTokens) = providers[0] {
            #expect(model == "local.gguf.simulator")
            #expect(maxContextTokens == 2048)
        } else {
            Issue.record("Expected local_llm provider")
        }
    }

    @Test("simulator local LLM smoke through App bootstrapper")
    func simulatorLocalLLMSmokeThroughAppBootstrapper() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_AGENT_RUN_LOCAL_LLM_SMOKE"] == "1" else {
            return
        }

        let container = try AppBootstrapper.makeContainer(store: .inMemory)
        let service = container.runtimeService
        var state = try await service.prepare()
        #expect(state.provider.active?.id == "local_llm")

        state = try await service.sendMessage("Say hello in Chinese.", state: state)

        let assistantMessages = state.messages.filter { $0.role == .assistant }
        #expect(state.phase == .ready)
        #expect(!assistantMessages.isEmpty)
        #expect(!assistantMessages.contains(where: { $0.text.contains("Mock response") }))
    }

    @Test("live RustRuntimeClient completes mock chat through App service")
    func liveRuntimeCompletesMockChat() async throws {
        let service = try makeLiveService()

        var state = try await service.prepare()
        state = try await service.sendMessage("hello", state: state)

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text).contains("hello"))
        #expect(state.messages.map(\.text).contains("Mock response to: hello"))
    }

    @Test("App bootstrapper default store creates usable runtime")
    func appBootstrapperDefaultStoreCreatesUsableRuntime() async throws {
        let container = try AppBootstrapper.makeContainer(environment: [:])
        let service = container.runtimeService

        var state = try await service.prepare()
        state = try await service.sendMessage("hello", state: state)

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text).contains("Mock response to: hello"))
    }

    @Test("App bootstrapper default container exposes visible native tools")
    @MainActor
    func appBootstrapperDefaultContainerExposesVisibleNativeTools() async throws {
        let container = try AppBootstrapper.makeContainer(environment: [:])
        let viewModel = container.makeToolCenterViewModel()

        await viewModel.reload()

        let toolNames = viewModel.rows.map(\.name)
        #expect(toolNames.contains("native.list_tools"))
        #expect(toolNames.contains("native.permission_status"))
        #expect(toolNames.contains("web.fetch_url_text"))
        #expect(toolNames.contains("files.pick_document"))
        #expect(toolNames.contains("photos.pick_images"))
    }

    @Test("App bootstrapper recovers from unreadable persistent store")
    func appBootstrapperRecoversFromUnreadablePersistentStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalAgentBrokenStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sqliteURL = directory.appendingPathComponent("agent.sqlite")
        try Data("not a sqlite database".utf8).write(to: sqliteURL)

        let container = try AppBootstrapper.makeContainer(
            environment: [:],
            store: .sqlite(path: sqliteURL.path)
        )
        let service = container.runtimeService

        var state = try await service.prepare()
        state = try await service.sendMessage("hello", state: state)

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text).contains("Mock response to: hello"))
    }

    @Test("degraded bootstrap container keeps chat and tools usable")
    @MainActor
    func degradedBootstrapContainerKeepsChatAndToolsUsable() async throws {
        let container = try AppBootstrapper.makeDegradedContainer(
            error: RuntimeBridgeError(kind: "ffi", message: "failed to create runtime bridge")
        )
        let toolCenter = container.makeToolCenterViewModel()

        await toolCenter.reload()
        var state = try await container.runtimeService.prepare()
        state = try await container.runtimeService.sendMessage("hello", state: state)

        #expect(toolCenter.rows.contains { $0.name == "native.list_tools" })
        #expect(toolCenter.rows.contains { $0.name == "web.fetch_url_text" })
        #expect(state.phase == .ready)
        #expect(state.messages.contains { $0.role == .assistant })
    }

    @Test("App bootstrapper keeps legacy streaming path by default")
    func appBootstrapperKeepsLegacyStreamingPathByDefault() async throws {
        let container = try AppBootstrapper.makeContainer(environment: [:], store: .inMemory)

        let usesCoordinator = await container.runtimeService.usesConversationExecutionCoordinatorForTesting()
        #expect(!usesCoordinator)
    }

    @Test("App bootstrapper can wire conversation execution coordinator behind feature flag")
    func appBootstrapperCanWireConversationExecutionCoordinatorBehindFeatureFlag() async throws {
        let container = try AppBootstrapper.makeContainer(
            environment: ["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1"],
            store: .inMemory
        )

        let usesCoordinator = await container.runtimeService.usesConversationExecutionCoordinatorForTesting()
        #expect(usesCoordinator)
    }

    @Test("feature-flagged coordinator starts with seeded profile revision")
    func featureFlaggedCoordinatorStartsWithSeededProfileRevision() async throws {
        let container = try AppBootstrapper.makeContainer(
            environment: ["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1"],
            store: .inMemory
        )

        let service = container.runtimeService
        var state = try await service.prepare()
        state = try await service.sendMessage("hello", state: state)

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text).contains("hello"))
    }

    @Test("App container exposes Rust backed agent builder")
    @MainActor
    func appContainerExposesRustBackedAgentBuilder() async throws {
        let container = try AppBootstrapper.makeContainer(
            environment: ["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1"],
            store: .inMemory
        )
        let viewModel = container.makeAgentBuilderViewModel(
            profileId: "profile.builder.integration",
            templateId: "template_1"
        )

        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        #expect(viewModel.publishedProfileRevisionId == 1)
        #expect(viewModel.lifecycle == .published(profileRevisionId: 1))
    }

    @Test("container builder view model loads tool cards")
    @MainActor
    func containerBuilderViewModelLoadsToolCards() async throws {
        let container = try AppBootstrapper.makeContainer(
            environment: ["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1"],
            store: .inMemory
        )
        let viewModel = container.makeAgentBuilderViewModel()

        await viewModel.load()

        #expect(viewModel.draft != nil)
        #expect(!viewModel.toolCards.isEmpty)
    }

    @Test("container exposes user mediated picker tools")
    @MainActor
    func containerExposesUserMediatedPickerTools() async throws {
        let container = try AppBootstrapper.makeContainer(
            environment: ["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1"],
            store: .inMemory
        )
        let viewModel = container.makeAgentBuilderViewModel()

        await viewModel.load()
        let builderToolIds = viewModel.toolCards.map(\.id)
        #expect(builderToolIds.contains("files.pick_document"))
        #expect(builderToolIds.contains("photos.pick_images"))

        let snapshot = await container.nativeToolkitClient.registrationSnapshot()
        #expect(snapshot.toolNames.contains("files.pick_document"))
        #expect(snapshot.toolNames.contains("photos.pick_images"))

        try await assertPendingInteractionTool(
            container.nativeToolkitClient,
            toolName: "files.pick_document",
            toolCallId: "call_file_picker",
            interactionKind: "file_picker"
        )
        try await assertPendingInteractionTool(
            container.nativeToolkitClient,
            toolName: "photos.pick_images",
            toolCallId: "call_photo_picker",
            interactionKind: "photos_picker"
        )
    }

    @Test("live RustRuntimeClient completes debug echo tool loop")
    func liveRuntimeCompletesDebugEchoToolLoop() async throws {
        let service = try makeLiveService()

        var state = try await service.prepare()
        state = try await service.sendMessage("use tool debug.echo", state: state)

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text).contains("Echo: hello"))
        #expect(state.messages.map(\.text).contains("Mock response after tool: debug.echo: hello"))
    }

    private func makeLiveService() throws -> AgentRuntimeService {
        let client = try RustRuntimeClient(configuration: RustRuntimeConfiguration(
            systemPrompt: "You are Local Agent.",
            runtimePolicy: "Use registered tools when helpful.",
            providerId: "mock",
            store: .inMemory
        ))
        return AgentRuntimeService(
            runtimeClient: client,
            toolDriver: MinimalHostToolDriver()
        )
    }
}

private func decodedJSONObject(_ json: String) throws -> [String: Any] {
    let data = try #require(json.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func assertPendingInteractionTool(
    _ client: NativeToolkitClientProtocol,
    toolName: String,
    toolCallId: String,
    interactionKind: String
) async throws {
    let result = await client.execute(ToolExecutionRequestDTO(
        runId: "run_1",
        sessionId: "session_1",
        toolCallEntryId: "entry_1",
        toolCallId: toolCallId,
        toolName: toolName,
        argumentsJson: "{}"
    ))

    #expect(result.isError == false)
    let envelope = try decodedJSONObject(result.structuredJson)
    let resultPayload = try #require(envelope["result"] as? [String: Any])
    #expect(envelope["tool_call_id"] as? String == toolCallId)
    #expect(resultPayload["kind"] as? String == "pending_user_interaction")
    #expect(resultPayload["interaction_kind"] as? String == interactionKind)
}
