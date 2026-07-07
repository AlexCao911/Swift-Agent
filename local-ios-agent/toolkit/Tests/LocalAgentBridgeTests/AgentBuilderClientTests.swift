import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Agent builder bridge client")
struct AgentBuilderClientTests {
    @Test("publish profile uses draft template id through execution bridge")
    func publishProfileUsesDraftTemplateId() async throws {
        let bridge = RecordingExecutionBridgeClient()
        let client = RustAgentBuilderClient(execution: bridge)

        let profile = try await client.publishProfile(AgentBuilderDraftDTO(
            profileId: "profile.draft.local",
            templateId: "template.assistant.default"
        ))

        #expect(bridge.builtRequests == [
            BuildAgentRequestDTO(
                profileId: "profile.draft.local",
                templateId: "template.assistant.default"
            ),
        ])
        #expect(profile.profileId == "profile.draft.local")
        #expect(profile.profileRevisionId == 1)
    }

    @Test("validate draft reports unsupported template")
    func validateDraftReportsUnsupportedTemplate() async throws {
        let bridge = RecordingExecutionBridgeClient()
        let client = RustAgentBuilderClient(execution: bridge)

        let readiness = try await client.validateDraft(AgentBuilderDraftDTO(
            profileId: "profile.draft.local",
            templateId: "template.unknown"
        ))

        #expect(readiness.issues.map(\.code) == ["agent_builder.template_unsupported"])
    }
}

private final class RecordingExecutionBridgeClient: ExecutionBridgeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBuiltRequests: [BuildAgentRequestDTO] = []

    var builtRequests: [BuildAgentRequestDTO] {
        lock.withLock { storedBuiltRequests }
    }

    func listAgentProfiles() async throws -> [AgentProfileDTO] {
        []
    }

    func buildAgent(_ request: BuildAgentRequestDTO) async throws -> AgentProfileDTO {
        lock.withLock {
            storedBuiltRequests.append(request)
        }
        return AgentProfileDTO(
            profileId: request.profileId ?? "profile.from_template.\(request.templateId)",
            profileRevisionId: 1,
            displayName: "Assistant"
        )
    }

    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        throw AgentBuilderClientTestError.unimplemented
    }

    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {}

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        throw AgentBuilderClientTestError.unimplemented
    }

    func cancelRun(runId: String) async throws -> RuntimeEventDTO {
        throw AgentBuilderClientTestError.unimplemented
    }

    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        throw AgentBuilderClientTestError.unimplemented
    }

    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {}
}

private enum AgentBuilderClientTestError: Error {
    case unimplemented
}
