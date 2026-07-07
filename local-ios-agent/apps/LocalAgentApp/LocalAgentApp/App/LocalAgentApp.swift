import LocalAgentBridge
import SwiftUI

@main
struct LocalAgentApp: App {
    private let container: AppContainer

    init() {
        do {
            container = try AppBootstrapper.makeContainer()
        } catch {
            container = AppContainer(
                runtimeService: AgentRuntimeService(
                    runtimeClient: FailingRuntimeClient(error: error),
                    toolDriver: MinimalHostToolDriver()
                ),
                agentBuilderClient: MockAgentBuilderClient.withReadinessIssues([
                    PermissionIssueDTO(
                        code: "app.bootstrap.failed",
                        message: error.localizedDescription
                    ),
                ]),
                permissionClient: MockPermissionClient(issues: []),
                agentBuilderToolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            BuilderFirstHostView(container: container)
        }
    }
}

private actor FailingRuntimeClient: RuntimeClient {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func createSession() async throws -> String { throw error }
    func sessionIds() async throws -> [String] { throw error }
    func registerToolSchema(_ schema: ToolSchemaDTO) async throws { throw error }
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws { throw error }
    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO { throw error }
    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] { throw error }
    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] { throw error }
    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO { throw error }
    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO { throw error }
    func cancel(runId: String) async throws -> RuntimeEventDTO { throw error }
    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? { throw error }
}
