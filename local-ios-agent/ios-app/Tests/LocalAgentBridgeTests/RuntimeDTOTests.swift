import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Runtime DTOs")
struct RuntimeDTOTests {
    @Test
    func decodesRustTurnResultJSONIntoSwiftDTOs() throws {
        let json = """
        {
          "run_id": "run_7",
          "state": "waiting_tool",
          "pending_tool_call_id": "call_1",
          "events": [
            {
              "id": "entry_1",
              "session_id": "session_1",
              "parent_id": null,
              "run_id": "run_7",
              "sequence": 3,
              "depth": 2,
              "kind": "assistant_text_delta",
              "payload": "hello",
              "blob_refs": ["blob_1"]
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(AgentTurnResultDTO.self, from: json)

        #expect(result.runId == "run_7")
        #expect(result.state == .waitingTool)
        #expect(result.pendingToolCallId == "call_1")
        #expect(result.events.count == 1)
        #expect(result.events[0].id == "entry_1")
        #expect(result.events[0].sessionId == "session_1")
        #expect(result.events[0].parentId == nil)
        #expect(result.events[0].runId == "run_7")
        #expect(result.events[0].sequence == 3)
        #expect(result.events[0].depth == 2)
        #expect(result.events[0].kind == .assistantTextDelta)
        #expect(result.events[0].payload == "hello")
        #expect(result.events[0].blobRefs == ["blob_1"])
    }

    @Test
    func decodesRustToolAndApprovalJSONIntoSwiftDTOs() throws {
        let toolJSON = """
        {
          "run_id": "run_7",
          "session_id": "session_1",
          "tool_call_entry_id": "entry_tool",
          "tool_call_id": "call_1",
          "tool_name": "debug.echo",
          "arguments_json": "{\\"text\\":\\"hello\\"}"
        }
        """.data(using: .utf8)!

        let approvalJSON = """
        {
          "approval_id": "approval_entry_tool",
          "run_id": "run_7",
          "tool_call_entry_id": "entry_tool",
          "message": "Allow tool `debug.echo` to run?",
          "requires_local_authentication": true
        }
        """.data(using: .utf8)!

        let promptJSON = """
        {
          "rendered_text": "system\\nruntime\\ntool"
        }
        """.data(using: .utf8)!

        let tool = try JSONDecoder().decode(ToolExecutionRequestDTO.self, from: toolJSON)
        let approval = try JSONDecoder().decode(ApprovalProtocolRequestDTO.self, from: approvalJSON)
        let prompt = try JSONDecoder().decode(PromptDebugSnapshotDTO.self, from: promptJSON)

        #expect(tool.runId == "run_7")
        #expect(tool.sessionId == "session_1")
        #expect(tool.toolCallEntryId == "entry_tool")
        #expect(tool.toolCallId == "call_1")
        #expect(tool.toolName == "debug.echo")
        #expect(tool.argumentsJson == #"{"text":"hello"}"#)
        #expect(approval.approvalId == "approval_entry_tool")
        #expect(approval.runId == "run_7")
        #expect(approval.toolCallEntryId == "entry_tool")
        #expect(approval.message == "Allow tool `debug.echo` to run?")
        #expect(approval.requiresLocalAuthentication)
        #expect(prompt.renderedText == "system\nruntime\ntool")
    }

    @Test
    func encodesToolResultInRustExpectedShape() throws {
        let result = ToolResultDTO(
            displayText: "Shown to user",
            modelText: "Shown to model",
            structuredJson: #"{"ok":true}"#,
            auditText: "audit row",
            sensitivity: .private,
            retention: .session,
            isError: false
        )

        let encoded = try JSONEncoder().encode(result)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(object?["display_text"] as? String == "Shown to user")
        #expect(object?["model_text"] as? String == "Shown to model")
        #expect(object?["structured_json"] as? String == #"{"ok":true}"#)
        #expect(object?["audit_text"] as? String == "audit row")
        #expect(object?["sensitivity"] as? String == "private")
        #expect(object?["retention"] as? String == "session")
        #expect(object?["is_error"] as? Bool == false)
    }

    @Test
    func encodesToolSchemaAndApprovalResponseInRustExpectedShape() throws {
        let schema = ToolSchemaDTO(
            name: "debug.echo",
            description: "Echoes text",
            parametersJsonSchema: #"{"type":"object"}"#,
            riskLevel: .readOnly
        )
        let approval = ApprovalProtocolResponseDTO(
            approvalId: "approval_1",
            approved: true,
            reason: nil
        )

        let schemaObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any]
        let approvalObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(approval)) as? [String: Any]

        #expect(schemaObject?["name"] as? String == "debug.echo")
        #expect(schemaObject?["description"] as? String == "Echoes text")
        #expect(schemaObject?["parameters_json_schema"] as? String == #"{"type":"object"}"#)
        #expect(schemaObject?["risk_level"] as? String == "read_only")
        #expect(approvalObject?["approval_id"] as? String == "approval_1")
        #expect(approvalObject?["approved"] as? Bool == true)
        #expect(approvalObject?.keys.contains("reason") == true)
        #expect(approvalObject?["reason"] is NSNull)
    }
}
