import Foundation
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore
import LocalAgentLLMLocal

public enum RustReActResolvedAttachmentContent: Equatable, Sendable {
    case text(String)
    case imageRGB8(Data, width: UInt32, height: UInt32)
    case opaque
}

public struct RustReActResolvedAttachment: Equatable, Sendable {
    public let reference: HostAttachmentReference
    public let content: RustReActResolvedAttachmentContent

    public init(
        reference: HostAttachmentReference,
        content: RustReActResolvedAttachmentContent
    ) {
        self.reference = reference
        self.content = content
    }
}

public protocol RustReActAttachmentResolving: Sendable {
    func resolve(
        _ references: [HostAttachmentReference]
    ) async throws -> [RustReActResolvedAttachment]
}

public struct EmptyRustReActAttachmentResolver: RustReActAttachmentResolving {
    public init() {}

    public func resolve(
        _ references: [HostAttachmentReference]
    ) async throws -> [RustReActResolvedAttachment] {
        guard references.isEmpty else {
            throw routeFailure(
                "model_route.attachment_resolver_unavailable",
                "the attachment store is unavailable"
            )
        }
        return []
    }
}

public actor RustReActModelRoute: ModelGenerationExecuting {
    private enum Backend: Sendable {
        case local(
            runtime: LocalModelRuntime,
            configuration: AgentHostConfiguration,
            target: LLMTargetRevision
        )
        case cloud(
            runtime: CloudLLMRuntime,
            configuration: AgentHostConfiguration,
            target: LLMTargetRevision
        )
    }

    private enum Session {
        case local(String)
        case cloud(String)
    }

    private let runID: String
    private let backend: Backend
    private let attachmentResolver: any RustReActAttachmentResolving
    private var session: Session?
    private var awaitingToolResults = false
    private var turn = 0
    private var cloudParameters: GenerationConfiguration?

    public init(
        runID: String,
        local: LocalLLMSubsystem,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision,
        attachmentResolver: any RustReActAttachmentResolving =
            EmptyRustReActAttachmentResolver()
    ) {
        self.runID = runID
        self.attachmentResolver = attachmentResolver
        backend = .local(
            runtime: local.runtime,
            configuration: configuration,
            target: target
        )
    }

    public init(
        runID: String,
        cloud: CloudLLMSubsystem,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision,
        attachmentResolver: any RustReActAttachmentResolving =
            EmptyRustReActAttachmentResolver()
    ) {
        self.runID = runID
        self.attachmentResolver = attachmentResolver
        backend = .cloud(
            runtime: cloud.runtime,
            configuration: configuration,
            target: target
        )
    }

    public func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        guard request.runID == runID else {
            throw routeFailure(
                "model_route.run_mismatch",
                "the model request does not belong to this frozen run"
            )
        }
        if case .compaction = request.purpose, session != nil {
            try await closeSession()
        }
        let attachments = session == nil
            ? try await attachmentResolver.resolve(request.attachmentReferences)
            : []

        let completion: LLMBackendCompletion
        switch backend {
        case let .local(runtime, configuration, target):
            completion = try await generateLocal(
                request,
                runtime: runtime,
                configuration: configuration,
                target: target,
                attachments: attachments,
                emit: emit
            )
        case let .cloud(runtime, configuration, target):
            completion = try await generateCloud(
                request,
                runtime: runtime,
                configuration: configuration,
                target: target,
                attachments: attachments,
                emit: emit
            )
        }
        awaitingToolResults = completion.outcome == .toolCallsReady

        if case .compaction = request.purpose {
            try await closeSession()
        }
    }

    public func cancel(runID: String) async {
        guard runID == self.runID, let session else { return }
        switch (backend, session) {
        case let (.local(runtime, _, _), .local(sessionID)):
            try? await runtime.cancel(sessionID: sessionID)
        case let (.cloud(runtime, _, _), .cloud(sessionID)):
            try? await runtime.cancel(sessionID: sessionID)
        default:
            break
        }
    }

    public func finish(runID: String) async {
        guard runID == self.runID else { return }
        try? await closeSession()
    }

    private func generateLocal(
        _ request: HostModelRequest,
        runtime: LocalModelRuntime,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision,
        attachments: [RustReActResolvedAttachment],
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws -> LLMBackendCompletion {
        let sessionID: String
        let events: LLMBackendEventSequence
        if let session {
            guard case let .local(existingID) = session,
                  awaitingToolResults,
                  !request.orderedToolResults.isEmpty
            else {
                throw routeFailure(
                    "model_route.local_continuation_invalid",
                    "the local model session is not awaiting this tool batch"
                )
            }
            sessionID = existingID
            events = try await runtime.resumeGeneration(
                sessionID: sessionID,
                input: try rustReActInput(request, includeContext: false),
                attachments: [],
                toolSchema: try rustReActToolSchema(request)
            )
        } else {
            let digest = try rustReActRequestDigest(request)
            let reserved = try await runtime.reserveSession(
                context: LocalSessionPreparationContext(
                    preparationID: "rust-react:\(runID)",
                    proposedRunID: runID,
                    initialDisclosureDigest: digest,
                    capabilityAttestationDigest: digest,
                    attestationExpiresAt: hostAttestationExpiration(
                        UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
                    )
                ),
                hostConfiguration: configuration,
                target: target
            )
            let prepared = try await runtime.openReservedSession(reserved)
            sessionID = prepared.sessionID
            session = .local(sessionID)
            events = try await runtime.startGeneration(
                sessionID: sessionID,
                input: try rustReActInput(
                    request,
                    includeContext: true,
                    resolvedAttachments: attachments
                ),
                attachments: localResolvedAttachments(attachments),
                toolSchema: try rustReActToolSchema(request)
            )
        }
        return try await pump(events, emit: emit)
    }

    private func generateCloud(
        _ request: HostModelRequest,
        runtime: CloudLLMRuntime,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision,
        attachments: [RustReActResolvedAttachment],
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws -> LLMBackendCompletion {
        let parameters: GenerationConfiguration
        if let cloudParameters {
            parameters = cloudParameters
        } else {
            parameters = try await runtime.resolvedGenerationConfiguration(
                hostConfiguration: configuration,
                target: target
            )
            cloudParameters = parameters
        }

        let sessionID: String
        let events: LLMBackendEventStream
        if let session {
            guard case let .cloud(existingID) = session,
                  awaitingToolResults,
                  !request.orderedToolResults.isEmpty
            else {
                throw routeFailure(
                    "model_route.cloud_continuation_invalid",
                    "the cloud model session is not awaiting this tool batch"
                )
            }
            sessionID = existingID
            events = try await runtime.resumeGeneration(
                sessionID: sessionID,
                turn: try cloudTurn(
                    request,
                    parameters: parameters,
                    includeContext: false,
                    includeToolResults: true,
                    attachments: []
                )
            )
        } else {
            let initial = try cloudTurn(
                request,
                parameters: parameters,
                includeContext: true,
                includeToolResults: false,
                attachments: attachments
            )
            let prepared = try await runtime.prepareSession(
                context: CloudSessionPreparationContext(
                    preparationID: "rust-react:\(runID)",
                    proposedRunID: runID,
                    initialTurn: initial,
                    signedToolDisplayKeys: Set(
                        request.orderedToolDefinitions.map(\.name)
                    )
                ),
                hostConfiguration: configuration,
                target: target
            )
            sessionID = prepared.sessionID
            session = .cloud(sessionID)
            events = try await runtime.startGeneration(
                sessionID: sessionID,
                turn: initial
            )
        }
        return try await pump(events, emit: emit)
    }

    private func cloudTurn(
        _ request: HostModelRequest,
        parameters: GenerationConfiguration,
        includeContext: Bool,
        includeToolResults: Bool,
        attachments: [RustReActResolvedAttachment]
    ) throws -> CloudGenerationTurnRequest {
        turn += 1
        let input = try rustReActInput(
            request,
            includeContext: includeContext,
            resolvedAttachments: attachments
        )
        let tools = try rustReActToolSchema(request)
        let results = includeToolResults
            ? try rustReActToolResults(request.orderedToolResults)
            : []
        let sources = try CanonicalJSONValue.object(entries: [])
        let history = CanonicalJSONValue.array([])
        let summary = safeSummary(input: input, results: results)
        let placeholder = GenerationDisclosure(
            schemaVersion: "1",
            generationTurnID: "\(runID):turn:\(turn)",
            contentDigest: String(repeating: "0", count: 64),
            sourceRevisionDigest: String(repeating: "0", count: 64),
            dataClasses: summary.dataClasses,
            highestSensitivity: summary.sensitivity,
            safeDisplaySummary: summary.display
        )
        let candidate = CloudGenerationTurnCandidate(
            input: input,
            canonicalToolSchema: tools,
            sourceRevisionDocument: sources,
            resolvedAttachments: [],
            toolResults: results,
            providerRequiredSemanticHistory: history,
            disclosure: placeholder,
            resolvedParameters: parameters
        )
        let validator = CloudSemanticTurnValidator()
        let disclosure = GenerationDisclosure(
            schemaVersion: "1",
            generationTurnID: placeholder.generationTurnID,
            contentDigest: try validator.contentDigest(candidate).hex,
            sourceRevisionDigest: try validator.sourceRevisionDigest(candidate).hex,
            dataClasses: summary.dataClasses,
            highestSensitivity: summary.sensitivity,
            safeDisplaySummary: summary.display
        )
        return CloudGenerationTurnRequest(
            input: input,
            canonicalToolSchema: tools,
            sourceRevisionDocument: sources,
            toolResults: results,
            providerRequiredSemanticHistory: history,
            disclosure: disclosure,
            resolvedParameters: parameters
        )
    }

    private func closeSession() async throws {
        guard let session else { return }
        self.session = nil
        awaitingToolResults = false
        switch (backend, session) {
        case let (.local(runtime, _, _), .local(sessionID)):
            try await runtime.closeSession(sessionID: sessionID)
        case let (.cloud(runtime, _, _), .cloud(sessionID)):
            try await runtime.closeSession(sessionID: sessionID)
        default:
            throw routeFailure(
                "model_route.session_mismatch",
                "the provider session does not match the frozen route"
            )
        }
    }
}

package func rustReActInput(
    _ request: HostModelRequest,
    includeContext: Bool,
    resolvedAttachments: [RustReActResolvedAttachment] = []
) throws -> AgentLLMInput {
    guard request.attachmentReferences == resolvedAttachments.map(\.reference) else {
        throw routeFailure(
            "model_route.attachment_mismatch",
            "resolved attachments do not match the ordered Rust references"
        )
    }
    guard includeContext else {
        return AgentLLMInput(inputID: request.runID, messages: [])
    }
    var messages = [
        LLMInputMessage(role: .system, content: [.text(request.systemPrompt)]),
    ]
    messages.append(contentsOf: try request.orderedMessages.map { message in
        let role: LLMInputRole
        switch message.role {
        case "system", "summary": role = .system
        case "user": role = .user
        case "assistant": role = .assistant
        case "tool": role = .user
        default:
            throw routeFailure(
                "model_route.message_role_invalid",
                "Rust supplied an unsupported model message role"
            )
        }
        let text: String
        if case let .string(value) = message.content {
            text = message.role == "tool" ? "[tool result]\n\(value)" : value
        } else {
            text = String(
                decoding: try CanonicalDigestV1.canonicalize(message.content),
                as: UTF8.self
            )
        }
        return LLMInputMessage(role: role, content: [.text(text)])
    })
    if !resolvedAttachments.isEmpty {
        messages.append(LLMInputMessage(
            role: .user,
            content: resolvedAttachments.map { attachment in
                switch attachment.content {
                case let .text(text):
                    .text(
                        "[Attachment: \(attachment.reference.displayName) "
                            + "(\(attachment.reference.mediaType))]\n\(text)"
                    )
                case .imageRGB8:
                    .attachment(
                        modality: .image,
                        attachmentID: attachment.reference.attachmentID,
                        mediaType: "image/rgb8"
                    )
                case .opaque:
                    .text(
                        "[Attachment: \(attachment.reference.displayName) "
                            + "(\(attachment.reference.mediaType)); "
                            + "binary content is available to tools]"
                    )
                }
            }
        ))
    }
    return AgentLLMInput(inputID: request.runID, messages: messages)
}

package func localResolvedAttachments(
    _ attachments: [RustReActResolvedAttachment]
) -> [LocalResolvedAttachment] {
    attachments.compactMap { attachment in
        guard case let .imageRGB8(data, width, height) = attachment.content else {
            return nil
        }
        return LocalResolvedAttachment(
            attachmentID: attachment.reference.attachmentID,
            rgb8: data,
            width: width,
            height: height
        )
    }
}

package func rustReActToolSchema(
    _ request: HostModelRequest
) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(
            name: "tools",
            value: .array(try request.orderedToolDefinitions.map { tool in
                try .object(entries: [
                    .init(name: "description", value: .string(tool.description)),
                    .init(name: "name", value: .string(tool.name)),
                    .init(name: "parameters", value: tool.inputSchema),
                ])
            })
        ),
    ])
}

package func rustReActToolResults(
    _ results: [HostToolResult]
) throws -> [NormalizedToolResult] {
    results.map { result in
        let classes = Set(result.dataClasses.compactMap(EgressDataClass.init(rawValue:)))
        let sensitivity: DataSensitivity
        switch result.highestSensitivity {
        case "public", "routine": sensitivity = .routine
        case "private": sensitivity = .private
        case "sensitive": sensitivity = .sensitive
        case "secret", "highly_sensitive": sensitivity = .highlySensitive
        default: sensitivity = .unknown
        }
        return NormalizedToolResult(
            callID: result.callID,
            toolName: result.toolName,
            result: result.result,
            isError: result.isError,
            dataClasses: classes.count == result.dataClasses.count
                ? classes
                : classes.union([.unknownData]),
            highestSensitivity: sensitivity
        )
    }
}

private func rustReActRequestDigest(
    _ request: HostModelRequest
) throws -> String {
    let data = try JSONEncoder().encode(request)
    let document = try JSONDecoder().decode(CanonicalJSONValue.self, from: data)
    return try CanonicalDigestV1.digest(
        domain: "agent-input:v1",
        document: document
    ).hex
}

private func pump<S: AsyncSequence>(
    _ events: S,
    emit: @escaping @Sendable (HostModelEvent) async throws -> Void
) async throws -> LLMBackendCompletion where S.Element == LLMBackendEvent {
    var names: [String: String] = [:]
    var arguments: [String: String] = [:]
    var completion: LLMBackendCompletion?

    for try await event in events {
        switch event {
        case .generationStarted:
            break
        case let .textDelta(text):
            try await emit(.textDelta(text))
        case let .reasoningSummaryDelta(text):
            try await emit(.reasoningDelta(text))
        case let .toolCallStarted(callID, name):
            names[callID] = name
        case let .toolCallArgumentsDelta(callID, delta):
            guard let name = names[callID] else {
                throw routeFailure(
                    "model_route.tool_stream_invalid",
                    "tool arguments arrived before the tool identity"
                )
            }
            arguments[callID, default: ""] += delta
            try await emit(.toolCallDelta(
                callID: callID,
                toolName: name,
                argumentsFragment: delta
            ))
        case let .toolCallCompleted(call):
            let emitted = arguments[call.callID, default: ""]
            guard emitted.isEmpty || call.argumentsJSON.hasPrefix(emitted) else {
                throw routeFailure(
                    "model_route.tool_stream_invalid",
                    "tool argument fragments do not match the completed call"
                )
            }
            names[call.callID] = call.name
            let remaining = String(call.argumentsJSON.dropFirst(emitted.count))
            if !remaining.isEmpty {
                try await emit(.toolCallDelta(
                    callID: call.callID,
                    toolName: call.name,
                    argumentsFragment: remaining
                ))
            }
        case let .usageUpdated(usage):
            try await emit(.usage(try .object(entries: [
                .init(
                    name: "input_tokens",
                    value: usage.inputTokens.map { .number(Double($0)) } ?? .null
                ),
                .init(
                    name: "output_tokens",
                    value: usage.outputTokens.map { .number(Double($0)) } ?? .null
                ),
            ])))
        case let .generationCompleted(value):
            completion = value
        case let .failed(failure):
            throw routeFailure(
                failure.code.rawValue,
                "the selected model failed this generation"
            )
        case .cancelled:
            throw CancellationError()
        case .sessionClosed:
            break
        }
    }
    guard let completion else {
        throw routeFailure(
            "stream_interrupted",
            "the selected model ended without a terminal completion"
        )
    }
    return completion
}

private func safeSummary(
    input: AgentLLMInput,
    results: [NormalizedToolResult]
) -> (
    dataClasses: Set<EgressDataClass>,
    sensitivity: DataSensitivity,
    display: SafeDisplaySummary
) {
    var dataClasses = results.reduce(into: Set<EgressDataClass>()) {
        $0.formUnion($1.dataClasses)
    }
    var sensitivity = results.map(\.highestSensitivity).max() ?? .routine
    if !input.messages.isEmpty {
        dataClasses.insert(.unknownData)
        sensitivity = .unknown
    }
    if dataClasses.isEmpty {
        dataClasses.insert(.unknownData)
        sensitivity = .unknown
    }
    let byteCount = input.messages.reduce(0) { total, message in
        total + message.content.reduce(0) { subtotal, content in
            switch content {
            case let .text(text): subtotal + text.utf8.count
            case .attachment: subtotal
            }
        }
    }
    let size: EgressSizeBucket = switch byteCount {
    case 0: .none
    case 1..<1_024: .lessThanOneKiB
    case 1_024..<102_400: .oneToOneHundredKiB
    case 102_400..<1_048_576: .oneHundredKiBToOneMiB
    default: .greaterThanOneMiB
    }
    return (
        dataClasses,
        sensitivity,
        SafeDisplaySummary(
            sourceKinds: results.isEmpty
                ? [.conversation]
                : [.conversation, .toolResult],
            addedItemCounts: dataClasses.map {
                EgressDataClassCount(dataClass: $0, count: 1)
            },
            approximateAddedSize: size,
            triggeringToolDisplayKeys: Set(results.map(\.toolName))
        )
    )
}

private func routeFailure(_ code: String, _ message: String) -> LLMHostFailure {
    LLMHostFailure(code: code, message: message)
}
