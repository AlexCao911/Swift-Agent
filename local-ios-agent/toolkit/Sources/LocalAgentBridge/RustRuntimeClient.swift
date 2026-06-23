import Foundation

#if canImport(CLocalAgentRuntime)
import CLocalAgentRuntime
#endif

public struct RuntimeBridgeError: LocalizedError, Equatable, Sendable, CustomStringConvertible {
    public var kind: String
    public var message: String

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? {
        message
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
    public var providers: [RustRuntimeProviderConfiguration]

    public init(
        systemPrompt: String,
        runtimePolicy: String,
        providerId: String,
        store: RustRuntimeStoreConfiguration,
        providers: [RustRuntimeProviderConfiguration] = []
    ) {
        self.systemPrompt = systemPrompt
        self.runtimePolicy = runtimePolicy
        self.providerId = providerId
        self.store = store
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case runtimePolicy = "runtime_policy"
        case providerId = "provider_id"
        case store
        case providers
    }
}

public enum RustRuntimeProviderConfiguration: Codable, Equatable, Sendable {
    case desktopMiniCPM(endpoint: String, model: String, maxContextTokens: Int)
    case localLLM(model: String, modelConfigJson: String, maxContextTokens: Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "desktop_minicpm", "desktop_mini_cpm":
            self = .desktopMiniCPM(
                endpoint: try container.decode(String.self, forKey: .endpoint),
                model: try container.decode(String.self, forKey: .model),
                maxContextTokens: try container.decode(Int.self, forKey: .maxContextTokens)
            )
        case "local_llm":
            self = .localLLM(
                model: try container.decode(String.self, forKey: .model),
                modelConfigJson: try container.decode(String.self, forKey: .modelConfigJson),
                maxContextTokens: try container.decode(Int.self, forKey: .maxContextTokens)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown provider kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .desktopMiniCPM(let endpoint, let model, let maxContextTokens):
            try container.encode("desktop_minicpm", forKey: .kind)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(model, forKey: .model)
            try container.encode(maxContextTokens, forKey: .maxContextTokens)
        case .localLLM(let model, let modelConfigJson, let maxContextTokens):
            try container.encode("local_llm", forKey: .kind)
            try container.encode(model, forKey: .model)
            try container.encode(modelConfigJson, forKey: .modelConfigJson)
            try container.encode(maxContextTokens, forKey: .maxContextTokens)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case endpoint
        case model
        case modelConfigJson = "model_config_json"
        case maxContextTokens = "max_context_tokens"
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
    public typealias RuntimeEventCallback = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?
    ) -> CInt

    public var makeRuntime: () -> RuntimeHandle?
    public var freeRuntime: (RuntimeHandle?) -> Void
    public var freeString: (StringResult) -> Void
    public var createSession: (RuntimeHandle?) -> StringResult
    public var sessionIds: (RuntimeHandle?) -> StringResult
    public var conversationSummaries: (RuntimeHandle?) -> StringResult
    public var forkSession: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> StringResult
    public var activeBranch: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> StringResult
    public var archiveSession: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var deleteSession: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var registerToolSchema: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var setPermissionState: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var sendMessage: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var sendMessageStreaming: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        RuntimeEventCallback?,
        UnsafeMutableRawPointer?
    ) -> StringResult
    public var pendingToolRequests: (RuntimeHandle?) -> StringResult
    public var pendingApprovalRequests: (RuntimeHandle?) -> StringResult
    public var submitToolResult: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> StringResult
    public var submitToolResultStreaming: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        RuntimeEventCallback?,
        UnsafeMutableRawPointer?
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
        conversationSummaries: @escaping (RuntimeHandle?) -> StringResult,
        forkSession: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> StringResult,
        activeBranch: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> StringResult,
        archiveSession: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        deleteSession: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        registerToolSchema: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        setPermissionState: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        sendMessage: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        sendMessageStreaming: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            RuntimeEventCallback?,
            UnsafeMutableRawPointer?
        ) -> StringResult,
        pendingToolRequests: @escaping (RuntimeHandle?) -> StringResult,
        pendingApprovalRequests: @escaping (RuntimeHandle?) -> StringResult,
        submitToolResult: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> StringResult,
        submitToolResultStreaming: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            RuntimeEventCallback?,
            UnsafeMutableRawPointer?
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
        self.conversationSummaries = conversationSummaries
        self.forkSession = forkSession
        self.activeBranch = activeBranch
        self.archiveSession = archiveSession
        self.deleteSession = deleteSession
        self.registerToolSchema = registerToolSchema
        self.setPermissionState = setPermissionState
        self.sendMessage = sendMessage
        self.sendMessageStreaming = sendMessageStreaming
        self.pendingToolRequests = pendingToolRequests
        self.pendingApprovalRequests = pendingApprovalRequests
        self.submitToolResult = submitToolResult
        self.submitToolResultStreaming = submitToolResultStreaming
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
            conversationSummaries: { runtime in
                local_agent_runtime_bridge_conversation_summaries(runtime.map { OpaquePointer($0) })
            },
            forkSession: { runtime, sessionId, leafId in
                local_agent_runtime_bridge_fork_session(
                    runtime.map { OpaquePointer($0) },
                    sessionId,
                    leafId
                )
            },
            activeBranch: { runtime, sessionId, leafId in
                local_agent_runtime_bridge_active_branch(
                    runtime.map { OpaquePointer($0) },
                    sessionId,
                    leafId
                )
            },
            archiveSession: { runtime, sessionId in
                local_agent_runtime_bridge_archive_session(
                    runtime.map { OpaquePointer($0) },
                    sessionId
                )
            },
            deleteSession: { runtime, sessionId in
                local_agent_runtime_bridge_delete_session(
                    runtime.map { OpaquePointer($0) },
                    sessionId
                )
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
            sendMessageStreaming: { runtime, inputJson, callback, userData in
                local_agent_runtime_bridge_send_message_streaming(
                    runtime.map { OpaquePointer($0) },
                    inputJson,
                    callback,
                    userData
                )
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
            submitToolResultStreaming: { runtime, runId, resultJson, callback, userData in
                local_agent_runtime_bridge_submit_tool_result_streaming(
                    runtime.map { OpaquePointer($0) },
                    runId,
                    resultJson,
                    callback,
                    userData
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

public final class RustRuntimeClient: StreamingBlobReferencingRuntimeClient, ProviderControllingRuntimeClient, ConversationRuntimeClient, @unchecked Sendable {
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

    public func conversationSummaries() async throws -> [ConversationSummaryDTO] {
        try decode(
            functions.conversationSummaries(handle),
            as: [ConversationSummaryDTO].self
        )
    }

    public func forkSession(sessionId: String, leafId: String) async throws -> String {
        try sessionId.withCString { sessionPointer in
            try leafId.withCString { leafPointer in
                try decode(
                    functions.forkSession(handle, sessionPointer, leafPointer),
                    as: String.self
                )
            }
        }
    }

    public func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
        try sessionId.withCString { sessionPointer in
            if let leafId {
                return try leafId.withCString { leafPointer in
                    try decode(
                        functions.activeBranch(handle, sessionPointer, leafPointer),
                        as: [RuntimeEventDTO].self
                    )
                }
            }

            return try decode(
                functions.activeBranch(handle, sessionPointer, nil),
                as: [RuntimeEventDTO].self
            )
        }
    }

    public func archiveSession(sessionId: String) async throws {
        _ = try sessionId.withCString { sessionPointer in
            try consume(functions.archiveSession(handle, sessionPointer))
        }
    }

    public func deleteSession(sessionId: String) async throws {
        _ = try sessionId.withCString { sessionPointer in
            try consume(functions.deleteSession(handle, sessionPointer))
        }
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
        try await sendMessage(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text,
            blobRefs: []
        )
    }

    public func sendMessage(
        sessionId: String,
        parentEventId: String?,
        text: String,
        blobRefs: [String]
    ) async throws -> AgentTurnResultDTO {
        let request = SendMessageRequest(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text,
            blobRefs: blobRefs
        )
        let json = try encode(request)
        return try json.withCString { pointer in
            try decode(functions.sendMessage(handle, pointer), as: AgentTurnResultDTO.self)
        }
    }

    public func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        sendMessageStream(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text,
            blobRefs: []
        )
    }

    public func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String,
        blobRefs: [String]
    ) -> AgentTurnStreamDTO {
        do {
            let request = SendMessageRequest(
                sessionId: sessionId,
                parentEventId: parentEventId,
                text: text,
                blobRefs: blobRefs
            )
            let json = try encode(request)
            return makeTurnStream { callback, userData in
                json.withCString { pointer in
                    self.functions.sendMessageStreaming(
                        self.handle,
                        pointer,
                        callback,
                        userData
                    )
                }
            }
        } catch {
            return failedTurnStream(error)
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

    public func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        do {
            let json = try encode(result)
            return makeTurnStream { callback, userData in
                runId.withCString { runIdPointer in
                    json.withCString { resultPointer in
                        self.functions.submitToolResultStreaming(
                            self.handle,
                            runIdPointer,
                            resultPointer,
                            callback,
                            userData
                        )
                    }
                }
            }
        } catch {
            return failedTurnStream(error)
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

    private func makeTurnStream(
        call: @escaping @Sendable (
            RustRuntimeCFunctionTable.RuntimeEventCallback?,
            UnsafeMutableRawPointer?
        ) -> RustRuntimeCFunctionTable.StringResult
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let result = Task.detached { [self] in
            let callbackBox = RuntimeEventCallbackBox(continuation: continuation)
            let opaqueCallbackBox = Unmanaged.passRetained(callbackBox).toOpaque()
            defer {
                Unmanaged<RuntimeEventCallbackBox>
                    .fromOpaque(opaqueCallbackBox)
                    .release()
            }

            do {
                let response = call(rustRuntimeEventCallback, opaqueCallbackBox)
                let result = try decode(response, as: AgentTurnResultDTO.self)
                continuation.finish()
                return result
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    private func failedTurnStream(_ error: Error) -> AgentTurnStreamDTO {
        let bridgeError = RuntimeBridgeError(
            kind: "swift",
            message: error.localizedDescription
        )
        let events = AsyncThrowingStream<RuntimeEventDTO, Error> { continuation in
            continuation.finish(throwing: bridgeError)
        }
        let result = Task<AgentTurnResultDTO, Error> {
            throw bridgeError
        }
        return AgentTurnStreamDTO(events: events, result: result)
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
    var blobRefs: [String] = []

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case parentEventId = "parent_event_id"
        case text
        case blobRefs = "blob_refs"
    }
}

private final class RuntimeEventCallbackBox: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<RuntimeEventDTO, Error>.Continuation

    init(continuation: AsyncThrowingStream<RuntimeEventDTO, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(eventJson: UnsafePointer<CChar>?) -> CInt {
        guard let eventJson else {
            continuation.finish(throwing: RuntimeBridgeError(
                kind: "ffi",
                message: "runtime bridge streamed a null event string"
            ))
            return 1
        }

        let eventText = String(cString: eventJson)
        do {
            let event = try JSONDecoder().decode(
                RuntimeEventDTO.self,
                from: Data(eventText.utf8)
            )
            continuation.yield(event)
            return 0
        } catch {
            continuation.finish(throwing: error)
            return 1
        }
    }
}

private func rustRuntimeEventCallback(
    eventJson: UnsafePointer<CChar>?,
    userData: UnsafeMutableRawPointer?
) -> CInt {
    guard let userData else {
        return 1
    }
    let box = Unmanaged<RuntimeEventCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return box.yield(eventJson: eventJson)
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
