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
            let container: AppContainer
            let bootstrapError = error
            do {
                container = try AppBootstrapper.makeDegradedContainer(error: bootstrapError)
            } catch {
                container = AppBootstrapper.makeLastResortContainer(error: bootstrapError)
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
