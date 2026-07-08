import LocalAgentBridge
import LocalNativeToolkit
import SwiftUI

@main
struct LocalAgentApp: App {
    private let container: AppContainer
    @State private var shellViewModel: AppShellViewModel

    @MainActor
    init() {
        do {
            let container = try AppBootstrapper.makeContainer()
            self.container = container
            _shellViewModel = State(initialValue: container.makeAppShellViewModel())
        } catch {
            let container = AppContainer(
                runtimeService: AgentRuntimeService(
                    runtimeClient: FailingRuntimeClient(error: error),
                    toolDriver: MinimalHostToolDriver()
                ),
                runDebugService: nil,
                nativeToolkitClient: EmptyNativeToolkitClient(),
                nativePermissionGateway: StoreBackedNativePermissionGateway(store: PermissionStore()),
                agentBuilderClient: MockAgentBuilderClient.withReadinessIssues([
                    PermissionIssueDTO(
                        code: "app.bootstrap.failed",
                        message: error.localizedDescription
                    ),
                ]),
                permissionClient: MockPermissionClient(issues: []),
                agentBuilderToolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: []),
                runInlineCardActionHandler: RunInlineCardActionHandler(
                    broker: NativeInteractionBroker(
                        store: InMemoryPendingUserInteractionStore(),
                        presenter: UnavailableNativeInteractionPresenter()
                    )
                )
            )
            self.container = container
            _shellViewModel = State(initialValue: container.makeAppShellViewModel())
        }
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(viewModel: shellViewModel, container: container)
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

private actor EmptyNativeToolkitClient: NativeToolkitClientProtocol {
    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot {
        NativeToolkitRegistrationSnapshot(schemas: [], toolNames: [])
    }

    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO {
        ToolResultDTO(
            displayText: "Native toolkit is unavailable.",
            modelText: "Native toolkit is unavailable.",
            structuredJson: #"{"error":"native_toolkit_unavailable"}"#,
            auditText: "Native toolkit unavailable.",
            sensitivity: .public,
            retention: .runOnly,
            isError: true
        )
    }
}
