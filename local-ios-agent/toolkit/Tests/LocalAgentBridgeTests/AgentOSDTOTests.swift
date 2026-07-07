import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Agent OS bridge DTOs")
struct AgentOSDTOTests {
    @Test("StartExecutionRequestDTO encodes only ConversationRunFrameRef as trusted execution input")
    func startExecutionRequestEncodesConversationRunFrameRefOnly() throws {
        let request = StartExecutionRequestDTO(
            agentProfileId: "profile_1",
            profileRevisionId: 1,
            userIntent: "answer the user",
            conversationRunFrameRef: ConversationRunFrameRefDTO(
                frameId: "frame_1",
                sessionId: "session_1",
                branchHeadId: "branch_head_1",
                userTurnId: "user_turn_1"
            ),
            options: ExecutionOptionsDTO()
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["conversation_run_frame_ref"] != nil)
        #expect(object["conversation_run_frame"] == nil)
    }

    @Test("RunHandleDTO decodes replay_from_sequence")
    func runHandleDecodesReplayFromSequence() throws {
        let json = """
        {
          "run_id": "run_1",
          "replay_from_sequence": 0
        }
        """.data(using: .utf8)!

        let handle = try JSONDecoder().decode(RunHandleDTO.self, from: json)

        #expect(handle.runId == "run_1")
        #expect(handle.replayFromSequence == 0)
    }

    @Test("StartRunRequestDTO does not encode trusted host state")
    func startRunRequestDoesNotEncodeTrustedHostState() throws {
        let dto = StartRunRequestDTO(agentProfileId: "profile_1", userIntent: "hello")
        let data = try JSONEncoder().encode(dto)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("agent_profile_id"))
        #expect(json.contains("user_intent"))
        #expect(!json.contains("permission_state"))
        #expect(!json.contains("local_bindings"))
        #expect(!json.contains("credential_availability"))
    }

    @Test("BuildAgentRequestDTO omits empty card-backed fields")
    func buildAgentRequestOmitsEmptyCardBackedFields() throws {
        let data = try JSONEncoder().encode(BuildAgentRequestDTO(
            profileId: "profile_1",
            templateId: "template_1"
        ))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["profile_id"] as? String == "profile_1")
        #expect(object["template_id"] as? String == "template_1")
        #expect(object["selected_tool_ids"] == nil)
        #expect(object["context_step_ids"] == nil)
    }

    @Test("BuildAgentRequestDTO encodes non-empty card-backed fields")
    func buildAgentRequestEncodesNonEmptyCardBackedFields() throws {
        let data = try JSONEncoder().encode(BuildAgentRequestDTO(
            profileId: "profile_1",
            templateId: "template_1",
            displayName: "Research Agent",
            systemPrompt: "Be careful.",
            persona: "Researcher",
            responseStyle: "Concise",
            selectedToolIds: ["web.fetch_url_text"],
            contextStepIds: ["system_prompt"]
        ))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["display_name"] as? String == "Research Agent")
        #expect(object["system_prompt"] as? String == "Be careful.")
        #expect(object["persona"] as? String == "Researcher")
        #expect(object["response_style"] as? String == "Concise")
        #expect(object["selected_tool_ids"] as? [String] == ["web.fetch_url_text"])
        #expect(object["context_step_ids"] as? [String] == ["system_prompt"])
    }

    @Test("BuildAgentRequestDTO decodes legacy template-backed request")
    func buildAgentRequestDecodesLegacyTemplateBackedRequest() throws {
        let json = """
        {
          "profile_id": "profile_1",
          "template_id": "template_1"
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(BuildAgentRequestDTO.self, from: json)

        #expect(request.profileId == "profile_1")
        #expect(request.templateId == "template_1")
        #expect(request.selectedToolIds.isEmpty)
        #expect(request.contextStepIds.isEmpty)
    }

    @Test("AgentBuilderDraftDTO decodes legacy template-backed draft")
    func agentBuilderDraftDecodesLegacyTemplateBackedDraft() throws {
        let json = """
        {
          "profile_id": "profile_1"
        }
        """.data(using: .utf8)!

        let draft = try JSONDecoder().decode(AgentBuilderDraftDTO.self, from: json)

        #expect(draft.profileId == "profile_1")
        #expect(draft.templateId == "template_1")
        #expect(draft.selectedToolIds.isEmpty)
        #expect(draft.contextStepIds.isEmpty)
    }

    @Test("package preview snapshot and permission clients return UI models")
    func packageSnapshotAndPermissionClientsReturnUIModels() async throws {
        let packageClient = MockAgentPackageClient.previewing(profileName: "Research Assistant")
        let snapshotClient = MockRunSnapshotClient.ready(profileId: "profile_1")
        let permissionClient = MockPermissionClient(issues: [
            PermissionIssueDTO(code: "permission.calendar.missing", message: "Calendar access is off"),
            PermissionIssueDTO(code: "credential.openai.missing", message: "OpenAI key is missing"),
        ])

        let preview = try await packageClient.previewInstall(URL(fileURLWithPath: "/tmp/my-agent"))
        let readiness = try await snapshotClient.readiness("profile_1")
        let permissions = try await permissionClient.readiness([])

        #expect(preview.profileName == "Research Assistant")
        #expect(preview.operations.map(\.code).contains("profile.create"))
        #expect(readiness.profileId == "profile_1")
        #expect(readiness.isReady)
        #expect(permissions.issues.count == 2)
    }

    @Test("runtime client startRun records request without trusted state")
    func runtimeClientStartRunRecordsRequestWithoutTrustedState() async throws {
        let client = MockRuntimeClient()
        let request = StartRunRequestDTO(agentProfileId: "profile_1", userIntent: "research this")

        let handle = try await client.startRun(request)

        #expect(handle.runId == "run_mock")
        #expect(await client.startedRunRequests == [request])
    }

    @Test("debug archive UI model decodes runtime trace payload")
    func debugArchiveUIModelDecodesRuntimeTracePayload() throws {
        let json = """
        {
          "run_id": "run_1",
          "state": "awaiting_approval",
          "events": [
            { "id": "event_1", "code": "run.started", "title": "Run started" },
            { "id": "event_2", "code": "approval.required", "title": "Approval required" }
          ],
          "archives": [
            {
              "id": "archive_1",
              "kind": "prompt",
              "title": "Prompt archive",
              "redacted_payload": "system prompt",
              "source_links": [
                { "kind": "prompt_archive", "target_id": "prompt_archive:run_1" }
              ]
            },
            {
              "id": "archive_2",
              "kind": "context",
              "title": "Context archive",
              "redacted_payload": "context payload",
              "source_links": []
            }
          ],
          "checkpoints": [
            { "id": "checkpoint_1", "title": "Before approval", "can_resume": true }
          ]
        }
        """.data(using: .utf8)!

        let archive = try JSONDecoder().decode(RunDebugUIModel.self, from: json)

        #expect(archive.runId == "run_1")
        #expect(archive.state == .awaitingApproval)
        #expect(archive.events.map(\.code) == ["run.started", "approval.required"])
        #expect(archive.archives.map(\.kind.rawValue) == ["prompt", "context"])
        #expect(archive.archives.first?.redactedPayload == "system prompt")
        #expect(archive.archives.first?.sourceLinks.first?.kind == .promptArchive)
        #expect(archive.checkpoints.first?.canResume == true)
    }
}
