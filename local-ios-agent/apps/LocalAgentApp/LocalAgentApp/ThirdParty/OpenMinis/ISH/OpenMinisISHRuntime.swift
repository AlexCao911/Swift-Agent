import Foundation

struct ISHCommandResult: Equatable, Sendable {
    let pid: Int32
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    let wasCancelled: Bool
}

protocol OpenMinisISHRunning: Sendable {
    func execute(
        executable: String,
        arguments: [String],
        stdin: Data?,
        onProcessStarted: @escaping @Sendable (Int32) async -> Void
    ) async -> ISHCommandResult
}

enum ISHEnvironmentPolicy {
    /// Credentials remain in Swift secure storage. The guest receives only
    /// deterministic product-neutral values from ISHShellExecutor.
    static let guestEnvironment: [String: String] = [:]
}

actor OpenMinisISHRuntime: OpenMinisISHRunning {
    static let shared = OpenMinisISHRuntime()

    private var prepared = false

    func execute(
        executable: String,
        arguments: [String],
        stdin: Data?,
        onProcessStarted: @escaping @Sendable (Int32) async -> Void
    ) async -> ISHCommandResult {
        do {
            try prepareIfNeeded()
        } catch {
            return ISHCommandResult(
                pid: -1,
                exitCode: -1,
                stdout: "",
                stderr: "Unable to prepare the Linux environment: \(error.localizedDescription)",
                duration: 0,
                wasCancelled: false
            )
        }

        let process = ISHProcessCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let pid = ISHShellExecutor.executeExecutable(
                    executable,
                    arguments: arguments,
                    environment: ISHEnvironmentPolicy.guestEnvironment,
                    stdinData: stdin,
                    lineCallback: nil
                ) { result in
                    continuation.resume(
                        returning: ISHCommandResult(
                            pid: Int32(result.pid),
                            exitCode: Int32(result.exitCode),
                            stdout: result.output,
                            stderr: result.errorOutput,
                            duration: result.duration,
                            wasCancelled: result.error == .cancelled
                        )
                    )
                }

                process.register(pid: Int32(pid))
                if pid >= 0 {
                    Task {
                        await onProcessStarted(Int32(pid))
                    }
                } else {
                    continuation.resume(
                        returning: ISHCommandResult(
                            pid: Int32(pid),
                            exitCode: Int32(pid),
                            stdout: "",
                            stderr: "Unable to start the Linux process.",
                            duration: 0,
                            wasCancelled: false
                        )
                    )
                }
            }
        } onCancel: {
            process.cancel()
        }
    }

    private func prepareIfNeeded() throws {
        guard !prepared else { return }
        guard !RootfsManager.shared.didResetWhileBooted else {
            throw ISHRuntimeError.requiresRelaunch
        }

        try RootfsManager.shared.installIfNeeded()
        let kernel = ISHKernel.shared
        if !kernel.isBooted {
            let status = kernel.boot(withRootPath: RootfsManager.shared.rootfsPath.path)
            guard status == 0 else {
                throw ISHRuntimeError.bootFailed(status)
            }
            RootfsManager.shared.applyDefaultMountOverlay()
        }
        for (mount, configuration) in LocalAgentToolMounts.configurations() {
            let guestPath = "/var/localagent/\(mount.rawValue)"
            let status = kernel.bindMountPath(
                guestPath,
                toHostPath: configuration.rootURL.path,
                readOnly: configuration.isWritable == false
            )
            guard status == 0 else {
                throw ISHRuntimeError.mountFailed(guestPath, status)
            }
        }
        prepared = true
    }
}

private enum ISHRuntimeError: LocalizedError {
    case bootFailed(Int32)
    case mountFailed(String, Int32)
    case requiresRelaunch

    var errorDescription: String? {
        switch self {
        case .bootFailed(let status):
            "iSH failed to boot (status \(status))."
        case .mountFailed(let path, let status):
            "iSH failed to mount \(path) (status \(status))."
        case .requiresRelaunch:
            "The Linux filesystem was reset; relaunch LocalAgent before using it."
        }
    }
}

private final class ISHProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    private var cancelled = false

    func register(pid: Int32) {
        let shouldCancel = lock.withLock {
            self.pid = pid
            return cancelled && pid >= 0
        }
        if shouldCancel {
            ISHShellExecutor.killProcessGroup(pid)
        }
    }

    func cancel() {
        let activePID = lock.withLock {
            cancelled = true
            return pid
        }
        if let activePID, activePID >= 0 {
            ISHShellExecutor.killProcessGroup(activePID)
        }
    }
}
