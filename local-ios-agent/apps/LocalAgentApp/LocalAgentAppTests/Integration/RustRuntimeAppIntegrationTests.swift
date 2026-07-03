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
