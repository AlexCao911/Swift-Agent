import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if canImport(CLocalAgentRuntime)
import CLocalAgentRuntime
#endif

public struct RuntimeBridgeError: Error, Equatable, Sendable, CustomStringConvertible {
    public var kind: String
    public var message: String

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String {
        "\(kind): \(message)"
    }
}

public struct RustRuntimeCFunctionTable: @unchecked Sendable {
    public typealias RuntimeHandle = UnsafeMutableRawPointer
    public typealias StringResult = UnsafeMutablePointer<CChar>?

    public var makeRuntime: () -> RuntimeHandle?
    public var freeRuntime: (RuntimeHandle?) -> Void
    public var freeString: (StringResult) -> Void
    public var createSession: (RuntimeHandle?) -> StringResult
    public var sessionIds: (RuntimeHandle?) -> StringResult
    public var registerToolSchema: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var sendMessage: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var pendingToolRequests: (RuntimeHandle?) -> StringResult
    public var pendingApprovalRequests: (RuntimeHandle?) -> StringResult
    public var submitToolResult: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> StringResult
    public var submitApprovalResponse: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var cancel: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var latestPromptDebugSnapshot: (RuntimeHandle?) -> StringResult

    public init(
        makeRuntime: @escaping () -> RuntimeHandle?,
        freeRuntime: @escaping (RuntimeHandle?) -> Void,
        freeString: @escaping (StringResult) -> Void,
        createSession: @escaping (RuntimeHandle?) -> StringResult,
        sessionIds: @escaping (RuntimeHandle?) -> StringResult,
        registerToolSchema: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        sendMessage: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        pendingToolRequests: @escaping (RuntimeHandle?) -> StringResult,
        pendingApprovalRequests: @escaping (RuntimeHandle?) -> StringResult,
        submitToolResult: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> StringResult,
        submitApprovalResponse: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        cancel: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        latestPromptDebugSnapshot: @escaping (RuntimeHandle?) -> StringResult
    ) {
        self.makeRuntime = makeRuntime
        self.freeRuntime = freeRuntime
        self.freeString = freeString
        self.createSession = createSession
        self.sessionIds = sessionIds
        self.registerToolSchema = registerToolSchema
        self.sendMessage = sendMessage
        self.pendingToolRequests = pendingToolRequests
        self.pendingApprovalRequests = pendingApprovalRequests
        self.submitToolResult = submitToolResult
        self.submitApprovalResponse = submitApprovalResponse
        self.cancel = cancel
        self.latestPromptDebugSnapshot = latestPromptDebugSnapshot
    }

    public static var live: Self {
        DynamicRuntimeBridgeSymbols.load()?.table ?? Self.unavailable
    }

    private static var unavailable: Self {
        let unavailable: (RuntimeHandle?) -> StringResult = { _ in
            makeCString(#"{"error":{"kind":"ffi","message":"CLocalAgentRuntime is unavailable"}}"#)
        }
        return Self(
            makeRuntime: { nil },
            freeRuntime: { _ in },
            freeString: { value in value?.deallocate() },
            createSession: unavailable,
            sessionIds: unavailable,
            registerToolSchema: { _, _ in unavailable(nil) },
            sendMessage: { _, _ in unavailable(nil) },
            pendingToolRequests: unavailable,
            pendingApprovalRequests: unavailable,
            submitToolResult: { _, _, _ in unavailable(nil) },
            submitApprovalResponse: { _, _ in unavailable(nil) },
            cancel: { _, _ in unavailable(nil) },
            latestPromptDebugSnapshot: unavailable
        )
    }
}

private struct DynamicRuntimeBridgeSymbols {
    typealias NewFunction = @convention(c) () -> UnsafeMutableRawPointer?
    typealias FreeRuntimeFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FreeStringFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias RuntimeFunction = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> UnsafeMutablePointer<CChar>?
    typealias RuntimeStringFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>?
    typealias RuntimeTwoStringFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>?

    var new: NewFunction
    var freeRuntime: FreeRuntimeFunction
    var freeString: FreeStringFunction
    var createSession: RuntimeFunction
    var sessionIds: RuntimeFunction
    var registerToolSchema: RuntimeStringFunction
    var sendMessage: RuntimeStringFunction
    var pendingToolRequests: RuntimeFunction
    var pendingApprovalRequests: RuntimeFunction
    var submitToolResult: RuntimeTwoStringFunction
    var submitApprovalResponse: RuntimeStringFunction
    var cancel: RuntimeStringFunction
    var latestPromptDebugSnapshot: RuntimeFunction

    var table: RustRuntimeCFunctionTable {
        RustRuntimeCFunctionTable(
            makeRuntime: new,
            freeRuntime: freeRuntime,
            freeString: freeString,
            createSession: createSession,
            sessionIds: sessionIds,
            registerToolSchema: registerToolSchema,
            sendMessage: sendMessage,
            pendingToolRequests: pendingToolRequests,
            pendingApprovalRequests: pendingApprovalRequests,
            submitToolResult: submitToolResult,
            submitApprovalResponse: submitApprovalResponse,
            cancel: cancel,
            latestPromptDebugSnapshot: latestPromptDebugSnapshot
        )
    }

    static func load() -> Self? {
        guard
            let new = symbol("local_agent_runtime_bridge_new", as: NewFunction.self),
            let freeRuntime = symbol(
                "local_agent_runtime_bridge_free",
                as: FreeRuntimeFunction.self
            ),
            let freeString = symbol(
                "local_agent_runtime_bridge_string_free",
                as: FreeStringFunction.self
            ),
            let createSession = symbol(
                "local_agent_runtime_bridge_create_session",
                as: RuntimeFunction.self
            ),
            let sessionIds = symbol(
                "local_agent_runtime_bridge_session_ids",
                as: RuntimeFunction.self
            ),
            let registerToolSchema = symbol(
                "local_agent_runtime_bridge_register_tool_schema",
                as: RuntimeStringFunction.self
            ),
            let sendMessage = symbol(
                "local_agent_runtime_bridge_send_message",
                as: RuntimeStringFunction.self
            ),
            let pendingToolRequests = symbol(
                "local_agent_runtime_bridge_pending_tool_requests",
                as: RuntimeFunction.self
            ),
            let pendingApprovalRequests = symbol(
                "local_agent_runtime_bridge_pending_approval_requests",
                as: RuntimeFunction.self
            ),
            let submitToolResult = symbol(
                "local_agent_runtime_bridge_submit_tool_result",
                as: RuntimeTwoStringFunction.self
            ),
            let submitApprovalResponse = symbol(
                "local_agent_runtime_bridge_submit_approval_response",
                as: RuntimeStringFunction.self
            ),
            let cancel = symbol(
                "local_agent_runtime_bridge_cancel",
                as: RuntimeStringFunction.self
            ),
            let latestPromptDebugSnapshot = symbol(
                "local_agent_runtime_bridge_latest_prompt_debug_snapshot",
                as: RuntimeFunction.self
            )
        else {
            return nil
        }

        return Self(
            new: new,
            freeRuntime: freeRuntime,
            freeString: freeString,
            createSession: createSession,
            sessionIds: sessionIds,
            registerToolSchema: registerToolSchema,
            sendMessage: sendMessage,
            pendingToolRequests: pendingToolRequests,
            pendingApprovalRequests: pendingApprovalRequests,
            submitToolResult: submitToolResult,
            submitApprovalResponse: submitApprovalResponse,
            cancel: cancel,
            latestPromptDebugSnapshot: latestPromptDebugSnapshot
        )
    }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        #if canImport(Darwin)
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        let currentProcess = dlopen(nil, RTLD_LAZY)
        let rawSymbol = dlsym(defaultHandle, name) ?? dlsym(currentProcess, name)
        guard let rawSymbol else {
            return nil
        }
        return unsafeBitCast(rawSymbol, to: T.self)
        #else
        return nil
        #endif
    }
}

public final class RustRuntimeClient: RuntimeClient, @unchecked Sendable {
    private let functions: RustRuntimeCFunctionTable
    private let handle: RustRuntimeCFunctionTable.RuntimeHandle

    public init(functions: RustRuntimeCFunctionTable = .live) throws {
        guard let handle = functions.makeRuntime() else {
            throw RuntimeBridgeError(
                kind: "ffi",
                message: "failed to create runtime bridge"
            )
        }
        self.functions = functions
        self.handle = handle
    }

    deinit {
        functions.freeRuntime(handle)
    }

    public func createSession() async throws -> String {
        try decode(functions.createSession(handle), as: String.self)
    }

    public func sessionIds() async throws -> [String] {
        try decode(functions.sessionIds(handle), as: [String].self)
    }

    public func registerToolSchema(_ schema: ToolSchemaDTO) async throws {
        let json = try encode(schema)
        _ = try json.withCString { pointer in
            try consume(functions.registerToolSchema(handle, pointer))
        }
    }

    public func sendMessage(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) async throws -> AgentTurnResultDTO {
        let request = SendMessageRequest(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text
        )
        let json = try encode(request)
        return try json.withCString { pointer in
            try decode(functions.sendMessage(handle, pointer), as: AgentTurnResultDTO.self)
        }
    }

    public func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        try decode(
            functions.pendingToolRequests(handle),
            as: [ToolExecutionRequestDTO].self
        )
    }

    public func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        try decode(
            functions.pendingApprovalRequests(handle),
            as: [ApprovalProtocolRequestDTO].self
        )
    }

    public func submitToolResult(
        runId: String,
        result: ToolResultDTO
    ) async throws -> AgentTurnResultDTO {
        let json = try encode(result)
        return try runId.withCString { runIdPointer in
            try json.withCString { resultPointer in
                try decode(
                    functions.submitToolResult(handle, runIdPointer, resultPointer),
                    as: AgentTurnResultDTO.self
                )
            }
        }
    }

    public func submitApprovalResponse(
        _ response: ApprovalProtocolResponseDTO
    ) async throws -> AgentTurnResultDTO {
        let json = try encode(response)
        return try json.withCString { pointer in
            try decode(
                functions.submitApprovalResponse(handle, pointer),
                as: AgentTurnResultDTO.self
            )
        }
    }

    public func cancel(runId: String) async throws -> RuntimeEventDTO {
        try runId.withCString { pointer in
            try decode(functions.cancel(handle, pointer), as: RuntimeEventDTO.self)
        }
    }

    public func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        try decode(
            functions.latestPromptDebugSnapshot(handle),
            as: Optional<PromptDebugSnapshotDTO>.self
        )
    }

    private func decode<T: Decodable>(
        _ response: RustRuntimeCFunctionTable.StringResult,
        as type: T.Type
    ) throws -> T {
        let data = try consume(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func consume(_ response: RustRuntimeCFunctionTable.StringResult) throws -> Data {
        guard let response else {
            throw RuntimeBridgeError(
                kind: "ffi",
                message: "runtime bridge returned a null string"
            )
        }
        defer { functions.freeString(response) }

        let text = String(cString: response)
        let data = Data(text.utf8)
        if let envelope = try? JSONDecoder().decode(BridgeErrorEnvelope.self, from: data),
           let error = envelope.error {
            throw RuntimeBridgeError(kind: error.kind, message: error.message)
        }
        return data
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct SendMessageRequest: Encodable {
    var sessionId: String
    var parentEventId: String?
    var text: String

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case parentEventId = "parent_event_id"
        case text
    }
}

private struct BridgeErrorEnvelope: Decodable {
    var error: BridgeErrorDetail?
}

private struct BridgeErrorDetail: Decodable {
    var kind: String
    var message: String
}

private func makeCString(_ string: String) -> UnsafeMutablePointer<CChar> {
    let cString = string.utf8CString
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: cString.count)
    cString.withUnsafeBufferPointer { buffer in
        pointer.initialize(from: buffer.baseAddress!, count: buffer.count)
    }
    return pointer
}
