import Foundation
import LocalAgentLLMContracts

#if canImport(CLocalAgentRuntime)
import CLocalAgentRuntime
#endif

internal let runtimeEventStreamBufferLimit = 512

public typealias HostProcessEpoch = LocalAgentLLMContracts.HostProcessEpoch

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
    public var hostProcessEpoch: HostProcessEpoch
    public var store: RustRuntimeStoreConfiguration
    public var agentOS: RustAgentOSConfiguration?

    public init(
        hostProcessEpoch: HostProcessEpoch,
        store: RustRuntimeStoreConfiguration,
        agentOS: RustAgentOSConfiguration? = nil
    ) {
        self.hostProcessEpoch = hostProcessEpoch
        self.store = store
        self.agentOS = agentOS
    }

    private enum CodingKeys: String, CodingKey {
        case hostProcessEpoch = "host_process_epoch"
        case store
        case agentOS = "agent_os"
    }
}

public struct RustAgentOSConfiguration: Codable, Equatable, Sendable {
    public var seedDevelopmentProfile: Bool

    public init(seedDevelopmentProfile: Bool = false) {
        self.seedDevelopmentProfile = seedDevelopmentProfile
    }

    private enum CodingKeys: String, CodingKey {
        case seedDevelopmentProfile = "seed_development_profile"
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
    public var renameSession: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> StringResult
    public var deleteSession: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var registerToolSchema: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var setPermissionState: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var pendingToolRequests: (RuntimeHandle?) -> StringResult
    public var pendingApprovalRequests: (RuntimeHandle?) -> StringResult
    public var submitToolResult: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> StringResult
    public var loadDebugArchive: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var listAgentProfiles: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var buildAgent: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var prepareUserTurn: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var observeEvents: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var observeEventsStreaming: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        RuntimeEventCallback?,
        UnsafeMutableRawPointer?
    ) -> StringResult
    public var submitTranscriptCommand: (
        RuntimeHandle?,
        UnsafePointer<CChar>?
    ) -> StringResult
    public var observeTranscriptProjections: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        RuntimeEventCallback?,
        UnsafeMutableRawPointer?
    ) -> StringResult
    public var cancelTranscriptProjectionSubscription: (
        RuntimeHandle?,
        UnsafePointer<CChar>?
    ) -> StringResult
    public var commitAssistantResult: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var approveTool: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var cancelRun: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var previewContext: (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult
    public var llmContractRequest: (
        RuntimeHandle?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> StringResult

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
        renameSession: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> StringResult,
        deleteSession: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        registerToolSchema: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        setPermissionState: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        pendingToolRequests: @escaping (RuntimeHandle?) -> StringResult,
        pendingApprovalRequests: @escaping (RuntimeHandle?) -> StringResult,
        submitToolResult: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> StringResult,
        loadDebugArchive: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult,
        listAgentProfiles: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult = { _, _ in nil },
        buildAgent: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult = { _, _ in nil },
        prepareUserTurn: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult = { _, _ in nil },
        observeEvents: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult = { _, _ in nil },
        observeEventsStreaming: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            RuntimeEventCallback?,
            UnsafeMutableRawPointer?
        ) -> StringResult = { _, _, _, _ in nil },
        commitAssistantResult: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult = { _, _ in nil },
        approveTool: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult = { _, _ in nil },
        cancelRun: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult = { _, _ in nil },
        previewContext: @escaping (RuntimeHandle?, UnsafePointer<CChar>?) -> StringResult = { _, _ in nil },
        llmContractRequest: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> StringResult = { _, _, _ in nil },
        submitTranscriptCommand: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?
        ) -> StringResult = { _, _ in nil },
        observeTranscriptProjections: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?,
            RuntimeEventCallback?,
            UnsafeMutableRawPointer?
        ) -> StringResult = { _, _, _, _ in nil },
        cancelTranscriptProjectionSubscription: @escaping (
            RuntimeHandle?,
            UnsafePointer<CChar>?
        ) -> StringResult = { _, _ in nil }
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
        self.renameSession = renameSession
        self.deleteSession = deleteSession
        self.registerToolSchema = registerToolSchema
        self.setPermissionState = setPermissionState
        self.pendingToolRequests = pendingToolRequests
        self.pendingApprovalRequests = pendingApprovalRequests
        self.submitToolResult = submitToolResult
        self.loadDebugArchive = loadDebugArchive
        self.listAgentProfiles = listAgentProfiles
        self.buildAgent = buildAgent
        self.prepareUserTurn = prepareUserTurn
        self.observeEvents = observeEvents
        self.observeEventsStreaming = observeEventsStreaming
        self.commitAssistantResult = commitAssistantResult
        self.approveTool = approveTool
        self.cancelRun = cancelRun
        self.previewContext = previewContext
        self.llmContractRequest = llmContractRequest
        self.submitTranscriptCommand = submitTranscriptCommand
        self.observeTranscriptProjections = observeTranscriptProjections
        self.cancelTranscriptProjectionSubscription =
            cancelTranscriptProjectionSubscription
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
            renameSession: { runtime, sessionId, title in
                local_agent_runtime_bridge_rename_session(
                    runtime.map { OpaquePointer($0) },
                    sessionId,
                    title
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
            loadDebugArchive: { runtime, runId in
                local_agent_runtime_bridge_load_debug_archive(
                    runtime.map { OpaquePointer($0) },
                    runId
                )
            },
            listAgentProfiles: { runtime, requestJson in
                local_agent_runtime_bridge_list_agent_profiles(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            },
            buildAgent: { runtime, requestJson in
                local_agent_runtime_bridge_build_agent(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            },
            prepareUserTurn: { runtime, requestJson in
                local_agent_runtime_bridge_prepare_user_turn(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            },
            observeEvents: { runtime, requestJson in
                local_agent_runtime_bridge_observe_events(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            },
            observeEventsStreaming: { runtime, requestJson, callback, userData in
                local_agent_runtime_bridge_observe_events_streaming(
                    runtime.map { OpaquePointer($0) },
                    requestJson,
                    callback,
                    userData
                )
            },
            commitAssistantResult: { runtime, requestJson in
                local_agent_runtime_bridge_commit_assistant_result(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            },
            approveTool: { runtime, requestJson in
                local_agent_runtime_bridge_approve_tool(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            },
            cancelRun: { runtime, requestJson in
                local_agent_runtime_bridge_cancel_run(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            },
            previewContext: { runtime, requestJson in
                local_agent_runtime_bridge_preview_context(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            },
            llmContractRequest: { runtime, operation, requestJson -> RustRuntimeCFunctionTable.StringResult in
                guard let operation else { return nil }
                switch String(cString: operation) {
                case RustAgentOSOperation.buildAgentV2.rawValue:
                    return local_agent_runtime_bridge_build_agent_v2(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.prepareProfilePublish.rawValue:
                    return local_agent_runtime_bridge_prepare_profile_publish(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.commitProfilePublish.rawValue:
                    return local_agent_runtime_bridge_commit_profile_publish(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.beginPackageBinding.rawValue:
                    return local_agent_runtime_bridge_begin_package_binding(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.attachHostBinding.rawValue:
                    return local_agent_runtime_bridge_attach_host_binding(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.confirmHostBindingActivation.rawValue:
                    return local_agent_runtime_bridge_confirm_host_binding_activation(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.beginLegacyProfileMigration.rawValue:
                    return local_agent_runtime_bridge_begin_legacy_profile_migration(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.listLegacyProfileMigrations.rawValue:
                    return local_agent_runtime_bridge_list_legacy_profile_migrations(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.listLegacyProfileMigrationActions.rawValue:
                    return local_agent_runtime_bridge_list_legacy_profile_migration_actions(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.completeLegacyProfileMigration.rawValue:
                    return local_agent_runtime_bridge_complete_legacy_profile_migration(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.previewRunPreparation.rawValue:
                    return local_agent_runtime_bridge_preview_run_preparation(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.renewRunPreparation.rawValue:
                    return local_agent_runtime_bridge_renew_run_preparation(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.registerPreparedSession.rawValue:
                    return local_agent_runtime_bridge_register_prepared_session(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.commitPreparedStart.rawValue:
                    return local_agent_runtime_bridge_commit_prepared_start(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.reconcilePreparation.rawValue:
                    return local_agent_runtime_bridge_reconcile_preparation(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.beginAbortPreparation.rawValue:
                    return local_agent_runtime_bridge_begin_abort_preparation(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.ackPreparedSessionCleanup.rawValue:
                    return local_agent_runtime_bridge_ack_prepared_session_cleanup(runtime.map { OpaquePointer($0) }, requestJson)
                case RustAgentOSOperation.confirmPreparedSessionClosed.rawValue:
                    return local_agent_runtime_bridge_confirm_prepared_session_closed(runtime.map { OpaquePointer($0) }, requestJson)
                default:
                    return nil
                }
            },
            submitTranscriptCommand: { runtime, requestJson in
                local_agent_runtime_bridge_submit_transcript_command(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            },
            observeTranscriptProjections: {
                runtime,
                requestJson,
                callback,
                userData in
                local_agent_runtime_bridge_observe_transcript_projections(
                    runtime.map { OpaquePointer($0) },
                    requestJson,
                    callback,
                    userData
                )
            },
            cancelTranscriptProjectionSubscription: { runtime, requestJson in
                local_agent_runtime_bridge_cancel_transcript_projection_subscription(
                    runtime.map { OpaquePointer($0) },
                    requestJson
                )
            }
        )
    }
}

public final class RustRuntimeClient: RuntimeClient, ConversationRuntimeClient, RustAgentOSBridgeGateway, @unchecked Sendable {
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

    #if canImport(CLocalAgentRuntime)
    public func installLLMHost(
        receive: @escaping @Sendable (Data) -> RustLLMHostCopyReceipt
    ) throws -> RustLLMHostPort {
        try RustLLMHostPort(owner: self, runtime: handle, receive: receive)
    }
    #endif

    public func createSession() async throws -> String {
        try decode(functions.createSession(handle), as: String.self)
    }

    public func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        try runId.withCString { pointer in
            try decode(functions.loadDebugArchive(handle, pointer), as: RunDebugUIModel.self)
        }
    }

    public func request<Request: Encodable, Response: Decodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request,
        as response: Response.Type
    ) async throws -> Response {
        let json = try encode(request)
        return try json.withCString { pointer in
            let result: RustRuntimeCFunctionTable.StringResult
            switch operation {
            case .listAgentProfiles:
                result = functions.listAgentProfiles(handle, pointer)
            case .buildAgent:
                result = functions.buildAgent(handle, pointer)
            case .prepareUserTurn:
                result = functions.prepareUserTurn(handle, pointer)
            case .commitAssistantResult:
                result = functions.commitAssistantResult(handle, pointer)
            case .approveTool:
                result = functions.approveTool(handle, pointer)
            case .submitToolResult:
                let submitRequest = try JSONDecoder().decode(
                    SubmitToolResultRequestDTO.self,
                    from: Data(json.utf8)
                )
                let resultJson = try encode(submitRequest.result)
                result = submitRequest.runId.withCString { runIdPointer in
                    resultJson.withCString { resultPointer in
                        functions.submitToolResult(handle, runIdPointer, resultPointer)
                    }
                }
            case .cancelRun:
                result = functions.cancelRun(handle, pointer)
            case .previewContext:
                result = functions.previewContext(handle, pointer)
            case .transcriptCommand:
                result = functions.submitTranscriptCommand(handle, pointer)
            case .buildAgentV2, .prepareProfilePublish, .commitProfilePublish, .beginPackageBinding,
                 .attachHostBinding, .confirmHostBindingActivation, .previewRunPreparation, .renewRunPreparation,
                 .registerPreparedSession, .commitPreparedStart, .reconcilePreparation,
                 .beginAbortPreparation,
                 .ackPreparedSessionCleanup, .confirmPreparedSessionClosed,
                 .beginLegacyProfileMigration, .listLegacyProfileMigrations,
                 .listLegacyProfileMigrationActions,
                 .completeLegacyProfileMigration:
                result = operation.rawValue.withCString { operationPointer in
                    functions.llmContractRequest(handle, operationPointer, pointer)
                }
            case .observeEvents, .observeTranscriptProjections,
                 .cancelTranscriptProjectionSubscription:
                throw RuntimeBridgeError(
                    kind: "unsupported_operation",
                    message: "\(operation.rawValue) uses its dedicated bridge method"
                )
            }
            return try decode(result, as: Response.self)
        }
    }

    public func stream<Request: Encodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request
    ) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        guard operation == .observeEvents else {
            return failedEventStream(RuntimeBridgeError(
                kind: "unsupported_operation",
                message: "\(operation.rawValue) does not expose an event stream"
            ))
        }

        do {
            let json = try encode(request)
            return makeEventStream { callback, userData in
                json.withCString { pointer in
                    self.functions.observeEventsStreaming(
                        self.handle,
                        pointer,
                        callback,
                        userData
                    )
                }
            }
        } catch {
            return failedEventStream(error)
        }
    }

    public func observeTranscriptProjections(
        _ request: ObserveTranscriptProjectionsRequestDTO
    ) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error> {
        do {
            let json = try encode(request)
            let (events, continuation) = AsyncThrowingStream.makeStream(
                of: TranscriptProjectionEventDTO.self,
                throwing: Error.self,
                bufferingPolicy: .bufferingOldest(runtimeEventStreamBufferLimit)
            )
            let callbackBox = TranscriptProjectionCallbackBox(
                continuation: continuation
            )
            continuation.onTermination = { @Sendable _ in
                Task { [weak self, callbackBox] in
                    guard let self else { return }
                    await self.cancelTranscriptProjectionSubscription(
                        subscriptionID: request.subscriptionID
                    )
                    callbackBox.terminate()
                }
            }
            Task.detached { [self, callbackBox] in
                let opaque = Unmanaged.passRetained(callbackBox).toOpaque()
                defer {
                    Unmanaged<TranscriptProjectionCallbackBox>
                        .fromOpaque(opaque)
                        .release()
                }
                do {
                    let response = json.withCString { pointer in
                        functions.observeTranscriptProjections(
                            handle,
                            pointer,
                            rustTranscriptProjectionCallback,
                            opaque
                        )
                    }
                    _ = try consume(response)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            return events
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
    }

    public func cancelTranscriptProjectionSubscription(
        subscriptionID: String
    ) async {
        let request = CancelTranscriptProjectionSubscriptionDTO(
            subscriptionID: subscriptionID
        )
        guard let json = try? encode(request) else { return }
        _ = try? json.withCString { pointer in
            try consume(
                functions.cancelTranscriptProjectionSubscription(handle, pointer)
            )
        }
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

    public func renameSession(sessionId: String, title: String) async throws {
        _ = try sessionId.withCString { sessionPointer in
            try title.withCString { titlePointer in
                try consume(functions.renameSession(handle, sessionPointer, titlePointer))
            }
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

    private func decode<T: Decodable>(
        _ response: RustRuntimeCFunctionTable.StringResult,
        as type: T.Type
    ) throws -> T {
        let data = try consume(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeEventStream(
        call: @escaping @Sendable (
            RustRuntimeCFunctionTable.RuntimeEventCallback?,
            UnsafeMutableRawPointer?
        ) -> RustRuntimeCFunctionTable.StringResult
    ) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self,
            bufferingPolicy: .bufferingOldest(runtimeEventStreamBufferLimit)
        )
        let callbackBox = RuntimeEventCallbackBox(
            continuation: continuation,
            dropPolicy: .failOnDroppedEvents
        )
        continuation.onTermination = { @Sendable _ in
            callbackBox.terminate(cancelRun: false)
        }
        Task.detached { [self, callbackBox] in
            let opaqueCallbackBox = Unmanaged.passRetained(callbackBox).toOpaque()
            defer {
                Unmanaged<RuntimeEventCallbackBox>
                    .fromOpaque(opaqueCallbackBox)
                    .release()
            }

            do {
                let response = call(rustRuntimeEventCallback, opaqueCallbackBox)
                _ = try consume(response)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return events
    }

    private func failedEventStream(_ error: Error) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        let bridgeError = error as? RuntimeBridgeError ?? RuntimeBridgeError(
            kind: "swift",
            message: error.localizedDescription
        )
        return AsyncThrowingStream<RuntimeEventDTO, Error> { continuation in
            continuation.finish(throwing: bridgeError)
        }
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

private enum RuntimeEventDropPolicy {
    case allowDroppedEvents
    case failOnDroppedEvents
}

private final class RuntimeEventCallbackBox: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<RuntimeEventDTO, Error>.Continuation
    private let dropPolicy: RuntimeEventDropPolicy
    private let onCancelRun: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var terminated = false
    private var cancelRequested = false
    private var latestRunId: String?
    private var cancellationDispatchedRunId: String?

    init(
        continuation: AsyncThrowingStream<RuntimeEventDTO, Error>.Continuation,
        initialRunId: String? = nil,
        dropPolicy: RuntimeEventDropPolicy,
        onCancelRun: (@Sendable (String) -> Void)? = nil
    ) {
        self.continuation = continuation
        self.latestRunId = initialRunId
        self.dropPolicy = dropPolicy
        self.onCancelRun = onCancelRun
    }

    func terminate(cancelRun: Bool) {
        let runIdToCancel: String?
        lock.lock()
        terminated = true
        if cancelRun {
            cancelRequested = true
        }
        runIdToCancel = pendingCancellationRunIdLocked()
        lock.unlock()

        if let runIdToCancel {
            onCancelRun?(runIdToCancel)
        }
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

            let shouldReject: Bool
            let runIdToCancel: String?
            lock.lock()
            latestRunId = event.runId ?? latestRunId
            shouldReject = terminated
            runIdToCancel = pendingCancellationRunIdLocked()
            lock.unlock()

            if let runIdToCancel {
                onCancelRun?(runIdToCancel)
            }
            if shouldReject {
                return 1
            }

            switch continuation.yield(event) {
            case .enqueued(_):
                return 0
            case .dropped(_):
                switch dropPolicy {
                case .allowDroppedEvents:
                    return 0
                case .failOnDroppedEvents:
                    continuation.finish(throwing: RuntimeBridgeError(
                        kind: "ffi",
                        message: "runtime event stream buffer overflow"
                    ))
                    return 1
                }
            case .terminated:
                return 1
            @unknown default:
                return 1
            }
        } catch {
            continuation.finish(throwing: error)
            return 1
        }
    }

    private func pendingCancellationRunIdLocked() -> String? {
        guard cancelRequested,
              let latestRunId,
              cancellationDispatchedRunId != latestRunId
        else {
            return nil
        }
        cancellationDispatchedRunId = latestRunId
        return latestRunId
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

private final class TranscriptProjectionCallbackBox: @unchecked Sendable {
    private let continuation:
        AsyncThrowingStream<TranscriptProjectionEventDTO, Error>.Continuation
    private let lock = NSLock()
    private var terminated = false

    init(
        continuation:
            AsyncThrowingStream<TranscriptProjectionEventDTO, Error>.Continuation
    ) {
        self.continuation = continuation
    }

    func terminate() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    func yield(eventJSON: UnsafePointer<CChar>?) -> CInt {
        guard let eventJSON else {
            continuation.finish(throwing: RuntimeBridgeError(
                kind: "ffi",
                message: "runtime bridge streamed a null projection event"
            ))
            return 1
        }
        lock.lock()
        let shouldReject = terminated
        lock.unlock()
        if shouldReject {
            return 1
        }

        do {
            let event = try JSONDecoder().decode(
                TranscriptProjectionEventDTO.self,
                from: Data(String(cString: eventJSON).utf8)
            )
            switch continuation.yield(event) {
            case .enqueued:
                return 0
            case .dropped:
                continuation.finish(throwing: RuntimeBridgeError(
                    kind: "ffi",
                    message: "transcript projection stream buffer overflow"
                ))
                return 1
            case .terminated:
                return 1
            @unknown default:
                return 1
            }
        } catch {
            continuation.finish(throwing: error)
            return 1
        }
    }
}

private func rustTranscriptProjectionCallback(
    eventJSON: UnsafePointer<CChar>?,
    userData: UnsafeMutableRawPointer?
) -> CInt {
    guard let userData else { return 1 }
    return Unmanaged<TranscriptProjectionCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .yield(eventJSON: eventJSON)
}

private struct SetPermissionStateRequest: Encodable {
    var scope: String
    var state: PermissionStateDTO
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
