import Foundation

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

public struct RustRuntimeConfiguration: Codable, Equatable, Sendable {
    public var systemPrompt: String
    public var runtimePolicy: String
    public var providerId: String
    public var store: RustRuntimeStoreConfiguration

    public init(
        systemPrompt: String,
        runtimePolicy: String,
        providerId: String,
        store: RustRuntimeStoreConfiguration
    ) {
        self.systemPrompt = systemPrompt
        self.runtimePolicy = runtimePolicy
        self.providerId = providerId
        self.store = store
    }

    private enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case runtimePolicy = "runtime_policy"
        case providerId = "provider_id"
        case store
    }
}

public enum RustRuntimeStoreConfiguration: Codable, Equatable, Sendable {
    case inMemory
    case sqlite(path: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "in_memory":
            self = .inMemory
        case "sqlite":
            self = .sqlite(path: try container.decode(String.self, forKey: .path))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown store kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inMemory:
            try container.encode("in_memory", forKey: .kind)
        case .sqlite(let path):
            try container.encode("sqlite", forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
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
    public var setPermissionState: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
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
    public var providerProfiles: (RuntimeHandle?) -> StringResult
    public var activeProvider: (RuntimeHandle?) -> StringResult
    public var setProvider: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult

    public init(
        makeRuntime: @escaping () -> RuntimeHandle?,
        freeRuntime: @escaping (RuntimeHandle?) -> Void,
        freeString: @escaping (StringResult) -> Void,
        createSession: @escaping (RuntimeHandle?) -> StringResult,
        sessionIds: @escaping (RuntimeHandle?) -> StringResult,
        registerToolSchema: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        setPermissionState: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
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
        latestPromptDebugSnapshot: @escaping (RuntimeHandle?) -> StringResult,
        providerProfiles: @escaping (RuntimeHandle?) -> StringResult,
        activeProvider: @escaping (RuntimeHandle?) -> StringResult,
        setProvider: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    ) {
        self.makeRuntime = makeRuntime
        self.freeRuntime = freeRuntime
        self.freeString = freeString
        self.createSession = createSession
        self.sessionIds = sessionIds
        self.registerToolSchema = registerToolSchema
        self.setPermissionState = setPermissionState
        self.sendMessage = sendMessage
        self.pendingToolRequests = pendingToolRequests
        self.pendingApprovalRequests = pendingApprovalRequests
        self.submitToolResult = submitToolResult
        self.submitApprovalResponse = submitApprovalResponse
        self.cancel = cancel
        self.latestPromptDebugSnapshot = latestPromptDebugSnapshot
        self.providerProfiles = providerProfiles
        self.activeProvider = activeProvider
        self.setProvider = setProvider
    }

    public static func live(configuration: RustRuntimeConfiguration) throws -> Self {
        let configurationJson = try encodeConfiguration(configuration)
        return Self(
            makeRuntime: {
                configurationJson.withCString { pointer in
                    guard let runtime = local_agent_runtime_bridge_new_with_config(pointer) else {
                        return nil
                    }
                    return UnsafeMutableRawPointer(runtime)
                }
            },
            freeRuntime: { runtime in
                local_agent_runtime_bridge_free(runtime.map { OpaquePointer($0) })
            },
            freeString: { value in
                local_agent_runtime_bridge_string_free(value)
            },
            createSession: { runtime in
                local_agent_runtime_bridge_create_session(runtime.map { OpaquePointer($0) })
            },
            sessionIds: { runtime in
                local_agent_runtime_bridge_session_ids(runtime.map { OpaquePointer($0) })
            },
            registerToolSchema: { runtime, schemaJson in
                local_agent_runtime_bridge_register_tool_schema(
                    runtime.map { OpaquePointer($0) },
                    schemaJson
                )
            },
            setPermissionState: { runtime, stateJson in
                local_agent_runtime_bridge_set_permission_state(
                    runtime.map { OpaquePointer($0) },
                    stateJson
                )
            },
            sendMessage: { runtime, inputJson in
                local_agent_runtime_bridge_send_message(runtime.map { OpaquePointer($0) }, inputJson)
            },
            pendingToolRequests: { runtime in
                local_agent_runtime_bridge_pending_tool_requests(runtime.map { OpaquePointer($0) })
            },
            pendingApprovalRequests: { runtime in
                local_agent_runtime_bridge_pending_approval_requests(runtime.map { OpaquePointer($0) })
            },
            submitToolResult: { runtime, runId, resultJson in
                local_agent_runtime_bridge_submit_tool_result(
                    runtime.map { OpaquePointer($0) },
                    runId,
                    resultJson
                )
            },
            submitApprovalResponse: { runtime, responseJson in
                local_agent_runtime_bridge_submit_approval_response(
                    runtime.map { OpaquePointer($0) },
                    responseJson
                )
            },
            cancel: { runtime, runId in
                local_agent_runtime_bridge_cancel(runtime.map { OpaquePointer($0) }, runId)
            },
            latestPromptDebugSnapshot: { runtime in
                local_agent_runtime_bridge_latest_prompt_debug_snapshot(
                    runtime.map { OpaquePointer($0) }
                )
            },
            providerProfiles: { runtime in
                local_agent_runtime_bridge_provider_profiles(runtime.map { OpaquePointer($0) })
            },
            activeProvider: { runtime in
                local_agent_runtime_bridge_active_provider(runtime.map { OpaquePointer($0) })
            },
            setProvider: { runtime, requestJson in
                local_agent_runtime_bridge_set_provider(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            }
        )
    }
}

public final class RustRuntimeClient: RuntimeClient, ProviderControllingRuntimeClient, @unchecked Sendable {
    private let functions: RustRuntimeCFunctionTable
    private let handle: RustRuntimeCFunctionTable.RuntimeHandle

    public convenience init(configuration: RustRuntimeConfiguration) throws {
        try self.init(functions: .live(configuration: configuration))
    }

    public init(functions: RustRuntimeCFunctionTable) throws {
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

    public func setPermissionState(scope: String, state: PermissionStateDTO) async throws {
        let request = SetPermissionStateRequest(scope: scope, state: state)
        let json = try encode(request)
        _ = try json.withCString { pointer in
            try consume(functions.setPermissionState(handle, pointer))
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

    public func providerProfiles() async throws -> [ProviderProfileDTO] {
        try decode(functions.providerProfiles(handle), as: [ProviderProfileDTO].self)
    }

    public func activeProvider() async throws -> ProviderProfileDTO {
        try decode(functions.activeProvider(handle), as: ProviderProfileDTO.self)
    }

    public func setProvider(sessionId: String, providerId: String) async throws -> RuntimeEventDTO {
        let request = SetProviderRequest(sessionId: sessionId, providerId: providerId)
        let json = try encode(request)
        return try json.withCString { pointer in
            try decode(functions.setProvider(handle, pointer), as: RuntimeEventDTO.self)
        }
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

private struct SetPermissionStateRequest: Encodable {
    var scope: String
    var state: PermissionStateDTO
}

private struct SetProviderRequest: Encodable {
    var sessionId: String
    var providerId: String

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case providerId = "provider_id"
    }
}

private struct BridgeErrorEnvelope: Decodable {
    var error: BridgeErrorDetail?
}

private struct BridgeErrorDetail: Decodable {
    var kind: String
    var message: String
}

private func encodeConfiguration(_ configuration: RustRuntimeConfiguration) throws -> String {
    let data = try JSONEncoder().encode(configuration)
    return String(decoding: data, as: UTF8.self)
}

private func makeCString(_ string: String) -> UnsafeMutablePointer<CChar> {
    let cString = string.utf8CString
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: cString.count)
    cString.withUnsafeBufferPointer { buffer in
        pointer.initialize(from: buffer.baseAddress!, count: buffer.count)
    }
    return pointer
}
