import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Agent builder bridge client")
struct AgentBuilderClientTests {
    @Test("portable builder sends requirements without Swift target details")
    func portableBuilderSendsOnlyRustOwnedDraftAndRequirements() async throws {
        let gateway = RecordingBuilderGateway()
        let client = RustPortableAgentBuilderClient(gateway: gateway)
        let request = BuildAgentV2RequestDTO(
            operationId: "publish.profile.portable.1",
            draft: AgentBuilderDraftDTO(
                profileId: "profile.portable",
                templateId: "template.assistant.default",
                displayName: "Portable"
            ),
            requirements: AgentLLMRequirementsDTO(
                slotId: "slot.model.primary",
                contextBudget: "16384",
                streamingRequired: true,
                toolCallingMode: "allowed"
            )
        )

        let pending = try await client.buildPendingProfile(request)

        #expect(pending.profileId == "profile.portable")
        #expect(gateway.operations == [.buildAgentV2])
        let payload = try #require(gateway.payloads.first)
        for forbidden in [
            "target_id", "provider", "model_id", "api_key", "base_url",
            "installation_id", "parameter_overrides",
        ] {
            #expect(payload.range(of: "\"\(forbidden)\"") == nil)
        }
    }

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

    @Test("publish profile forwards card backed draft fields")
    func publishProfileForwardsCardBackedDraftFields() async throws {
        let bridge = RecordingExecutionBridgeClient()
        let client = RustAgentBuilderClient(execution: bridge)

        _ = try await client.publishProfile(AgentBuilderDraftDTO(
            profileId: "profile.draft.local",
            templateId: "template.assistant.default",
            displayName: "Research Agent",
            systemPrompt: "You are careful.",
            persona: "Researcher",
            responseStyle: "Concise",
            selectedToolIds: ["calendar.search_events", "web.fetch_url_text"],
            contextStepIds: ["system_prompt", "conversation_history", "tool_results"]
        ))

        #expect(bridge.builtRequests == [
            BuildAgentRequestDTO(
                profileId: "profile.draft.local",
                templateId: "template.assistant.default",
                displayName: "Research Agent",
                systemPrompt: "You are careful.",
                persona: "Researcher",
                responseStyle: "Concise",
                selectedToolIds: ["calendar.search_events", "web.fetch_url_text"],
                contextStepIds: ["system_prompt", "conversation_history", "tool_results"]
            ),
        ])
    }

    @Test("preview context forwards draft to execution bridge")
    func previewContextForwardsDraftToExecutionBridge() async throws {
        let bridge = RecordingExecutionBridgeClient()
        let client = RustAgentBuilderClient(execution: bridge)
        let request = BuilderContextPreviewRequestDTO(
            draft: AgentBuilderDraftDTO(
                profileId: "profile.draft.local",
                templateId: "template.assistant.default",
                systemPrompt: "You are careful.",
                selectedToolIds: ["web.fetch_url_text"],
                contextStepIds: ["system_prompt"]
            ),
            sampleUserMessage: "Hello"
        )

        let preview = try await client.previewContext(request)

        #expect(bridge.previewRequests == [request])
        #expect(preview.segments.map(\.id) == ["system_prompt"])
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

private final class RecordingBuilderGateway: RustAgentOSBridgeGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var storedOperations: [RustAgentOSOperation] = []
    private var storedPayloads: [String] = []

    var operations: [RustAgentOSOperation] {
        lock.withLock { storedOperations }
    }

    var payloads: [String] {
        lock.withLock { storedPayloads }
    }

    func request<Request, Response>(
        _ operation: RustAgentOSOperation,
        _ request: Request,
        as response: Response.Type
    ) async throws -> Response where Request: Encodable, Response: Decodable {
        let data = try JSONEncoder().encode(request)
        lock.withLock {
            storedOperations.append(operation)
            storedPayloads.append(String(decoding: data, as: UTF8.self))
        }
        let value: any Encodable = switch operation {
        case .buildAgentV2:
            PendingAgentProfileDTO(
                profileId: "profile.portable",
                profileRevisionId: 1,
                displayName: "Portable",
                llmSlotId: "slot.model.primary",
                requirementsHash: "requirements-hash"
            )
        default:
            throw AgentBuilderClientTestError.unimplemented
        }
        let encoded = try JSONEncoder().encode(AnyEncodable(value))
        return try JSONDecoder().decode(Response.self, from: encoded)
    }

    func stream<Request>(
        _ operation: RustAgentOSOperation,
        _ request: Request
    ) -> AsyncThrowingStream<RuntimeEventDTO, Error> where Request: Encodable {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private final class RecordingExecutionBridgeClient: ExecutionBridgeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBuiltRequests: [BuildAgentRequestDTO] = []
    private var storedPreviewRequests: [BuilderContextPreviewRequestDTO] = []

    var builtRequests: [BuildAgentRequestDTO] {
        lock.withLock { storedBuiltRequests }
    }

    var previewRequests: [BuilderContextPreviewRequestDTO] {
        lock.withLock { storedPreviewRequests }
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

    func previewContext(_ request: BuilderContextPreviewRequestDTO) async throws -> BuilderContextPreviewResponseDTO {
        lock.withLock {
            storedPreviewRequests.append(request)
        }
        return BuilderContextPreviewResponseDTO(
            isPreviewOnly: false,
            segments: [
                BuilderContextPreviewSegmentDTO(
                    id: "system_prompt",
                    title: "System Prompt",
                    sourceLabel: "prompt",
                    trustLevel: "trusted_app_policy",
                    isEnabled: true,
                    previewText: request.draft.systemPrompt ?? ""
                ),
            ],
            tokenEstimate: 4,
            warnings: []
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

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
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
