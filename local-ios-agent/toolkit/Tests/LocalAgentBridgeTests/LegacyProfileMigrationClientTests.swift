import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Legacy profile migration bridge")
struct LegacyProfileMigrationClientTests {
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
