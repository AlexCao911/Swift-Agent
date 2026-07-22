import Foundation

#if canImport(CLocalAgentRuntime)
import CLocalAgentRuntime
#endif

public enum RustLLMHostCopyReceipt: Int32, Sendable {
    case copied = 0
    case backpressure = 1
    case hostUnavailable = 2
}

#if canImport(CLocalAgentRuntime)
private final class RustLLMHostCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private let receive: @Sendable (Data) -> RustLLMHostCopyReceipt

    init(receive: @escaping @Sendable (Data) -> RustLLMHostCopyReceipt) {
        self.receive = receive
    }

    func copyAndReceive(_ bytes: UnsafePointer<UInt8>?, count: Int) -> RustLLMHostCopyReceipt {
        lock.lock()
        let isAccepting = accepting
        lock.unlock()
        guard isAccepting, let bytes else {
            return .hostUnavailable
        }
        // The owned copy is complete before control returns to Rust. No Rust call is
        // permitted from this synchronous callback.
        return receive(Data(bytes: bytes, count: count))
    }

    func beginQuiescing() {
        lock.lock()
        accepting = false
        lock.unlock()
    }
}

private func rustLLMHostSubmitCommand(
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int,
    _ context: UnsafeMutableRawPointer?
) -> local_agent_llm_host_copy_receipt_t {
    guard let context else {
        return LOCAL_AGENT_LLM_HOST_UNAVAILABLE
    }
    let box = Unmanaged<RustLLMHostCallbackContext>.fromOpaque(context).takeUnretainedValue()
    switch box.copyAndReceive(bytes, count: length) {
    case .copied:
        return LOCAL_AGENT_LLM_HOST_COPIED
    case .backpressure:
        return LOCAL_AGENT_LLM_HOST_BACKPRESSURE
    case .hostUnavailable:
        return LOCAL_AGENT_LLM_HOST_UNAVAILABLE
    }
}

private func rustLLMHostReleaseContext(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<RustLLMHostCallbackContext>.fromOpaque(context).release()
}

internal struct RustLLMHostCFunctionTable: @unchecked Sendable {
    typealias RuntimeHandle = UnsafeMutableRawPointer
    typealias StringResult = UnsafeMutablePointer<CChar>?

    var install: (RuntimeHandle?, UnsafePointer<local_agent_llm_host_vtable_t>?) -> CInt
    var uninstall: (RuntimeHandle?) -> CInt
    var suspend: (RuntimeHandle?) -> CInt
    var resume: (RuntimeHandle?) -> CInt
    var drive: (RuntimeHandle?) -> CInt
    var submitAcknowledgement: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    var submitEvent: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    var freeString: (StringResult) -> Void

    static let live = Self(
        install: { runtime, vtable in
            local_agent_runtime_bridge_install_llm_host(
                runtime.map(OpaquePointer.init),
                vtable
            )
        },
        uninstall: { runtime in
            local_agent_runtime_bridge_uninstall_llm_host(runtime.map(OpaquePointer.init))
        },
        suspend: { runtime in
            local_agent_runtime_bridge_suspend_llm_host(runtime.map(OpaquePointer.init))
        },
        resume: { runtime in
            local_agent_runtime_bridge_resume_llm_host(runtime.map(OpaquePointer.init))
        },
        drive: { runtime in
            local_agent_runtime_bridge_drive_llm_host(runtime.map(OpaquePointer.init))
        },
        submitAcknowledgement: { runtime, json in
            local_agent_runtime_bridge_submit_llm_command_ack(
                runtime.map(OpaquePointer.init),
                json
            )
        },
        submitEvent: { runtime, json in
            local_agent_runtime_bridge_submit_llm_event(runtime.map(OpaquePointer.init), json)
        },
        freeString: { local_agent_runtime_bridge_string_free($0) }
    )
}

public final class RustLLMHostPort: @unchecked Sendable {
    private let owner: AnyObject
    private let runtime: UnsafeMutableRawPointer
    private let functions: RustLLMHostCFunctionTable
    private let callbackContext: RustLLMHostCallbackContext
    private let stateLock = NSLock()
    private var installed = false

    internal init(
        owner: AnyObject,
        runtime: UnsafeMutableRawPointer,
        functions: RustLLMHostCFunctionTable = .live,
        receive: @escaping @Sendable (Data) -> RustLLMHostCopyReceipt
    ) throws {
        self.owner = owner
        self.runtime = runtime
        self.functions = functions
        let context = RustLLMHostCallbackContext(receive: receive)
        self.callbackContext = context
        let retained = Unmanaged.passRetained(context)
        var vtable = local_agent_llm_host_vtable_t(
            abi_version: 1,
            submit_command: rustLLMHostSubmitCommand,
            release_context: rustLLMHostReleaseContext,
            context: retained.toOpaque()
        )
        guard functions.install(runtime, &vtable) == 0 else {
            retained.release()
            throw RuntimeBridgeError(kind: "ffi", message: "failed to install LLM host port")
        }
        installed = true
    }

    deinit {
        try? close()
        _ = owner
    }

    public func close() throws {
        stateLock.lock()
        guard installed else {
            stateLock.unlock()
            return
        }
        installed = false
        callbackContext.beginQuiescing()
        stateLock.unlock()
        guard functions.uninstall(runtime) == 0 else {
            throw RuntimeBridgeError(kind: "ffi", message: "failed to uninstall LLM host port")
        }
    }

    public func suspend() throws {
        guard functions.suspend(runtime) == 0 else {
            throw RuntimeBridgeError(kind: "ffi", message: "failed to suspend LLM host port")
        }
    }

    public func resume() throws {
        guard functions.resume(runtime) == 0 else {
            throw RuntimeBridgeError(kind: "ffi", message: "failed to resume LLM host port")
        }
    }

    internal func driveForTesting() throws {
        guard functions.drive(runtime) == 0 else {
            throw RuntimeBridgeError(kind: "ffi", message: "failed to drive LLM host port")
        }
    }

    public func submitCommandAcknowledgementJSON(_ data: Data) throws -> Data {
        try submit(data, using: functions.submitAcknowledgement)
    }

    public func submitEventJSON(_ data: Data) throws -> Data {
        try submit(data, using: functions.submitEvent)
    }

    private func submit(
        _ data: Data,
        using operation: (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) throws -> Data {
        guard let json = String(data: data, encoding: .utf8) else {
            throw RuntimeBridgeError(kind: "encoding", message: "LLM host JSON must be UTF-8")
        }
        let result = json.withCString { operation(runtime, $0) }
        guard let result else {
            throw RuntimeBridgeError(kind: "ffi", message: "LLM host operation returned null")
        }
        defer { functions.freeString(result) }
        return Data(String(cString: result).utf8)
    }
}
#endif
