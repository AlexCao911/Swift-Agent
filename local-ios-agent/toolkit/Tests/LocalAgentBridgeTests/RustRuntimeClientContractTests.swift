import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Rust runtime client contracts")
struct RustRuntimeClientContractTests {
    @Test
    func runtimeConfigurationContainsOnlyHostOwnedFields() throws {
        let configuration = RustRuntimeConfiguration(
            hostProcessEpoch: try testHostProcessEpoch(),
            store: .inMemory
        )

        let data = try JSONEncoder().encode(configuration)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(object.keys) == ["host_process_epoch", "store"])
        #expect(
            object["host_process_epoch"] as? String
                == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        #expect(object["provider_id"] == nil)
        #expect(object["providers"] == nil)
        #expect(object["system_prompt"] == nil)
        #expect(object["runtime_policy"] == nil)
    }

    @Test
    func llmContractGatewayRoutesProviderNeutralOperations() async throws {
        let probe = RuntimeCFunctionProbe()
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())

        let actions: [LegacyMigrationActionDTO] = try await client!.request(
            .listLegacyProfileMigrationActions,
            EmptyAgentOSRequestDTO(),
            as: [LegacyMigrationActionDTO].self
        )

        #expect(actions.isEmpty)
        #expect(probe.lastLLMOperation == "list_legacy_profile_migration_actions")
        let request = try #require(probe.lastLLMRequest)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
        )
        #expect(object.isEmpty)

        client = nil
        #expect(probe.freedRuntimeHandles == 1)
        #expect(probe.freedStrings == 1)
    }

    @Test
    func bridgeErrorsStillFreeReturnedStrings() async throws {
        let probe = RuntimeCFunctionProbe()
        probe.createSessionResponse = #"{"error":{"kind":"ffi","message":"bad input"}}"#
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())

        do {
            _ = try await client?.createSession()
            Issue.record("Expected createSession to throw")
        } catch let error as RuntimeBridgeError {
            #expect(error.kind == "ffi")
            #expect(error.message == "bad input")
        }

        client = nil
        #expect(probe.freedRuntimeHandles == 1)
        #expect(probe.freedStrings == 1)
    }

    @Test
    func hostAttestationRejectsLegacyFlattenedFields() throws {
        let digest = String(repeating: "a", count: 64)
        let json = """
        {
          "document": {
            "schema_version": "1",
            "preparation_id": "preparation-1",
            "proposed_run_id": "run-1",
            "session_id": "session-1",
            "swift_snapshot_id": "snapshot-1",
            "prepared_session_registration_digest": "\(digest)",
            "binding_id": "binding-1",
            "binding_revision": "1",
            "binding_hash": "\(digest)",
            "requirements_hash": "\(digest)",
            "disclosure_digest": "\(digest)",
            "capability_snapshot_digest": "\(digest)",
            "resolved_parameters_digest": "\(digest)",
            "host_process_epoch": "epoch-1",
            "expires_at": "2026-07-22T00:02:00.000Z",
            "opaque_egress_subject_digest": "\(digest)"
          },
          "preparation_binding_digest": "\(digest)",
          "egress_attestation_digest": "\(digest)",
          "disclosure_grant_id": "grant-1",
          "data_classes": {"user_content": true},
          "highest_sensitivity": "private",
          "capability_attestation": {
            "supported_capabilities": ["text"],
            "input_modalities": ["text"],
            "context_length": "4096",
            "streaming": true,
            "tool_calling": false,
            "expiration_millis": 120000,
            "attestation_digest": "\(digest)"
          },
          "registration": {},
          "expiration_millis": 120000
        }
        """

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(HostAttestationDTO.self, from: Data(json.utf8))
        }
    }

    private func testHostProcessEpoch() throws -> HostProcessEpoch {
        try #require(
            HostProcessEpoch(
                rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            )
        )
    }
}

private final class RuntimeCFunctionProbe: @unchecked Sendable {
    private let handle = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    var createSessionResponse = #""session_1""#
    var freedStrings = 0
    var freedRuntimeHandles = 0
    var lastLLMOperation: String?
    var lastLLMRequest: String?

    func table() -> RustRuntimeCFunctionTable {
        RustRuntimeCFunctionTable(
            makeRuntime: { self.handle },
            freeRuntime: { runtime in
                if runtime != nil {
                    self.freedRuntimeHandles += 1
                }
            },
            freeString: { value in
                value?.deallocate()
                self.freedStrings += 1
            },
            createSession: { _ in Self.makeCString(self.createSessionResponse) },
            sessionIds: { _ in Self.makeCString("[]") },
            conversationSummaries: { _ in Self.makeCString("[]") },
            forkSession: { _, _, _ in Self.makeCString(#""session_forked""#) },
            activeBranch: { _, _, _ in Self.makeCString("[]") },
            archiveSession: { _, _ in Self.makeCString("null") },
            renameSession: { _, _, _ in Self.makeCString("null") },
            deleteSession: { _, _ in Self.makeCString("null") },
            registerToolSchema: { _, _ in Self.makeCString("null") },
            setPermissionState: { _, _ in Self.makeCString("null") },
            pendingToolRequests: { _ in Self.makeCString("[]") },
            pendingApprovalRequests: { _ in Self.makeCString("[]") },
            submitToolResult: { _, _, _ in Self.makeCString("null") },
            loadDebugArchive: { _, _ in Self.makeCString("null") },
            llmContractRequest: { _, operation, request in
                self.lastLLMOperation = operation.map(String.init(cString:))
                self.lastLLMRequest = request.map(String.init(cString:))
                return Self.makeCString("[]")
            }
        )
    }

    private static func makeCString(_ value: String) -> UnsafeMutablePointer<CChar>? {
        strdup(value)
    }
}
