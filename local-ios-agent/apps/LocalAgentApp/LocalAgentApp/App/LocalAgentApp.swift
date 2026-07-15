import LocalAgentBridge
import LocalNativeToolkit
import SwiftUI

@main
struct LocalAgentApp: App {
    private let hostProcessEpoch: HostProcessEpoch
    @State private var container: AppContainer?
    @State private var shellViewModel: AppShellViewModel?

    @MainActor
    init() {
        guard let hostProcessEpoch = try? HostProcessEpoch.generate() else {
            preconditionFailure("The app cannot establish a secure host process epoch")
        }
        self.hostProcessEpoch = hostProcessEpoch
        _container = State(initialValue: nil)
        _shellViewModel = State(initialValue: nil)
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
    }
}
