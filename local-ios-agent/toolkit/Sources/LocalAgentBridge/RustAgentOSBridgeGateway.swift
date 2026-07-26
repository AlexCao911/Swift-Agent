import Foundation

public enum RustAgentOSOperation: String, Hashable, Sendable {
    case listAgentProfiles = "list_agent_profiles"
    case buildAgent = "build_agent"
    case prepareUserTurn = "prepare_user_turn"
    case commitAssistantResult = "commit_assistant_result"
    case startRun = "start_run"
    case observeEvents = "observe_events"
    case approveTool = "approve_tool"
    case submitToolResult = "submit_tool_result"
    case cancelRun = "cancel_run"
    case updateRuntimeOptions = "update_runtime_options"
    case previewContext = "preview_context"
    case profileExecutionRoute = "profile_execution_route"
    case prepareProfilePublish = "prepare_profile_publish"
    case commitProfilePublish = "commit_profile_publish"
    case beginPackageBinding = "begin_package_binding"
    case attachHostBinding = "attach_host_binding"
    case confirmHostBindingActivation = "confirm_host_binding_activation"
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
}

public protocol ProfileExecutionRouteClient: Sendable {
    func profileExecutionRoute(
        profileID: String,
        profileRevision: UInt64
    ) async throws -> ProfileExecutionRouteDTO
}
