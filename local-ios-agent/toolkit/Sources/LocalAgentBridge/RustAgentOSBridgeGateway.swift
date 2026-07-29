import Foundation

public enum RustAgentOSOperation: String, Hashable, Sendable {
    case listAgentProfiles = "list_agent_profiles"
    case buildAgent = "build_agent"
    case buildAgentV2 = "build_agent_v2"
    case prepareUserTurn = "prepare_user_turn"
    case commitAssistantResult = "commit_assistant_result"
    case observeEvents = "observe_events"
    case transcriptCommand = "transcript_command"
    case observeTranscriptProjections = "observe_transcript_projections"
    case cancelTranscriptProjectionSubscription =
        "cancel_transcript_projection_subscription"
    case approveTool = "approve_tool"
    case submitToolResult = "submit_tool_result"
    case cancelRun = "cancel_run"
    case previewContext = "preview_context"
    case prepareProfilePublish = "prepare_profile_publish"
    case commitProfilePublish = "commit_profile_publish"
    case beginPackageBinding = "begin_package_binding"
    case attachHostBinding = "attach_host_binding"
    case confirmHostBindingActivation = "confirm_host_binding_activation"
    case beginLegacyProfileMigration = "begin_legacy_profile_migration"
    case listLegacyProfileMigrations = "list_legacy_profile_migrations"
    case listLegacyProfileMigrationActions = "list_legacy_profile_migration_actions"
    case completeLegacyProfileMigration = "complete_legacy_profile_migration"
    case previewRunPreparation = "preview_run_preparation"
    case renewRunPreparation = "renew_run_preparation"
    case registerPreparedSession = "register_prepared_session"
    case commitPreparedStart = "commit_prepared_start"
    case reconcilePreparation = "reconcile_preparation"
    case beginAbortPreparation = "begin_abort_preparation"
    case ackPreparedSessionCleanup = "ack_prepared_session_cleanup"
    case confirmPreparedSessionClosed = "confirm_prepared_session_closed"
}

public protocol RustAgentOSBridgeGateway: Sendable {
    func request<Request: Encodable, Response: Decodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request,
        as response: Response.Type
    ) async throws -> Response

    func stream<Request: Encodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request
    ) -> AsyncThrowingStream<RuntimeEventDTO, Error>

    func observeTranscriptProjections(
        _ request: ObserveTranscriptProjectionsRequestDTO
    ) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error>

    func cancelTranscriptProjectionSubscription(
        subscriptionID: String
    ) async
}

public extension RustAgentOSBridgeGateway {
    func observeTranscriptProjections(
        _ request: ObserveTranscriptProjectionsRequestDTO
    ) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: RuntimeBridgeError(
                kind: "unsupported_operation",
                message: "transcript projection stream is unavailable"
            ))
        }
    }

    func cancelTranscriptProjectionSubscription(
        subscriptionID: String
    ) async {}
}
