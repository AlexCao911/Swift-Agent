import LocalAgentBridge
import LocalNativeToolkit
import SwiftUI

@main
struct LocalAgentApp: App {
    private let container: AppContainer
    @State private var shellViewModel: AppShellViewModel

    @MainActor
    init() {
        guard let hostProcessEpoch = try? HostProcessEpoch.generate() else {
            preconditionFailure("The app cannot establish a secure host process epoch")
        }
        do {
            let container = try AppBootstrapper.makeContainer(
                hostProcessEpoch: hostProcessEpoch
            )
            self.container = container
            _shellViewModel = State(initialValue: container.makeAppShellViewModel())
        } catch {
            let container: AppContainer
            let bootstrapError = error
            do {
                container = try AppBootstrapper.makeDegradedContainer(
                    error: bootstrapError,
                    hostProcessEpoch: hostProcessEpoch
                )
            } catch {
                container = AppBootstrapper.makeLastResortContainer(
                    error: bootstrapError,
                    hostProcessEpoch: hostProcessEpoch
                )
            }
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
