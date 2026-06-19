import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Rust runtime App integration")
struct RustRuntimeAppIntegrationTests {
    @Test("live RustRuntimeClient completes mock chat through App service")
    func liveRuntimeCompletesMockChat() async throws {
        let service = try makeLiveService()

        var state = try await service.prepare()
        state = try await service.sendMessage("hello", state: state)

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text).contains("hello"))
        #expect(state.messages.map(\.text).contains("Mock response to: hello"))
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
