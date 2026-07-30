import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import Security

package struct LLMHostRuntimeError: Error, Equatable, Sendable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

package enum HostSessionLifecycle: String, Equatable, Sendable {
    case allocated
    case registrationInFlight
    case registeredNotOpen
    case opening
    case openedAwaitingCommit
    case commitInFlight
    case commitOutcomeUnknown
    case committed
    case closing
    case quarantined
    case closed
}

package enum HostSessionHandleGenerator {
    package static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw LLMHostRuntimeError(
                code: "llm.host.random_generation_failed",
                message: "could not generate a host session handle"
            )
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

package struct AllocatedHostSession: Sendable {
    package let sessionHandle: String
    package let preparationID: String
    package let proposedRunID: String
    package let swiftSnapshotID: String
    package let bindingHash: String
    package let hostProcessEpoch: HostProcessEpoch
    package let preparedSessionRegistrationDigest: String
    package let cleanupOwner: PreparedSessionCleanupOwner

    package init(
        sessionHandle: String,
        preparationID: String,
        proposedRunID: String,
        swiftSnapshotID: String,
        bindingHash: String,
        hostProcessEpoch: HostProcessEpoch,
        preparedSessionRegistrationDigest: String,
        cleanupOwner: PreparedSessionCleanupOwner
    ) {
        self.sessionHandle = sessionHandle
        self.preparationID = preparationID
        self.proposedRunID = proposedRunID
        self.swiftSnapshotID = swiftSnapshotID
        self.bindingHash = bindingHash
        self.hostProcessEpoch = hostProcessEpoch
        self.preparedSessionRegistrationDigest = preparedSessionRegistrationDigest
        self.cleanupOwner = cleanupOwner
    }
}

package protocol LLMHostRustSink: LLMEventSubmitting {
    func submitCommandAcknowledgement(
        _ acknowledgement: HostCommandAcknowledgement
    ) async -> Bool

    func acknowledgePreparedSessionCleanup(
        _ acknowledgement: PreparedSessionCleanupAcknowledgementDTO
    ) async -> Bool

    func confirmPreparedSessionClosed(
        _ receipt: PreparedSessionClosedReceiptDTO
    ) async -> Bool
}

private struct CommandIdentity: Equatable {
    let commandID: String
    let commandEnvelopeDigest: String
}

private struct CommandLedgerRecord {
    let identity: CommandIdentity
    let result: Task<HostCommandAcknowledgement, Never>
}

private enum CommandLedgerClaim {
    case next
    case duplicate(Task<HostCommandAcknowledgement, Never>)
    case conflict
    case gap
}

private struct HostCommandLedger {
    private(set) var nextSequence: UInt64 = 1
    private var records: [UInt64: CommandLedgerRecord] = [:]

    func claim(_ command: HostCommandEnvelope) -> CommandLedgerClaim {
        if command.commandSequence > nextSequence {
            return .gap
        }
        if command.commandSequence < nextSequence {
            guard let record = records[command.commandSequence] else {
                return .conflict
            }
            let identity = CommandIdentity(
                commandID: command.commandID,
                commandEnvelopeDigest: command.commandEnvelopeDigest
            )
            return record.identity == identity
                ? .duplicate(record.result)
                : .conflict
        }
        return .next
    }

    mutating func record(
        _ command: HostCommandEnvelope,
        result: Task<HostCommandAcknowledgement, Never>
    ) {
        precondition(command.commandSequence == nextSequence)
        records[command.commandSequence] = CommandLedgerRecord(
            identity: CommandIdentity(
                commandID: command.commandID,
                commandEnvelopeDigest: command.commandEnvelopeDigest
            ),
            result: result
        )
        nextSequence += 1
    }
}

private struct CleanupOperation {
    let command: HostPreparedSessionCleanupCommand
    let result: Task<CleanupOperationResult, Never>
}

private enum CleanupOperationResult: Sendable {
    case success(
        PreparedSessionCleanupAcknowledgementDTO,
        PreparedSessionClosedReceiptDTO
    )
    case digestFailure
}

private struct HostSessionEntry {
    let allocation: AllocatedHostSession
    var lifecycle: HostSessionLifecycle
    var driver: (any LLMHostSessionDriver)?
    var commandLedger = HostCommandLedger()
    let eventSequencer: LLMEventSequencer
    var generationTask: Task<Void, Never>?
    var activeGenerationTurnID: String?
    var cleanupOperation: CleanupOperation?
}

private struct ClosedSessionTombstone {
    let allocation: AllocatedHostSession
    let cleanupCommand: HostPreparedSessionCleanupCommand?
    let cleanupAcknowledgement: PreparedSessionCleanupAcknowledgementDTO?
    let closeReceipt: PreparedSessionClosedReceiptDTO?
}

package actor LLMBridgeActor {
    private let inbox: BoundedHostCommandInbox
    private let hostProcessEpoch: HostProcessEpoch
    private let rustSink: any LLMHostRustSink
    private let modelHandler: ModelRuntimeCommandHandler?
    private let toolHandler: ToolBatchCommandHandler?
    private let operationStartTimeout: Duration
    private var sessions: [String: HostSessionEntry] = [:]
    private var tombstones: [String: ClosedSessionTombstone] = [:]
    private var drainTask: Task<Void, Never>?

    package init(
        inbox: BoundedHostCommandInbox,
        hostProcessEpoch: HostProcessEpoch,
        rustSink: any LLMHostRustSink,
        modelExecutor: (any ModelGenerationExecuting)? = nil,
        toolExecutor: (any ToolBatchExecuting)? = nil,
        operationStartTimeout: Duration
    ) {
        self.inbox = inbox
        self.hostProcessEpoch = hostProcessEpoch
        self.rustSink = rustSink
        modelHandler = modelExecutor.map(ModelRuntimeCommandHandler.init)
        toolHandler = toolExecutor.map(ToolBatchCommandHandler.init)
        self.operationStartTimeout = operationStartTimeout
    }

    package func allocate(_ session: AllocatedHostSession) throws {
        guard session.hostProcessEpoch == hostProcessEpoch else {
            throw failure(
                "llm.host.wrong_epoch",
                "allocated session uses a different host process epoch"
            )
        }
        guard tombstones[session.sessionHandle] == nil else {
            throw failure(
                "llm.host.session_handle_reused",
                "closed session handles cannot be reused within an epoch"
            )
        }
        guard sessions[session.sessionHandle] == nil else {
            throw failure(
                "llm.host.session_handle_conflict",
                "session handle is already allocated"
            )
        }
        guard sessions.isEmpty else {
            throw failure(
                "llm.host.concurrent_session_forbidden",
                "V1 permits only one active host session"
            )
        }
        sessions[session.sessionHandle] = HostSessionEntry(
            allocation: session,
            lifecycle: .allocated,
            driver: nil,
            eventSequencer: LLMEventSequencer(
                runID: session.proposedRunID,
                sessionHandle: session.sessionHandle,
                hostProcessEpoch: session.hostProcessEpoch,
                submitter: rustSink
            )
        )
    }

    package func beginRegistration(_ handle: String) throws {
        try transition(handle, from: [.allocated], to: .registrationInFlight)
    }

    package func markRegistered(_ handle: String) throws {
        try transition(handle, from: [.registrationInFlight], to: .registeredNotOpen)
    }

    package func beginOpen(_ handle: String) throws {
        try transition(handle, from: [.registeredNotOpen], to: .opening)
    }

    package func installOpenedDriver(
        _ driver: any LLMHostSessionDriver,
        for handle: String
    ) throws {
        var entry = try session(handle)
        guard entry.lifecycle == .opening else {
            throw invalidTransition(entry.lifecycle, to: .openedAwaitingCommit)
        }
        entry.driver = driver
        entry.lifecycle = .openedAwaitingCommit
        sessions[handle] = entry
    }

    package func markOpenedAwaitingCommit(_ handle: String) throws {
        try transition(handle, from: [.opening], to: .openedAwaitingCommit)
    }

    package func beginCommit(_ handle: String) throws {
        try transition(handle, from: [.openedAwaitingCommit], to: .commitInFlight)
    }

    package func markCommitOutcomeUnknown(_ handle: String) throws {
        if try session(handle).lifecycle == .committed {
            return
        }
        try transition(handle, from: [.commitInFlight], to: .commitOutcomeUnknown)
    }

    package func markCommitted(_ handle: String) throws {
        if try session(handle).lifecycle == .committed {
            return
        }
        try transition(
            handle,
            from: [.commitInFlight, .commitOutcomeUnknown],
            to: .committed
        )
    }

    package func beginClosing(_ handle: String) throws {
        try transition(
            handle,
            from: [
                .registrationInFlight,
                .registeredNotOpen,
                .opening,
                .openedAwaitingCommit,
                .commitInFlight,
                .commitOutcomeUnknown,
                .committed,
            ],
            to: .closing
        )
    }

    package func applyReconciliation(
        _ outcome: PreparationReconciliationDTO,
        to handle: String
    ) throws {
        var entry = try session(handle)
        let admissible: Set<HostSessionLifecycle> = outcome.status == .committed
            ? [.commitOutcomeUnknown, .openedAwaitingCommit, .committed]
            : [.commitOutcomeUnknown]
        guard admissible.contains(entry.lifecycle) else {
            throw invalidTransition(entry.lifecycle, to: entry.lifecycle)
        }

        switch outcome.status {
        case .committed:
            guard let runHandle = outcome.handle,
                  runHandle.runID == entry.allocation.proposedRunID,
                  runHandle.sessionHandle == handle
            else {
                throw failure(
                    "llm.host.reconciliation_identity_mismatch",
                    "committed reconciliation does not match the prepared session"
                )
            }
            entry.lifecycle = .committed

        case .pending:
            entry.lifecycle = .openedAwaitingCommit

        case .aborting:
            guard let cleanup = outcome.cleanupIdentity,
                  cleanup.preparationID == entry.allocation.preparationID,
                  cleanup.proposedRunID == entry.allocation.proposedRunID,
                  cleanup.sessionHandle == handle,
                  cleanup.registrationDigest
                    == entry.allocation.preparedSessionRegistrationDigest,
                  cleanup.hostProcessEpoch == hostProcessEpoch.rawValue
            else {
                throw failure(
                    "llm.host.reconciliation_identity_mismatch",
                    "aborting reconciliation does not match the prepared session"
                )
            }
            entry.lifecycle = .closing
        }
        sessions[handle] = entry
    }

    package func recordSessionClosed(_ handle: String) throws {
        let entry = try session(handle)
        guard entry.lifecycle == .closing else {
            throw invalidTransition(entry.lifecycle, to: .closed)
        }
        sessions.removeValue(forKey: handle)
        tombstones[handle] = ClosedSessionTombstone(
            allocation: entry.allocation,
            cleanupCommand: nil,
            cleanupAcknowledgement: nil,
            closeReceipt: nil
        )
    }

    package func lifecycle(for handle: String) -> HostSessionLifecycle? {
        if let entry = sessions[handle] {
            return entry.lifecycle
        }
        return tombstones[handle] == nil ? nil : .closed
    }

    package func hasInstalledDriver(for handle: String) -> Bool {
        sessions[handle]?.driver != nil
    }

    package func drainNext() async {
        guard let data = inbox.pop() else { return }
        do {
            let dispatch = try JSONDecoder().decode(HostDispatchEnvelope.self, from: data)
            switch dispatch.dispatchKind {
            case .command:
                if let command = dispatch.command {
                    await process(command)
                }
            case .preparedSessionCleanup:
                if let cleanup = dispatch.preparedSessionCleanup {
                    await process(cleanup)
                }
            }
        } catch {
            // A malformed copy has no trustworthy command identity to acknowledge.
        }
    }

    package func drainAvailable() async {
        scheduleDrainIfNeeded()
        while let activeDrain = drainTask {
            await activeDrain.value
        }
    }

    package func signalInbox() {
        scheduleDrainIfNeeded()
    }

    private func scheduleDrainIfNeeded() {
        guard drainTask == nil, inbox.hasQueuedData() else { return }
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.performDrainLoop()
        }
    }

    private func performDrainLoop() async {
        while !Task.isCancelled, let data = inbox.pop() {
            await processCopiedData(data)
        }
        drainTask = nil
        scheduleDrainIfNeeded()
    }

    private func processCopiedData(_ data: Data) async {
        do {
            let dispatch = try JSONDecoder().decode(HostDispatchEnvelope.self, from: data)
            switch dispatch.dispatchKind {
            case .command:
                if let command = dispatch.command {
                    await process(command)
                }
            case .preparedSessionCleanup:
                if let cleanup = dispatch.preparedSessionCleanup {
                    await process(cleanup)
                }
            }
        } catch {
            // A malformed copy has no trustworthy command identity to acknowledge.
        }
    }

    private func process(_ command: HostCommandEnvelope) async {
        guard command.schemaVersion == 1 || command.schemaVersion == 2 else {
            await reject(command, code: "llm.command.unsupported_schema")
            return
        }
        guard tombstones[command.sessionHandle] == nil else {
            await reject(command, code: "llm.command.closed_session")
            return
        }
        guard command.hostProcessEpoch == hostProcessEpoch.rawValue else {
            await reject(command, code: "llm.command.wrong_epoch")
            return
        }
        do {
            try command.payload.validate(
                for: command.kind,
                envelopeRunID: command.runID
            )
        } catch let error as HostContractValidationError {
            await reject(command, code: error.code)
            return
        } catch {
            await reject(command, code: "llm.contract.command_payload_mismatch")
            return
        }
        guard let digest = try? command.recomputedDigest().hex,
              digest == command.commandEnvelopeDigest
        else {
            await reject(command, code: "llm.command.digest_mismatch")
            return
        }
        if sessions[command.sessionHandle] == nil {
            guard adoptRustOwnedV2Session(for: command) else {
                await reject(command, code: "llm.command.unknown_session")
                return
            }
        }
        guard var entry = sessions[command.sessionHandle] else { return }
        guard command.hostProcessEpoch == entry.allocation.hostProcessEpoch.rawValue else {
            await reject(command, code: "llm.command.wrong_epoch")
            return
        }
        guard command.runID == entry.allocation.proposedRunID else {
            await reject(command, code: "llm.command.wrong_run")
            return
        }

        switch entry.commandLedger.claim(command) {
        case let .duplicate(result):
            let acknowledgement = await result.value
            _ = await rustSink.submitCommandAcknowledgement(acknowledgement)
            return

        case .conflict:
            await reject(command, code: "llm.command.sequence_conflict")
            return

        case .gap:
            await reject(command, code: "llm.command.sequence_gap")
            return

        case .next:
            let result = executionTask(for: command, entry: &entry)
            entry.commandLedger.record(command, result: result)
            sessions[command.sessionHandle] = entry
            let acknowledgement = await result.value
            let acknowledged = await rustSink.submitCommandAcknowledgement(acknowledgement)
            if acknowledged,
               acknowledgement.disposition == .accepted,
               command.schemaVersion == 2
            {
                executeAcceptedV2Command(command)
            }
        }
    }

    private func adoptRustOwnedV2Session(
        for command: HostCommandEnvelope
    ) -> Bool {
        guard command.schemaVersion == 2,
              command.kind == .startGeneration,
              command.commandSequence == 1,
              modelHandler != nil
        else {
            return false
        }
        let allocation = AllocatedHostSession(
            sessionHandle: command.sessionHandle,
            preparationID: "rust-react:\(command.runID)",
            proposedRunID: command.runID,
            swiftSnapshotID: command.payloadDigest,
            bindingHash: command.payloadDigest,
            hostProcessEpoch: hostProcessEpoch,
            preparedSessionRegistrationDigest: command.commandEnvelopeDigest,
            cleanupOwner: PreparedSessionCleanupOwner()
        )
        sessions[command.sessionHandle] = HostSessionEntry(
            allocation: allocation,
            lifecycle: .committed,
            driver: nil,
            eventSequencer: LLMEventSequencer(
                runID: command.runID,
                sessionHandle: command.sessionHandle,
                hostProcessEpoch: hostProcessEpoch,
                submitter: rustSink
            )
        )
        return true
    }

    private func executionTask(
        for command: HostCommandEnvelope,
        entry: inout HostSessionEntry
    ) -> Task<HostCommandAcknowledgement, Never> {
        let rejection: String?
        let driver = entry.driver
        let isV2 = command.schemaVersion == 2

        switch command.kind {
        case .startGeneration:
            rejection = isV2
                ? v2GenerationRejection(
                    command,
                    lifecycle: entry.lifecycle,
                    allowed: [.commitInFlight, .commitOutcomeUnknown, .committed]
                )
                : generationRejection(
                    command,
                    lifecycle: entry.lifecycle,
                    allowed: [.commitInFlight, .commitOutcomeUnknown, .committed],
                    driver: driver
                )
            if rejection == nil,
               entry.lifecycle == .commitInFlight
                || entry.lifecycle == .commitOutcomeUnknown
            {
                entry.lifecycle = .committed
            }

        case .resumeGeneration:
            rejection = isV2
                ? v2GenerationRejection(
                    command,
                    lifecycle: entry.lifecycle,
                    allowed: [.committed]
                )
                : generationRejection(
                    command,
                    lifecycle: entry.lifecycle,
                    allowed: [.committed],
                    driver: driver
                )

        case .cancelGeneration:
            rejection = entry.lifecycle == .committed
                && (isV2 ? modelHandler != nil : driver != nil)
                ? nil
                : "llm.command.invalid_lifecycle"

        case .executeToolBatch:
            rejection = isV2
                && entry.lifecycle == .committed
                && toolHandler != nil
                && command.payload.toolBatch != nil
                ? nil
                : "llm.command.invalid_lifecycle"

        case .cancelToolBatch:
            rejection = isV2
                && entry.lifecycle == .committed
                && toolHandler != nil
                && command.payload.targetBatchID != nil
                ? nil
                : "llm.command.invalid_lifecycle"

        case .closeSession:
            rejection = entry.lifecycle == .committed
                && (isV2 ? modelHandler != nil : driver != nil)
                ? nil
                : "llm.command.invalid_lifecycle"
            if rejection == nil {
                entry.lifecycle = .closing
            }

        case .capacityAvailable:
            rejection = entry.lifecycle == .committed
                ? nil
                : "llm.command.invalid_lifecycle"
        }

        if let rejection {
            return Task { rejectedAcknowledgement(command, code: rejection) }
        }

        if command.kind == .startGeneration || command.kind == .resumeGeneration {
            guard let generationTurnID = command.generationTurnID,
                  let disclosure = command.disclosure
            else {
                return Task {
                    rejectedAcknowledgement(
                        command,
                        code: "llm.command.missing_generation_disclosure"
                    )
                }
            }
            if isV2 {
                entry.activeGenerationTurnID = generationTurnID
                return Task { acceptedAcknowledgement(command) }
            }
            guard let driver else {
                return Task {
                    rejectedAcknowledgement(
                        command,
                        code: "llm.command.invalid_lifecycle"
                    )
                }
            }
            let turn = HostGenerationTurn(
                commandID: command.commandID,
                generationTurnID: generationTurnID,
                payload: command.payload,
                disclosure: disclosure
            )
            let mode: HostGenerationMode = command.kind == .startGeneration
                ? .start
                : .resume
            let sequencer = entry.eventSequencer
            let operationStartTimeout = operationStartTimeout
            entry.generationTask = Task {
                await driveGeneration(
                    driver: driver,
                    sequencer: sequencer,
                    turn: turn,
                    mode: mode,
                    operationStartTimeout: operationStartTimeout
                )
            }
            entry.activeGenerationTurnID = generationTurnID
            return Task { acceptedAcknowledgement(command) }
        }

        if isV2 {
            return Task { acceptedAcknowledgement(command) }
        }
        let eventSequencer = entry.eventSequencer
        guard let driver else {
            return Task {
                rejectedAcknowledgement(
                    command,
                    code: "llm.command.invalid_lifecycle"
                )
            }
        }
        let generationTask = entry.generationTask
        let activeGenerationTurnID = entry.activeGenerationTurnID
        return Task {
            switch command.kind {
            case .startGeneration, .resumeGeneration:
                break

            case .executeToolBatch, .cancelToolBatch:
                break

            case .cancelGeneration:
                Task {
                    do {
                        try await driver.cancel()
                        _ = try await eventSequencer.submit(
                            kind: .cancelled,
                            payload: LLMEventPayload(commandID: command.commandID),
                            generationTurnID: activeGenerationTurnID
                        )
                    } catch {
                        _ = try? await eventSequencer.submit(
                            kind: .failed,
                            payload: LLMEventPayload(
                                failureCode: publicFailureCode(error)
                            ),
                            generationTurnID: activeGenerationTurnID
                        )
                    }
                }

            case .closeSession:
                Task { [weak self] in
                    await generationTask?.value
                    do {
                        try await driver.close()
                        let result = try await eventSequencer.submit(
                            kind: .sessionClosed,
                            payload: LLMEventPayload(
                                commandID: command.commandID,
                                closeDisposition:
                                    LLMBackendSessionCloseDisposition.closed.rawValue
                            ),
                            generationTurnID: nil
                        )
                        await self?.finishCommittedClose(
                            command.sessionHandle,
                            result: result
                        )
                    } catch {
                        await self?.quarantine(command.sessionHandle)
                    }
                }

            case .capacityAvailable:
                await eventSequencer.notifyCapacityAvailable()
            }
            return acceptedAcknowledgement(command)
        }
    }

    private func executeAcceptedV2Command(_ command: HostCommandEnvelope) {
        guard var entry = sessions[command.sessionHandle] else { return }
        let sequencer = entry.eventSequencer

        switch command.kind {
        case .startGeneration, .resumeGeneration:
            guard let modelHandler,
                  let generationTurnID = command.generationTurnID,
                  let request = try? command.payload.modelRequest(
                      for: command.kind,
                      envelopeRunID: command.runID
                  )
            else {
                return
            }
            entry.generationTask = Task {
                await modelHandler.generate(
                    request: request,
                    generationTurnID: generationTurnID,
                    sequencer: sequencer
                )
            }
            entry.activeGenerationTurnID = generationTurnID
            sessions[command.sessionHandle] = entry

        case .executeToolBatch:
            guard let toolHandler, let batch = command.payload.toolBatch else { return }
            let generationTurnID = entry.activeGenerationTurnID
            Task {
                await toolHandler.execute(
                    batch,
                    generationTurnID: generationTurnID,
                    sequencer: sequencer
                )
            }

        case .cancelToolBatch:
            guard let toolHandler, let batchID = command.payload.targetBatchID else {
                return
            }
            Task { await toolHandler.cancel(batchID: batchID) }

        case .cancelGeneration:
            guard let modelHandler else { return }
            let generationTurnID = entry.activeGenerationTurnID
            Task {
                await modelHandler.cancel(runID: command.runID)
                _ = try? await sequencer.submit(
                    kind: .cancelled,
                    payload: LLMEventPayload(commandID: command.commandID),
                    generationTurnID: generationTurnID
                )
            }

        case .closeSession:
            let generationTask = entry.generationTask
            Task { [weak self] in
                await generationTask?.value
                await self?.modelHandler?.finish(runID: command.runID)
                await self?.toolHandler?.finish(runID: command.runID)
                let result = try? await sequencer.submit(
                    kind: .sessionClosed,
                    payload: LLMEventPayload(
                        commandID: command.commandID,
                        closeDisposition:
                            LLMBackendSessionCloseDisposition.closed.rawValue
                    ),
                    generationTurnID: nil
                )
                await self?.finishCommittedClose(
                    command.sessionHandle,
                    result: result
                )
            }

        case .capacityAvailable:
            Task { await sequencer.notifyCapacityAvailable() }
        }
    }

    private func finishCommittedClose(
        _ handle: String,
        result: LLMEventSubmissionResult?
    ) {
        guard result == .accepted || result == .duplicate,
              let entry = sessions[handle],
              entry.lifecycle == .closing
        else { return }
        sessions.removeValue(forKey: handle)
        tombstones[handle] = ClosedSessionTombstone(
            allocation: entry.allocation,
            cleanupCommand: nil,
            cleanupAcknowledgement: nil,
            closeReceipt: nil
        )
    }

    private func generationRejection(
        _ command: HostCommandEnvelope,
        lifecycle: HostSessionLifecycle,
        allowed: Set<HostSessionLifecycle>,
        driver: (any LLMHostSessionDriver)?
    ) -> String? {
        guard allowed.contains(lifecycle), driver != nil else {
            return "llm.command.invalid_lifecycle"
        }
        guard let generationTurnID = command.generationTurnID,
              let disclosure = command.disclosure,
              disclosure.generationTurnID == generationTurnID
        else {
            return "llm.command.missing_generation_disclosure"
        }
        return nil
    }

    private func v2GenerationRejection(
        _ command: HostCommandEnvelope,
        lifecycle: HostSessionLifecycle,
        allowed: Set<HostSessionLifecycle>
    ) -> String? {
        guard allowed.contains(lifecycle), modelHandler != nil else {
            return "llm.command.invalid_lifecycle"
        }
        guard let generationTurnID = command.generationTurnID,
              let disclosure = command.disclosure,
              disclosure.generationTurnID == generationTurnID
        else {
            return "llm.command.missing_generation_disclosure"
        }
        return nil
    }

    private func process(_ cleanup: HostPreparedSessionCleanupCommand) async {
        if let tombstone = tombstones[cleanup.sessionHandle] {
            await replayCleanupIfExact(cleanup, tombstone: tombstone)
            return
        }
        guard var entry = sessions[cleanup.sessionHandle] else { return }
        guard cleanupMatchesAllocation(cleanup, entry.allocation),
              preparedCleanupDigest(cleanup) == cleanup.cleanupCommandDigest
        else {
            entry.lifecycle = .quarantined
            sessions[cleanup.sessionHandle] = entry
            return
        }

        if let operation = entry.cleanupOperation {
            guard operation.command == cleanup else {
                entry.lifecycle = .quarantined
                sessions[cleanup.sessionHandle] = entry
                return
            }
            await finishCleanup(
                cleanup,
                allocation: entry.allocation,
                result: await operation.result.value
            )
            return
        }

        let admissible: Set<HostSessionLifecycle> = [
            .registrationInFlight,
            .registeredNotOpen,
            .opening,
            .openedAwaitingCommit,
            .commitInFlight,
            .commitOutcomeUnknown,
            .committed,
        ]
        guard admissible.contains(entry.lifecycle) else {
            entry.lifecycle = .quarantined
            sessions[cleanup.sessionHandle] = entry
            return
        }

        let allocation = entry.allocation
        let owner = entry.allocation.cleanupOwner
        let operation = Task {
            let disposition = await owner.close()
            let acknowledgement = PreparedSessionCleanupAcknowledgementDTO(
                cleanupCommandId: cleanup.cleanupCommandID,
                preparationId: cleanup.preparationID,
                preparationCleanupSequence: cleanup.preparationCleanupSequence,
                cleanupCommandDigest: cleanup.cleanupCommandDigest
            )
            guard let receiptDigest = preparedCloseReceiptDigest(
                cleanup,
                disposition: disposition
            ) else {
                return CleanupOperationResult.digestFailure
            }
            let receipt = PreparedSessionClosedReceiptDTO(
                cleanupCommandId: cleanup.cleanupCommandID,
                preparationId: cleanup.preparationID,
                proposedRunId: cleanup.proposedRunID,
                sessionHandle: cleanup.sessionHandle,
                hostProcessEpoch: cleanup.hostProcessEpoch,
                preparationCleanupSequence: cleanup.preparationCleanupSequence,
                closeDisposition: disposition.rawValue,
                receiptDigest: receiptDigest
            )
            return CleanupOperationResult.success(acknowledgement, receipt)
        }
        entry.lifecycle = .closing
        entry.cleanupOperation = CleanupOperation(command: cleanup, result: operation)
        sessions[cleanup.sessionHandle] = entry
        await finishCleanup(
            cleanup,
            allocation: allocation,
            result: await operation.value
        )
    }

    private func finishCleanup(
        _ cleanup: HostPreparedSessionCleanupCommand,
        allocation: AllocatedHostSession,
        result: CleanupOperationResult
    ) async {
        guard case let .success(acknowledgement, receipt) = result else {
            quarantine(cleanup.sessionHandle)
            return
        }
        guard await rustSink.acknowledgePreparedSessionCleanup(acknowledgement) else {
            quarantine(cleanup.sessionHandle)
            return
        }
        guard await rustSink.confirmPreparedSessionClosed(receipt) else {
            quarantine(cleanup.sessionHandle)
            return
        }

        sessions.removeValue(forKey: cleanup.sessionHandle)
        tombstones[cleanup.sessionHandle] = ClosedSessionTombstone(
            allocation: allocation,
            cleanupCommand: cleanup,
            cleanupAcknowledgement: acknowledgement,
            closeReceipt: receipt
        )
    }

    private func replayCleanupIfExact(
        _ cleanup: HostPreparedSessionCleanupCommand,
        tombstone: ClosedSessionTombstone
    ) async {
        guard tombstone.cleanupCommand == cleanup,
              let acknowledgement = tombstone.cleanupAcknowledgement,
              let receipt = tombstone.closeReceipt
        else {
            return
        }
        guard await rustSink.acknowledgePreparedSessionCleanup(acknowledgement) else {
            return
        }
        _ = await rustSink.confirmPreparedSessionClosed(receipt)
    }

    private func cleanupMatchesAllocation(
        _ cleanup: HostPreparedSessionCleanupCommand,
        _ allocation: AllocatedHostSession
    ) -> Bool {
        cleanup.preparationID == allocation.preparationID
            && cleanup.proposedRunID == allocation.proposedRunID
            && cleanup.sessionHandle == allocation.sessionHandle
            && cleanup.hostProcessEpoch == allocation.hostProcessEpoch.rawValue
            && cleanup.hostProcessEpoch == hostProcessEpoch.rawValue
            && cleanup.preparationCleanupSequence == 1
            && cleanup.preparedSessionRegistrationDigest
                == allocation.preparedSessionRegistrationDigest
    }

    private func quarantine(_ handle: String) {
        guard var entry = sessions[handle] else { return }
        entry.lifecycle = .quarantined
        sessions[handle] = entry
    }

    private func reject(
        _ command: HostCommandEnvelope,
        code: String
    ) async {
        _ = await rustSink.submitCommandAcknowledgement(
            rejectedAcknowledgement(command, code: code)
        )
    }

    private func session(_ handle: String) throws -> HostSessionEntry {
        guard let entry = sessions[handle] else {
            throw failure(
                "llm.host.unknown_session",
                "host session does not exist"
            )
        }
        return entry
    }

    private func transition(
        _ handle: String,
        from allowed: Set<HostSessionLifecycle>,
        to newLifecycle: HostSessionLifecycle
    ) throws {
        var entry = try session(handle)
        guard allowed.contains(entry.lifecycle) else {
            throw invalidTransition(entry.lifecycle, to: newLifecycle)
        }
        entry.lifecycle = newLifecycle
        sessions[handle] = entry
    }

    private func invalidTransition(
        _ current: HostSessionLifecycle,
        to target: HostSessionLifecycle
    ) -> LLMHostRuntimeError {
        failure(
            "llm.host.invalid_lifecycle",
            "cannot transition from \(current.rawValue) to \(target.rawValue)"
        )
    }

    private func failure(_ code: String, _ message: String) -> LLMHostRuntimeError {
        LLMHostRuntimeError(code: code, message: message)
    }
}

private func acceptedAcknowledgement(
    _ command: HostCommandEnvelope
) -> HostCommandAcknowledgement {
    HostCommandAcknowledgement(
        commandID: command.commandID,
        sessionHandle: command.sessionHandle,
        commandSequence: command.commandSequence,
        commandEnvelopeDigest: command.commandEnvelopeDigest,
        disposition: .accepted
    )
}

private func rejectedAcknowledgement(
    _ command: HostCommandEnvelope,
    code: String
) -> HostCommandAcknowledgement {
    HostCommandAcknowledgement(
        commandID: command.commandID,
        sessionHandle: command.sessionHandle,
        commandSequence: command.commandSequence,
        commandEnvelopeDigest: command.commandEnvelopeDigest,
        disposition: .rejected,
        rejectionCode: code
    )
}

private enum HostGenerationStartTimeout: Error {
    case elapsed
}

private func driveGeneration(
    driver: any LLMHostSessionDriver,
    sequencer: LLMEventSequencer,
    turn: HostGenerationTurn,
    mode: HostGenerationMode,
    operationStartTimeout: Duration
) async {
    do {
        let launch = try await driver.makeAuthorizedLaunch(for: turn, mode: mode)
        let operation = try await startOperation(
            launch,
            timeout: operationStartTimeout
        )
        _ = try await sequencer.submit(
            kind: .generationStarted,
            payload: LLMEventPayload(
                commandID: turn.commandID,
                opaqueOperationID: operation.opaqueOperationID
            ),
            generationTurnID: turn.generationTurnID
        )
        for try await backendEvent in operation.events {
            guard let normalized = normalizedEvent(backendEvent) else { continue }
            _ = try await sequencer.submit(
                kind: normalized.kind,
                payload: normalized.payload,
                generationTurnID: turn.generationTurnID
            )
        }
    } catch {
        _ = try? await sequencer.submit(
            kind: .failed,
            payload: LLMEventPayload(failureCode: publicFailureCode(error)),
            generationTurnID: turn.generationTurnID
        )
    }
}

private func startOperation(
    _ launch: AuthorizedHostGenerationLaunch,
    timeout: Duration
) async throws -> HostGenerationOperation {
    try await withThrowingTaskGroup(of: HostGenerationOperation.self) { group in
        group.addTask { try await launch.run() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw HostGenerationStartTimeout.elapsed
        }
        guard let operation = try await group.next() else {
            throw HostGenerationStartTimeout.elapsed
        }
        group.cancelAll()
        return operation
    }
}

private func normalizedEvent(
    _ event: LLMBackendEvent
) -> (kind: LLMEventKind, payload: LLMEventPayload)? {
    switch event {
    case .generationStarted:
        return nil
    case let .textDelta(text):
        return (.textDelta, LLMEventPayload(text: text))
    case let .reasoningSummaryDelta(text):
        return (.reasoningSummaryDelta, LLMEventPayload(text: text))
    case let .toolCallStarted(callID, name):
        return (
            .toolCallStarted,
            LLMEventPayload(callID: callID, name: name)
        )
    case let .toolCallArgumentsDelta(callID, delta):
        return (
            .toolCallArgumentsDelta,
            LLMEventPayload(callID: callID, argumentsJSON: delta)
        )
    case let .toolCallCompleted(call):
        return (
            .toolCallCompleted,
            LLMEventPayload(
                callID: call.callID,
                name: call.name,
                argumentsJSON: call.argumentsJSON
            )
        )
    case let .usageUpdated(usage):
        return (
            .usageUpdated,
            LLMEventPayload(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            )
        )
    case let .generationCompleted(completion):
        return (
            .generationCompleted,
            LLMEventPayload(
                completion: LLMBackendCompletionWire(
                    outcome: completion.outcome.rawValue,
                    orderedCallIDs: completion.orderedCallIDs,
                    finishReason: completion.finishReason.rawValue
                )
            )
        )
    case let .failed(failure):
        return (
            .failed,
            LLMEventPayload(failureCode: failure.code.rawValue)
        )
    case .cancelled:
        return nil
    case let .sessionClosed(commandID, disposition):
        return (
            .sessionClosed,
            LLMEventPayload(
                commandID: commandID,
                closeDisposition: disposition.rawValue
            )
        )
    }
}

private func publicFailureCode(_ error: Error) -> String {
    if let failure = error as? LLMHostFailure {
        return failure.code
    }
    if error is CancellationError {
        return LLMBackendFailureCode.cancelled.rawValue
    }
    guard let failure = error as? LLMFailure else {
        return LLMBackendFailureCode.generationFailed.rawValue
    }
    let code = failure.code.lowercased()
    if code.contains("egress") {
        return LLMBackendFailureCode.egressDenied.rawValue
    }
    if code.contains("rate") {
        return LLMBackendFailureCode.rateLimited.rawValue
    }
    if code.contains("context") {
        return LLMBackendFailureCode.contextExceeded.rawValue
    }
    if code.contains("capability") || code.contains("unsupported") {
        return LLMBackendFailureCode.unsupportedCapability.rawValue
    }
    if code.contains("stream") || code.contains("transport") {
        return LLMBackendFailureCode.streamInterrupted.rawValue
    }
    if code.contains("not_ready")
        || code.contains("state_invalid")
        || code.contains("not_runnable")
        || code.contains("unavailable")
    {
        return LLMBackendFailureCode.notReady.rawValue
    }
    if code.contains("cancel") {
        return LLMBackendFailureCode.cancelled.rawValue
    }
    return LLMBackendFailureCode.generationFailed.rawValue
}

private struct PreparedCleanupDigestDocument: Encodable {
    let cleanupCommandID: String
    let preparationID: String
    let proposedRunID: String
    let sessionHandle: String
    let hostProcessEpoch: String
    let preparationCleanupSequence: UInt64
    let reason: String
    let preparedSessionRegistrationDigest: String
    let cleanupCommandDigest = ""

    init(_ cleanup: HostPreparedSessionCleanupCommand) {
        cleanupCommandID = cleanup.cleanupCommandID
        preparationID = cleanup.preparationID
        proposedRunID = cleanup.proposedRunID
        sessionHandle = cleanup.sessionHandle
        hostProcessEpoch = cleanup.hostProcessEpoch
        preparationCleanupSequence = cleanup.preparationCleanupSequence
        reason = cleanup.reason
        preparedSessionRegistrationDigest = cleanup.preparedSessionRegistrationDigest
    }

    private enum CodingKeys: String, CodingKey {
        case cleanupCommandID = "cleanup_command_id"
        case preparationID = "preparation_id"
        case proposedRunID = "proposed_run_id"
        case sessionHandle = "session_handle"
        case hostProcessEpoch = "host_process_epoch"
        case preparationCleanupSequence = "preparation_cleanup_sequence"
        case reason
        case preparedSessionRegistrationDigest = "prepared_session_registration_digest"
        case cleanupCommandDigest = "cleanup_command_digest"
    }
}

private func preparedCleanupDigest(
    _ cleanup: HostPreparedSessionCleanupCommand
) -> String? {
    guard let document = try? JSONDecoder().decode(
        CanonicalJSONValue.self,
        from: JSONEncoder().encode(PreparedCleanupDigestDocument(cleanup))
    ) else {
        return nil
    }
    return try? CanonicalDigestV1.digest(
        domain: "prepared-session-cleanup-command:v1",
        document: document
    ).hex
}

private func preparedCloseReceiptDigest(
    _ cleanup: HostPreparedSessionCleanupCommand,
    disposition: LLMBackendSessionCloseDisposition
) -> String? {
    guard let document = try? CanonicalJSONValue.object(entries: [
        .init(name: "cleanup_command_id", value: .string(cleanup.cleanupCommandID)),
        .init(name: "preparation_id", value: .string(cleanup.preparationID)),
        .init(name: "proposed_run_id", value: .string(cleanup.proposedRunID)),
        .init(name: "session_handle", value: .string(cleanup.sessionHandle)),
        .init(name: "host_process_epoch", value: .string(cleanup.hostProcessEpoch)),
        .init(
            name: "cleanup_sequence",
            value: .number(Double(cleanup.preparationCleanupSequence))
        ),
        .init(
            name: "prepared_session_registration_digest",
            value: .string(cleanup.preparedSessionRegistrationDigest)
        ),
        .init(
            name: "cleanup_command_digest",
            value: .string(cleanup.cleanupCommandDigest)
        ),
        .init(name: "close_disposition", value: .string(disposition.rawValue)),
    ]) else {
        return nil
    }
    return try? CanonicalDigestV1.digest(
        domain: "prepared-session-closed-receipt:v1",
        document: document
    ).hex
}
