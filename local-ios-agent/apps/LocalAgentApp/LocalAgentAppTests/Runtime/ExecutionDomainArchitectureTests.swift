import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Execution domain architecture")
struct ExecutionDomainArchitectureTests {
    @Test("adapter is composed from focused services")
    func adapterUsesFocusedServices() {
        let bridge = MockRuntimeClient()
        let adapter = ExecutionDomainAdapter(
            profiles: AgentProfileService(bridge: bridge),
            composition: AgentCompositionService(bridge: bridge),
            lifecycle: RunLifecycleService(bridge: bridge),
            events: RunEventStreamService(bridge: bridge),
            tools: ToolApprovalService(bridge: bridge),
            debug: RunDebugService(bridge: bridge),
            inference: InferenceSettingsService(bridge: bridge)
        )
        let domain: any ExecutionDomain = adapter

        #expect(domain is ExecutionDomainAdapter)
    }
}
