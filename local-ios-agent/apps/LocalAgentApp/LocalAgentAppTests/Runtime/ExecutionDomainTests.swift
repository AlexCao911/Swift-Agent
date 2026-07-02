import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Execution domain")
struct ExecutionDomainTests {
    @Test("adapter delegates run lifecycle through focused services")
    func adapterDelegatesRunLifecycleThroughFocusedServices() async throws {
        let event = RuntimeEventDTO(
            id: "event_5",
            sessionId: "session_1",
            parentId: nil,
            runId: "run_mock",
            sequence: 5,
            depth: 0,
            kind: .unknown(raw: "execution.event"),
            payload: "run.completed",
            blobRefs: []
        )
        let bridge = MockRuntimeClient(
            agentProfiles: [
                AgentProfileDTO(profileId: "profile_1", displayName: "Planner"),
            ],
            executionEventsByRunId: ["run_mock": [event]]
        )
        let domain = ExecutionDomainAdapter(
            profiles: AgentProfileService(bridge: bridge),
            composition: AgentCompositionService(bridge: bridge),
            lifecycle: RunLifecycleService(bridge: bridge),
            events: RunEventStreamService(bridge: bridge),
            tools: ToolApprovalService(bridge: bridge),
            debug: RunDebugService(bridge: bridge),
            inference: InferenceSettingsService(bridge: bridge)
        )
        let frameRef = ConversationRunFrameRefDTO(
            frameId: "frame_1",
            sessionId: "session_1",
            branchHeadId: "entry_user",
            userTurnId: "entry_user"
        )

        let profiles = try await domain.listAgentProfiles()
        let built = try await domain.buildAgent(templateId: "template_1")
        let handle = try await domain.startRun(StartExecutionRequestDTO(
            agentProfileId: "profile_1",
            userIntent: "continue",
            conversationRunFrameRef: frameRef
        ))
        var observed: [RuntimeEventDTO] = []
        for try await event in domain.observeEvents(runId: "run_mock", fromSequence: 4) {
            observed.append(event)
        }
        try await domain.approveTool(
            id: "approval_1",
            decision: ApprovalDecisionDTO(approved: true)
        )
        let cancelled = try await domain.cancelRun(runId: "run_mock")
        try await domain.updateRuntimeOptions(RuntimeOptionsDTO(
            systemPrompt: "system",
            runtimePolicy: "policy",
            temperature: 0.2,
            topP: 0.9
        ))

        #expect(profiles.map(\.profileId) == ["profile_1"])
        #expect(built.profileId == "profile_1")
        #expect(handle.runId == "run_mock")
        #expect(observed == [event])
        #expect(cancelled.kind == .runCancelled)
        #expect(await bridge.builtAgentTemplateIds == ["template_1"])
        #expect(await bridge.startedExecutionRequests.count == 1)
        #expect(await bridge.approvedTools.count == 1)
        #expect(await bridge.updatedRuntimeOptions.count == 1)
    }
}
