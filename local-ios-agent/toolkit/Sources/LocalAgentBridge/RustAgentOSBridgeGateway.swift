import Foundation

public enum RustAgentOSOperation: String, Sendable {
    case listAgentProfiles = "list_agent_profiles"
    case buildAgent = "build_agent"
    case prepareUserTurn = "prepare_user_turn"
    case commitAssistantResult = "commit_assistant_result"
    case startRun = "start_run"
    case observeEvents = "observe_events"
    case approveTool = "approve_tool"
    case cancelRun = "cancel_run"
    case updateRuntimeOptions = "update_runtime_options"
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
