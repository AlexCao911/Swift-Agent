import LocalAgentBridge
import LocalNativeToolkit
import SwiftUI

@main
struct LocalAgentApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let hostProcessEpoch: HostProcessEpoch
    @State private var container: AppContainer?
    @State private var shellViewModel: AppShellViewModel?
    @State private var intentRouter: AppIntentRouter

    @MainActor
    init() {
        guard let hostProcessEpoch = try? HostProcessEpoch.generate() else {
            preconditionFailure("The app cannot establish a secure host process epoch")
        }
        self.hostProcessEpoch = hostProcessEpoch
        _container = State(initialValue: nil)
        _shellViewModel = State(initialValue: nil)
        _intentRouter = State(initialValue: .shared)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container, let shellViewModel {
                    AppShellView(viewModel: shellViewModel, container: container)
                } else {
                    ProgressView("Preparing local runtime…")
                        .task { await bootstrap() }
                }
            }
            .onChange(of: intentRouter.pendingRoute) {
                consumePendingIntent()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                container?.resumeLLMHost()
            case .inactive, .background:
                container?.suspendLLMHost()
                if let broker = container?.cloudApprovalBroker {
                    Task { await broker.denyAll() }
                }
            @unknown default:
                container?.suspendLLMHost()
                if let broker = container?.cloudApprovalBroker {
                    Task { await broker.denyAll() }
                }
            }
        }
    }

    @MainActor
    private func bootstrap() async {
        guard container == nil else { return }
        let ready: AppContainer
        do {
            ready = try await AppBootstrapper.makeReadyContainer(
                hostProcessEpoch: hostProcessEpoch
            )
        } catch {
            let bootstrapError = error
            do {
                ready = try AppBootstrapper.makeDegradedContainer(
                    error: bootstrapError,
                    hostProcessEpoch: hostProcessEpoch
                )
            } catch {
                ready = AppBootstrapper.makeLastResortContainer(
                    error: bootstrapError,
                    hostProcessEpoch: hostProcessEpoch
                )
            }
        }
        container = ready
        shellViewModel = ready.makeAppShellViewModel()
        consumePendingIntent()
    }

    @MainActor
    private func consumePendingIntent() {
        guard let shellViewModel,
              let route = intentRouter.consumePendingRoute()
        else { return }
        shellViewModel.handleAppIntent(route)
    }
}
