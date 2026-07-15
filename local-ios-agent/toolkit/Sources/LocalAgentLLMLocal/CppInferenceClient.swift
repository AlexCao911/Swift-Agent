import Foundation
import LocalAgentLLMContracts
import LocalAgentInferenceNative

package protocol CppInferenceAPI: Sendable {
    func listEngines() throws -> [CppEngineDescriptor]
    func validateModel(_ request: CppModelLoadRequest) throws
    func load(_ request: CppModelLoadRequest) throws -> any CppLoadedModelAPI
}

package protocol CppLoadedModelAPI: AnyObject, Sendable {
    func validateGeneration(_ request: CppGenerationRequest) throws
    func start(_ request: CppGenerationRequest) throws -> any CppGenerationAPI
    func unload() throws
}

package protocol CppGenerationAPI: AnyObject, Sendable {
    var events: CppTokenEventSequence { get }
    func cancel() throws
    func release() throws
}

package protocol CppInferenceRegistryAPI: Sendable {
    func listEngines() throws -> [CppEngineDescriptor]
    func capabilities(engineID: String) throws -> CppEngineCapabilities
}

package struct CppEngineDescriptor: Decodable, Equatable, Sendable {
    package let engineID: String
    package let abiVersion: String
    package let engineVersion: String
    package let displayName: String
    package let testOnly: Bool
    package let capabilities: CppEngineCapabilities

    package init(
        engineID: String,
        abiVersion: String,
        engineVersion: String,
        displayName: String,
        testOnly: Bool,
        capabilities: CppEngineCapabilities
    ) {
        self.engineID = engineID
        self.abiVersion = abiVersion
        self.engineVersion = engineVersion
        self.displayName = displayName
        self.testOnly = testOnly
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case engineID = "engine_id"
        case abiVersion = "abi_version"
        case engineVersion = "engine_version"
        case displayName = "display_name"
        case testOnly = "test_only"
        case capabilities
    }
}

package struct CppEngineCapabilities: Decodable, Equatable, Sendable {
    package let supportedModelFormats: Set<String>
    package let supportsVision: Bool
    package let supportsStreaming: Bool
    package let supportsCancellation: Bool
    package let supportsTokenUsage: Bool
    package let maxContextTokens: UInt64?
    package let backendParameters: [CppParameterDescriptor]

    package init(
        supportedModelFormats: Set<String>,
        supportsVision: Bool,
        supportsStreaming: Bool,
        supportsCancellation: Bool,
        supportsTokenUsage: Bool,
        maxContextTokens: UInt64?,
        backendParameters: [CppParameterDescriptor]
    ) {
        self.supportedModelFormats = supportedModelFormats
        self.supportsVision = supportsVision
        self.supportsStreaming = supportsStreaming
        self.supportsCancellation = supportsCancellation
        self.supportsTokenUsage = supportsTokenUsage
        self.maxContextTokens = maxContextTokens
        self.backendParameters = backendParameters
    }

    private enum CodingKeys: String, CodingKey {
        case supportedModelFormats = "supported_model_formats"
        case supportsVision = "supports_vision"
        case supportsStreaming = "supports_streaming"
        case supportsCancellation = "supports_cancellation"
        case supportsTokenUsage = "supports_token_usage"
        case maxContextTokens = "max_context_tokens"
        case backendParameters = "backend_parameters"
    }
}

package struct CppParameterDescriptor: Decodable, Equatable, Sendable {
    package let backendOption: String
    package let valueType: String
    package let minimum: Double?
    package let maximum: Double?

    package init(
        backendOption: String,
        valueType: String,
        minimum: Double?,
        maximum: Double?
    ) {
        self.backendOption = backendOption
        self.valueType = valueType
        self.minimum = minimum
        self.maximum = maximum
    }

    private enum CodingKeys: String, CodingKey {
        case backendOption = "backend_option"
        case valueType = "value_type"
        case minimum, maximum
    }
}

package struct CppModelLoadRequest: Equatable, Sendable {
    package let engineID: String
    package let modelID: String
    package let modelFormat: String
    package let artifactPathsByRole: [String: String]
    package let contextTokens: UInt64
    package let manifestLoadOptions: [String: CanonicalJSONValue]
    package let template: LocalChatTemplateSelector
    package let toolCallCodecID: String?

    package init(
        engineID: String,
        modelID: String,
        modelFormat: String,
        artifactPathsByRole: [String: String],
        contextTokens: UInt64,
        manifestLoadOptions: [String: CanonicalJSONValue],
        template: LocalChatTemplateSelector,
        toolCallCodecID: String? = nil
    ) {
        self.engineID = engineID
        self.modelID = modelID
        self.modelFormat = modelFormat
        self.artifactPathsByRole = artifactPathsByRole
        self.contextTokens = contextTokens
        self.manifestLoadOptions = manifestLoadOptions
        self.template = template
        self.toolCallCodecID = toolCallCodecID
    }
}

public struct LocalResolvedAttachment: Equatable, Sendable {
    public let attachmentID: String
    public let rgb8: Data
    public let width: UInt32
    public let height: UInt32

    public init(attachmentID: String, rgb8: Data, width: UInt32, height: UInt32) {
        self.attachmentID = attachmentID
        self.rgb8 = rgb8
        self.width = width
        self.height = height
    }
}

package struct CppGenerationRequest: Equatable, Sendable {
    package let input: AgentLLMInput
    package let attachments: [LocalResolvedAttachment]
    package let canonicalToolSchema: CanonicalJSONValue?
    package let template: LocalChatTemplateSelector
    package let toolCallCodecID: String?
    package let concreteOptions: [String: CanonicalJSONValue]

    package init(
        input: AgentLLMInput,
        attachments: [LocalResolvedAttachment],
        canonicalToolSchema: CanonicalJSONValue?,
        template: LocalChatTemplateSelector,
        toolCallCodecID: String?,
        concreteOptions: [String: CanonicalJSONValue]
    ) {
        self.input = input
        self.attachments = attachments
        self.canonicalToolSchema = canonicalToolSchema
        self.template = template
        self.toolCallCodecID = toolCallCodecID
        self.concreteOptions = concreteOptions
    }
}

package enum CppInferenceRequestEncoder {
    package static func modelJSON(_ request: CppModelLoadRequest) throws -> Data {
        guard !request.engineID.isEmpty,
              !request.modelID.isEmpty,
              !request.modelFormat.isEmpty,
              request.contextTokens > 0,
              let weights = request.artifactPathsByRole[LocalModelArtifactRole.weights.rawValue],
              weights.hasPrefix("/")
        else {
            throw failure(
                "local_engine.model_request_invalid",
                "model load request is missing signed engine, model, or weights identity"
            )
        }
        var entries = [
            CanonicalJSONObjectEntry(name: "engine", value: .string(request.engineID)),
            .init(name: "model_id", value: .string(request.modelID)),
            .init(name: "model_path", value: .string(weights)),
            .init(name: "model_format", value: .string(request.modelFormat)),
            .init(name: "context_tokens", value: .number(Double(request.contextTokens))),
            .init(name: "chat_template_source", value: .string(request.template.source.rawValue)),
            .init(name: "chat_template_id", value: .string(request.template.templateID)),
        ]
        if let mmproj = request.artifactPathsByRole[
            LocalModelArtifactRole.multimodalProjection.rawValue
        ] {
            guard mmproj.hasPrefix("/") else {
                throw failure("local_engine.model_request_invalid", "multimodal artifact path is invalid")
            }
            entries.append(.init(name: "mmproj_path", value: .string(mmproj)))
        }
        if let codecID = request.toolCallCodecID {
            entries.append(.init(name: "tool_call_codec_id", value: .string(codecID)))
        }

        let runtimeKeys = Set(["n_threads", "n_gpu_layers"])
        let runtimeOptions = request.manifestLoadOptions.filter { runtimeKeys.contains($0.key) }
        if !runtimeOptions.isEmpty {
            entries.append(.init(
                name: "runtime",
                value: try .object(entries: runtimeOptions.map {
                    .init(name: $0.key, value: $0.value)
                })
            ))
        }
        if !request.manifestLoadOptions.isEmpty {
            entries.append(.init(
                name: "manifest_options",
                value: try .object(entries: request.manifestLoadOptions.map {
                    .init(name: $0.key, value: $0.value)
                })
            ))
        }
        return try CanonicalDigestV1.canonicalize(.object(entries: entries))
    }

    package static func generationJSON(_ request: CppGenerationRequest) throws -> Data {
        let referencedAttachments = try attachmentReferences(in: request.input)
        let buffers = Dictionary(
            request.attachments.map { ($0.attachmentID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        guard buffers.count == request.attachments.count,
              Set(referencedAttachments) == Set(buffers.keys),
              referencedAttachments.count == buffers.count
        else {
            throw failure(
                "local_engine.attachment_mismatch",
                "attachment references must match the supplied image buffers exactly"
            )
        }

        for attachment in request.attachments {
            let expectedBytes = UInt64(attachment.width) * UInt64(attachment.height) * 3
            guard attachment.width > 0,
                  attachment.height > 0,
                  expectedBytes <= UInt64(Int.max),
                  attachment.rgb8.count == Int(expectedBytes)
            else {
                throw failure(
                    "local_engine.attachment_invalid",
                    "resolved image attachment is not valid rgb8 data"
                )
            }
        }

        let messages = try request.input.messages.map(messageDocument)
        var entries = [
            CanonicalJSONObjectEntry(name: "schema_version", value: .string("2")),
            CanonicalJSONObjectEntry(name: "messages", value: .array(messages)),
            CanonicalJSONObjectEntry(
                name: "template",
                value: try .object(entries: [
                    .init(name: "source", value: .string(request.template.source.rawValue)),
                    .init(name: "id", value: .string(request.template.templateID)),
                ])
            ),
        ]

        if let toolSchema = request.canonicalToolSchema {
            guard request.toolCallCodecID != nil else {
                throw failure(
                    "local_engine.tool_codec_missing",
                    "tool schema requires an approved tool-call codec"
                )
            }
            entries.append(.init(name: "tool_schema", value: toolSchema))
        }
        if let codecID = request.toolCallCodecID {
            guard request.canonicalToolSchema != nil else {
                throw failure(
                    "local_engine.tool_schema_missing",
                    "tool-call codec requires a tool schema"
                )
            }
            entries.append(.init(name: "tool_call_codec_id", value: .string(codecID)))
        }
        if !referencedAttachments.isEmpty {
            entries.append(.init(
                name: "images",
                value: .array(try referencedAttachments.map { id in
                    guard let attachment = buffers[id] else {
                        throw failure("local_engine.attachment_mismatch", "image buffer is missing")
                    }
                    return try .object(entries: [
                        .init(name: "format", value: .string("rgb8")),
                        .init(name: "width", value: .number(Double(attachment.width))),
                        .init(name: "height", value: .number(Double(attachment.height))),
                    ])
                })
            ))
        }
        if !request.concreteOptions.isEmpty {
            entries.append(.init(
                name: "sampling",
                value: try .object(entries: request.concreteOptions.map {
                    .init(name: $0.key, value: $0.value)
                })
            ))
        }

        return try CanonicalDigestV1.canonicalize(.object(entries: entries))
    }

    private static func attachmentReferences(in input: AgentLLMInput) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for message in input.messages {
            for content in message.content {
                guard case let .attachment(modality, attachmentID, mediaType) = content else {
                    continue
                }
                guard modality == .image, mediaType == "image/rgb8", !attachmentID.isEmpty else {
                    throw failure(
                        "local_engine.attachment_unsupported",
                        "local inference accepts only resolved image/rgb8 attachments"
                    )
                }
                guard seen.insert(attachmentID).inserted else {
                    throw failure(
                        "local_engine.attachment_duplicate",
                        "each resolved attachment must be referenced exactly once"
                    )
                }
                result.append(attachmentID)
            }
        }
        return result
    }

    private static func messageDocument(_ message: LLMInputMessage) throws -> CanonicalJSONValue {
        let textParts = message.content.compactMap { content -> CanonicalJSONValue? in
            guard case let .text(text) = content else { return nil }
            return try? .object(entries: [
                .init(name: "type", value: .string("text")),
                .init(name: "text", value: .string(text)),
            ])
        }
        guard !textParts.isEmpty else {
            throw failure(
                "local_engine.message_content_invalid",
                "each local inference message requires at least one text part"
            )
        }
        return try .object(entries: [
            .init(name: "role", value: .string(message.role.rawValue)),
            .init(name: "content", value: .array(textParts)),
        ])
    }

    private static func failure(_ code: String, _ message: String) -> LLMFailure {
        LLMFailure(code: code, message: message, retryable: false)
    }
}

package enum CppInferenceRegistry {
    package static let live: any CppInferenceRegistryAPI = LiveCppInferenceRegistry()
}

package enum CppInferenceClient {
    package static let live: any CppInferenceAPI & LocalModelConfigValidator = LiveCppInferenceClient()
}

package enum CppInferenceRegistryError: Error, Equatable, Sendable {
    case nativeStatus(Int32)
    case missingOutput
    case unknownEngine(String)
}

private struct LiveCppInferenceRegistry: CppInferenceRegistryAPI {
    func listEngines() throws -> [CppEngineDescriptor] {
        var output: UnsafeMutablePointer<CChar>?
        let status = local_agent_engine_list(&output)
        guard status == LOCAL_AGENT_STATUS_OK else {
            throw CppInferenceRegistryError.nativeStatus(Int32(status.rawValue))
        }
        guard let output else {
            throw CppInferenceRegistryError.missingOutput
        }
        defer { local_agent_string_free(output) }
        return try JSONDecoder().decode(
            [CppEngineDescriptor].self,
            from: Data(String(cString: output).utf8)
        )
    }

    func capabilities(engineID: String) throws -> CppEngineCapabilities {
        guard try listEngines().contains(where: { $0.engineID == engineID }) else {
            throw CppInferenceRegistryError.unknownEngine(engineID)
        }

        var engine: OpaquePointer?
        let createStatus = engineID.withCString {
            local_agent_engine_create($0, &engine)
        }
        guard createStatus == LOCAL_AGENT_STATUS_OK else {
            throw CppInferenceRegistryError.nativeStatus(Int32(createStatus.rawValue))
        }
        guard let engine else {
            throw CppInferenceRegistryError.missingOutput
        }
        defer { _ = local_agent_engine_release(engine) }

        var output: UnsafeMutablePointer<CChar>?
        let capabilitiesStatus = local_agent_engine_capabilities(engine, &output)
        guard capabilitiesStatus == LOCAL_AGENT_STATUS_OK else {
            throw CppInferenceRegistryError.nativeStatus(Int32(capabilitiesStatus.rawValue))
        }
        guard let output else {
            throw CppInferenceRegistryError.missingOutput
        }
        defer { local_agent_string_free(output) }
        return try JSONDecoder().decode(
            CppEngineCapabilities.self,
            from: Data(String(cString: output).utf8)
        )
    }
}

private struct LiveCppInferenceClient: CppInferenceAPI, LocalModelConfigValidator {
    func listEngines() throws -> [CppEngineDescriptor] {
        try CppInferenceRegistry.live.listEngines()
    }

    func validate(
        manifest: LocalModelRevisionManifest,
        artifactPathsByRole: [LocalModelArtifactRole: URL]
    ) throws {
        try validateModel(CppModelLoadRequest(
            engineID: manifest.engineID,
            modelID: manifest.id.modelID,
            modelFormat: manifest.modelFormat,
            artifactPathsByRole: Dictionary(uniqueKeysWithValues: artifactPathsByRole.map {
                ($0.key.rawValue, $0.value.path)
            }),
            contextTokens: manifest.loadTemplate.contextTokens,
            manifestLoadOptions: manifest.loadTemplate.manifestControlledOptions,
            template: manifest.chatTemplate,
            toolCallCodecID: manifest.toolCallCodecID
        ))
    }

    func validateModel(_ request: CppModelLoadRequest) throws {
        let engine = try makeEngine(request.engineID)
        defer { try? engine.close() }
        let data = try CppInferenceRequestEncoder.modelJSON(request)
        let status = try engine.withOpenPointer { pointer in
            String(decoding: data, as: UTF8.self).withCString {
                local_agent_model_validate(pointer, $0)
            }
        }
        try requireOK(status, engine: engine)
    }

    func load(_ request: CppModelLoadRequest) throws -> any CppLoadedModelAPI {
        let engine = try makeEngine(request.engineID)
        do {
            let data = try CppInferenceRequestEncoder.modelJSON(request)
            var model: OpaquePointer?
            let status = try engine.withOpenPointer { pointer in
                String(decoding: data, as: UTF8.self).withCString {
                    local_agent_model_load(pointer, $0, &model)
                }
            }
            try requireOK(status, engine: engine)
            guard let model else {
                throw nativeFailure(
                    code: "missing_model_handle",
                    retryable: false,
                    engineID: request.engineID
                )
            }
            return LiveCppLoadedModel(
                engineID: request.engineID,
                engine: engine,
                model: LockedNativeHandle(pointer: model) { pointer in
                    resultFromStatus(
                        local_agent_model_unload(pointer),
                        operation: "model_unload"
                    )
                }
            )
        } catch {
            try? engine.close()
            throw error
        }
    }

    private func makeEngine(_ engineID: String) throws -> LockedNativeHandle {
        var pointer: OpaquePointer?
        let status = engineID.withCString { local_agent_engine_create($0, &pointer) }
        guard status == LOCAL_AGENT_STATUS_OK else {
            throw failureFromNative(status: status, engine: nil, fallbackOperation: "engine_create")
        }
        guard let pointer else {
            throw nativeFailure(code: "missing_engine_handle", retryable: false, engineID: engineID)
        }
        return LockedNativeHandle(pointer: pointer) { pointer in
            resultFromStatus(local_agent_engine_release(pointer), operation: "engine_release")
        }
    }
}

private final class LiveCppLoadedModel: CppLoadedModelAPI, @unchecked Sendable {
    private let engineID: String
    private let engine: LockedNativeHandle
    private let model: LockedNativeHandle

    init(engineID: String, engine: LockedNativeHandle, model: LockedNativeHandle) {
        self.engineID = engineID
        self.engine = engine
        self.model = model
    }

    func validateGeneration(_ request: CppGenerationRequest) throws {
        let data = try CppInferenceRequestEncoder.generationJSON(request)
        let status = try model.withOpenPointer { pointer in
            String(decoding: data, as: UTF8.self).withCString {
                local_agent_generation_validate(pointer, $0)
            }
        }
        try requireOK(status, engine: engine)
    }

    func start(_ request: CppGenerationRequest) throws -> any CppGenerationAPI {
        let data = try CppInferenceRequestEncoder.generationJSON(request)
        var generation: OpaquePointer?
        let status = try withNativeImages(request.attachments) { images, count in
            try model.withOpenPointer { pointer in
                String(decoding: data, as: UTF8.self).withCString {
                    local_agent_generation_start(pointer, $0, images, count, &generation)
                }
            }
        }
        try requireOK(status, engine: engine)
        guard let generation else {
            throw nativeFailure(code: "missing_generation_handle", retryable: false, engineID: engineID)
        }
        let live = LiveCppGeneration(
            engine: engine,
            handle: LockedNativeHandle(pointer: generation) { pointer in
                resultFromStatus(
                    local_agent_generation_release(pointer),
                    operation: "generation_release",
                    cancelledIsSuccess: true
                )
            }
        )
        live.startReading()
        return live
    }

    func unload() throws {
        try model.close()
        try engine.close()
    }
}

private final class LiveCppGeneration: CppGenerationAPI, @unchecked Sendable {
    private let engine: LockedNativeHandle
    private let handle: LockedNativeHandle
    private let channel = CppEventChannel(maxEventCount: 128, maxUTF8Bytes: 256 * 1024)
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    init(engine: LockedNativeHandle, handle: LockedNativeHandle) {
        self.engine = engine
        self.handle = handle
    }

    var events: CppTokenEventSequence { channel.sequence }

    func startReading() {
        let context = CppReadContext(channel: channel)
        Thread.detachNewThread { [engine, handle, channel] in
            let retained = Unmanaged.passRetained(context)
            defer { retained.release() }
            do {
                let status = try handle.withOpenPointer { pointer in
                    local_agent_generation_read(
                        pointer,
                        cppTokenCallback,
                        retained.toOpaque()
                    )
                }
                if status == LOCAL_AGENT_STATUS_OK {
                    channel.finish()
                } else if status == LOCAL_AGENT_STATUS_CANCELLED {
                    channel.cancel()
                } else if !context.hasDecodeFailure {
                    channel.fail(failureFromNative(
                        status: status,
                        engine: engine,
                        fallbackOperation: "generation_read"
                    ))
                }
            } catch let failure as LLMFailure {
                channel.fail(failure)
            } catch {
                channel.fail(nativeFailure(code: "generation_read_failed", retryable: true))
            }
        }
    }

    func cancel() throws {
        let shouldRequest = cancellationLock.withLock {
            guard !cancellationRequested else { return false }
            cancellationRequested = true
            return true
        }
        guard shouldRequest else { return }
        channel.cancel()
        let status = try handle.withOpenPointer(local_agent_generation_cancel)
        if status != LOCAL_AGENT_STATUS_OK, status != LOCAL_AGENT_STATUS_CANCELLED {
            throw failureFromNative(status: status, engine: engine, fallbackOperation: "generation_cancel")
        }
    }

    func release() throws {
        channel.cancel()
        try handle.close()
    }
}

private final class CppReadContext: @unchecked Sendable {
    let channel: CppEventChannel
    private let lock = NSLock()
    private var decodeFailure = false

    init(channel: CppEventChannel) {
        self.channel = channel
    }

    var hasDecodeFailure: Bool { lock.withLock { decodeFailure } }

    func receive(_ pointer: UnsafePointer<CChar>?) -> LocalAgentStatus {
        guard let pointer else { return failDecode() }
        do {
            let event = try JSONDecoder().decode(
                NativeTokenEvent.self,
                from: Data(String(cString: pointer).utf8)
            )
            let token: CppTokenEvent
            switch event.type {
            case "text_delta", "structured_delta":
                guard let text = event.text else { return failDecode() }
                token = .textDelta(text)
            case "usage":
                token = .usage(
                    inputTokens: event.promptTokens,
                    outputTokens: event.completionTokens
                )
            case "completed":
                token = .completed(rawFinishReason: "stop")
            default:
                return failDecode()
            }
            switch channel.send(token) {
            case .accepted: return LOCAL_AGENT_STATUS_OK
            case .cancelled, .closed: return LOCAL_AGENT_STATUS_CANCELLED
            }
        } catch {
            return failDecode()
        }
    }

    private func failDecode() -> LocalAgentStatus {
        lock.withLock { decodeFailure = true }
        channel.fail(nativeFailure(code: "event_decode_failed", retryable: false))
        return LOCAL_AGENT_STATUS_ERROR
    }
}

private let cppTokenCallback: local_agent_token_callback = { tokenJSON, userData in
    guard let userData else { return LOCAL_AGENT_STATUS_INVALID_ARGUMENT }
    return Unmanaged<CppReadContext>.fromOpaque(userData)
        .takeUnretainedValue()
        .receive(tokenJSON)
}

private struct NativeTokenEvent: Decodable {
    let type: String
    let text: String?
    let promptTokens: UInt64?
    let completionTokens: UInt64?

    enum CodingKeys: String, CodingKey {
        case type, text
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

private struct NativeErrorPayload: Decodable {
    let code: String
    let recoverable: Bool?
    let engine: String?
}

private func requireOK(
    _ status: LocalAgentStatus,
    engine: LockedNativeHandle
) throws {
    guard status == LOCAL_AGENT_STATUS_OK else {
        throw failureFromNative(status: status, engine: engine, fallbackOperation: "native_call")
    }
}

private func failureFromNative(
    status: LocalAgentStatus,
    engine: LockedNativeHandle?,
    fallbackOperation: String
) -> LLMFailure {
    if status == LOCAL_AGENT_STATUS_CANCELLED {
        return nativeFailure(code: "cancelled", retryable: false)
    }
    if status == LOCAL_AGENT_STATUS_INVALID_ARGUMENT {
        return nativeFailure(code: "invalid_argument", retryable: false)
    }
    var output: UnsafeMutablePointer<CChar>?
    let errorStatus: LocalAgentStatus
    if let engine {
        errorStatus = (try? engine.withOpenPointer {
            local_agent_last_error($0, &output)
        }) ?? LOCAL_AGENT_STATUS_ERROR
    } else {
        errorStatus = local_agent_last_error(nil, &output)
    }
    defer { if let output { local_agent_string_free(output) } }
    guard errorStatus == LOCAL_AGENT_STATUS_OK,
          let output,
          let payload = try? JSONDecoder().decode(
              NativeErrorPayload.self,
              from: Data(String(cString: output).utf8)
          )
    else {
        return nativeFailure(code: fallbackOperation + "_failed", retryable: false)
    }
    return nativeFailure(
        code: payload.code,
        retryable: payload.recoverable ?? false,
        engineID: payload.engine
    )
}

private func nativeFailure(
    code: String,
    retryable: Bool,
    engineID: String? = nil
) -> LLMFailure {
    let safeCode = code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        ? code
        : "native_failure"
    return LLMFailure(
        code: "local_engine.\(safeCode)",
        message: "The local inference engine could not complete the operation.",
        retryable: retryable,
        recoveryAction: retryable ? .retry : .chooseAnotherModel,
        redactedDiagnostics: engineID.map { ["engine_id": $0] } ?? [:]
    )
}

private func resultFromStatus(
    _ status: LocalAgentStatus,
    operation: String,
    cancelledIsSuccess: Bool = false
) -> Result<Void, LLMFailure> {
    if status == LOCAL_AGENT_STATUS_OK
        || cancelledIsSuccess && status == LOCAL_AGENT_STATUS_CANCELLED
    {
        return .success(())
    }
    return .failure(failureFromNative(
        status: status,
        engine: nil,
        fallbackOperation: operation
    ))
}

private func withNativeImages<T>(
    _ attachments: [LocalResolvedAttachment],
    operation: (UnsafePointer<LocalAgentImageInput>?, UInt64) throws -> T
) throws -> T {
    var byteBuffers: [UnsafeMutablePointer<UInt8>] = []
    var formatBuffers: [UnsafeMutablePointer<CChar>] = []
    defer {
        byteBuffers.forEach { $0.deallocate() }
        formatBuffers.forEach { free($0) }
    }
    var images: [LocalAgentImageInput] = []
    for attachment in attachments {
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: attachment.rgb8.count)
        attachment.rgb8.copyBytes(to: bytes, count: attachment.rgb8.count)
        byteBuffers.append(bytes)
        guard let format = strdup("rgb8") else {
            throw nativeFailure(code: "image_allocation_failed", retryable: true)
        }
        formatBuffers.append(format)
        images.append(LocalAgentImageInput(
            bytes: UnsafePointer(bytes),
            byte_count: UInt64(attachment.rgb8.count),
            width: attachment.width,
            height: attachment.height,
            pixel_format: UnsafePointer(format)
        ))
    }
    return try images.withUnsafeBufferPointer { buffer in
        try operation(buffer.baseAddress, UInt64(buffer.count))
    }
}

public enum LocalInferenceNativeRegistry {
    public static func releaseEngineIDs() throws -> [String] {
        try CppInferenceRegistry.live.listEngines().map(\.engineID).sorted()
    }
}

/// A link-time probe used by the App integration target. Keeping every C ABI
/// entry point in one referenced tuple makes the final test host prove that the
/// sole XCFramework slice, including its vendor objects, resolves the complete
/// boundary rather than only the registry function exercised by Task 1.
public enum LocalInferenceNativeLinkProbe {
    @inline(never)
    public static func requireAllExports() {
        precondition(
            local_agent_link_anchor() == 15,
            "Local inference C ABI final-link anchor is incomplete"
        )
    }
}
