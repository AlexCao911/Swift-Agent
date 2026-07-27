import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Legacy profile migration bridge")
struct LegacyProfileMigrationClientTests {
    @Test("action inventory uses the dedicated read-only operation")
    func actionInventoryOperation() async throws {
        let gateway = MigrationActionGateway()
        let client = RustLegacyProfileMigrationClient(gateway: gateway)

        let actions = try await client.actions()

        #expect(actions.first?.migrationSubject == "legacy:1")
        #expect(gateway.operations == [.listLegacyProfileMigrationActions])
    }

    @Test("begin request and action remain provider neutral")
    func portableMigrationProjection() throws {
        let request = BeginLegacyProfileMigrationDTO(
            attemptId: "attempt-1",
            profileId: "legacy",
            profileRevision: 1
        )
        let requestJSON = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        for forbidden in [
            "target_id", "provider", "credential", "base_url",
            "local_path", "engine_id", "parameter_overrides",
        ] {
            #expect(!requestJSON.contains(forbidden))
        }

        let action = try JSONDecoder().decode(
            LegacyMigrationActionDTO.self,
            from: Data(
                """
                {
                  "migration_subject":"legacy:1",
                  "source_digest":"opaque-source-digest",
                  "display_name":"Legacy",
                  "requirements":{
                    "slot_id":"slot.model.primary",
                    "capabilities":[],
                    "input_modalities":["text"],
                    "context_budget":"4096",
                    "streaming_required":true,
                    "tool_calling_mode":"allowed"
                  },
                  "redacted_model_hint":"gpt-4.1",
                  "state":"pending",
                  "successor":{
                    "profile_id":"legacy",
                    "profile_revision":2,
                    "llm_slot_id":"slot.model.primary",
                    "requirements_hash":"requirements-hash",
                    "host_binding_operation_id":"operation-1"
                  }
                }
                """.utf8
            )
        )

        #expect(action.successor?.profileRevision == 2)
        #expect(action.redactedModelHint == "gpt-4.1")
    }
}

private final class MigrationActionGateway: RustAgentOSBridgeGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOperations: [RustAgentOSOperation] = []

    var operations: [RustAgentOSOperation] {
        lock.withLock { recordedOperations }
    }

    func request<Request: Encodable, Response: Decodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request,
        as response: Response.Type
    ) async throws -> Response {
        lock.withLock {
            recordedOperations.append(operation)
        }
        return try JSONDecoder().decode(
            Response.self,
            from: Data(
                """
                [{
                  "migration_subject":"legacy:1",
                  "source_digest":"opaque-source-digest",
                  "display_name":"Legacy",
                  "requirements":{
                    "slot_id":"slot.model.primary",
                    "capabilities":[],
                    "input_modalities":["text"],
                    "context_budget":"4096",
                    "streaming_required":true,
                    "tool_calling_mode":"allowed"
                  },
                  "state":"pending"
                }]
                """.utf8
            )
        )
    }

    func stream<Request: Encodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request
    ) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
