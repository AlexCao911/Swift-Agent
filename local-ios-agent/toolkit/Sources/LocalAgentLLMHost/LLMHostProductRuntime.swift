import Foundation
import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore
import LocalAgentLLMLocal

public protocol LLMProductRunStarting: Sendable {
    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO
}

extension RustExecutionBridgeClient: LLMProductRunStarting {}

public struct LLMProductRunRouter: LLMProductRunStarting {
    private let routes: any ProfileExecutionRouteClient
    private let legacy: any LLMProductRunStarting
    private let host: any LLMProductRunStarting

    public init(
        routes: any ProfileExecutionRouteClient,
        legacy: any LLMProductRunStarting,
        host: any LLMProductRunStarting
    ) {
        self.routes = routes
        self.legacy = legacy
        self.host = host
    }

    public func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        let route = try await routes.profileExecutionRoute(
            profileID: request.agentProfileId,
            profileRevision: request.profileRevisionId
        )
        guard route.profileID == request.agentProfileId,
              route.profileRevision == request.profileRevisionId
        else {
            throw LLMHostFailure(
                code: "execution.profile_route_stale",
                message: "Rust returned a route for a different profile revision"
            )
        }
        switch route.llmBindingSchema {
        case .legacyV1:
            return try await legacy.startRun(request)
        case .hostSlotV2:
            return try await host.startRun(request)
        }
    }

    public func start(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        try await startRun(request)
    }
}

public final class LLMHostProductRuntime: @unchecked Sendable {
    public let hostProcessEpoch: HostProcessEpoch
    private let rust: RustRuntimeClient
    private let runtime: LLMHostRuntime
    private let port: RustLLMHostPort

    private init(
        rust: RustRuntimeClient,
        runtime: LLMHostRuntime,
        port: RustLLMHostPort,
        hostProcessEpoch: HostProcessEpoch
    ) {
        self.rust = rust
        self.runtime = runtime
        self.port = port
        self.hostProcessEpoch = hostProcessEpoch
    }

    public static func bootstrap(
        rust: RustRuntimeClient,
        hostProcessEpoch: HostProcessEpoch
    ) async throws -> LLMHostProductRuntime {
        let sink = RustPortHostSink(rust: rust)
        let runtime = LLMHostRuntime(
            hostProcessEpoch: hostProcessEpoch,
            rustSink: sink
        )
        let port = try rust.installLLMHost { bytes in
            switch runtime.copy(bytes) {
            case .copied: .copied
            case .backpressure: .backpressure
            case .hostUnavailable: .hostUnavailable
            }
        }
        await sink.attach(port)
        return LLMHostProductRuntime(
            rust: rust,
            runtime: runtime,
            port: port,
            hostProcessEpoch: hostProcessEpoch
        )
    }

    public func startLocal(
        _ request: StartExecutionRequestDTO,
        subsystem: LocalLLMSubsystem,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) async throws -> RunHandleDTO {
        try validateExactBinding(request, configuration: configuration, target: target)
        guard subsystem.hostProcessEpoch == hostProcessEpoch else {
            throw wrongEpoch()
        }
        let ids = try newRunIDs()
        let bridge = LLMRunPreparationBridge(
            rust: RustGatewayRunPreparationClient(gateway: rust),
            registry: runtime.bridgeActor,
            reserver: LocalHostSessionReserver(
                runtime: subsystem.runtime,
                configuration: configuration,
                target: target
            ),
            nowMillis: Self.nowMillis
        )
        return try await bridge.prepareAndCommit(
            startRequest: previewRequest(request, ids: ids)
        ).runHandle
    }

    public func startCloud(
        _ request: StartExecutionRequestDTO,
        subsystem: CloudLLMSubsystem,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision,
        context: @Sendable (String, String) throws -> CloudSessionPreparationContext
    ) async throws -> RunHandleDTO {
        try validateExactBinding(request, configuration: configuration, target: target)
        guard subsystem.hostProcessEpoch == hostProcessEpoch else {
            throw wrongEpoch()
        }
        let ids = try newRunIDs()
        let bridge = LLMRunPreparationBridge(
            rust: RustGatewayRunPreparationClient(gateway: rust),
            registry: runtime.bridgeActor,
            reserver: CloudHostSessionReserver(
                runtime: subsystem.runtime,
                context: try context(ids.preparationID, ids.proposedRunID),
                configuration: configuration,
                target: target
            ),
            nowMillis: Self.nowMillis
        )
        return try await bridge.prepareAndCommit(
            startRequest: previewRequest(request, ids: ids)
        ).runHandle
    }

    public func suspend() throws {
        try port.suspend()
    }

    public func resume() throws {
        try port.resume()
    }

    public func shutdown() throws {
        runtime.beginQuiescing()
        try port.close()
    }

    private func previewRequest(
        _ request: StartExecutionRequestDTO,
        ids: (preparationID: String, proposedRunID: String)
    ) -> PreviewRunPreparationRequestDTO {
        PreviewRunPreparationRequestDTO(
            idempotencyKey: "preview:\(ids.preparationID)",
            preparationId: ids.preparationID,
            proposedRunId: ids.proposedRunID,
            startRequest: AuthoritativePreparationStartRequestDTO(
                agentProfileId: request.agentProfileId,
                profileRevisionId: request.profileRevisionId,
                userIntent: request.userIntent,
                conversationRunFrameRef: request.conversationRunFrameRef
            ),
            nowMillis: Self.nowMillis()
        )
    }

    private func newRunIDs() throws -> (preparationID: String, proposedRunID: String) {
        (
            "preparation-\(try HostSessionHandleGenerator.generate())",
            "run-\(try HostSessionHandleGenerator.generate())"
        )
    }

    private func validateExactBinding(
        _ request: StartExecutionRequestDTO,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) throws {
        guard configuration.agentProfileID == request.agentProfileId,
              configuration.agentProfileRevision == request.profileRevisionId,
              configuration.selectedTarget == target.reference
        else {
            throw LLMHostFailure(
                code: "execution.host_binding_mismatch",
                message: "host selection does not match the exact Rust route revision"
            )
        }
    }

    private func wrongEpoch() -> LLMHostFailure {
        LLMHostFailure(
            code: "llm.host.wrong_epoch",
            message: "Rust and Swift LLM subsystems use different host epochs"
        )
    }

    private static func nowMillis() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000)
    }
}

private extension HostRunHandleDTO {
    var runHandle: RunHandleDTO {
        RunHandleDTO(runId: runID, replayFromSequence: 0)
    }
}

private actor RustPortHostSink: LLMHostRustSink {
    private let rust: RustRuntimeClient
    private var port: RustLLMHostPort?

    init(rust: RustRuntimeClient) {
        self.rust = rust
    }

    func attach(_ port: RustLLMHostPort) {
        self.port = port
    }

    func submit(_ envelope: LLMEventEnvelope) async throws -> LLMEventSubmissionResult {
        let port = try requirePort()
        let response = try port.submitEventJSON(JSONEncoder().encode(envelope))
        return try JSONDecoder().decode(LLMEventSubmissionResult.self, from: response)
    }

    func submitCommandAcknowledgement(
        _ acknowledgement: HostCommandAcknowledgement
    ) async -> Bool {
        await submitReceipt {
            try $0.submitCommandAcknowledgementJSON(
                JSONEncoder().encode(acknowledgement)
            )
        }
    }

    func acknowledgePreparedSessionCleanup(
        _ acknowledgement: PreparedSessionCleanupAcknowledgementDTO
    ) async -> Bool {
        do {
            _ = try await rust.request(
                .ackPreparedSessionCleanup,
                acknowledgement,
                as: RunPreparationRecordDTO.self
            )
            return true
        } catch {
            return false
        }
    }

    func confirmPreparedSessionClosed(
        _ receipt: PreparedSessionClosedReceiptDTO
    ) async -> Bool {
        do {
            _ = try await rust.request(
                .confirmPreparedSessionClosed,
                receipt,
                as: RunPreparationRecordDTO.self
            )
            return true
        } catch {
            return false
        }
    }

    private func submitReceipt(
        _ body: (RustLLMHostPort) throws -> Data
    ) async -> Bool {
        guard let port else { return false }
        do {
            _ = try body(port)
            return true
        } catch {
            return false
        }
    }

    private func requirePort() throws -> RustLLMHostPort {
        guard let port else {
            throw LLMHostFailure(
                code: "llm.host.port_unavailable",
                message: "Rust host port is not installed"
            )
        }
        return port
    }
}
