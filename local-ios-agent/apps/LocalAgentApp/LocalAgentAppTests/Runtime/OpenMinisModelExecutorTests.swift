import Foundation
import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore
import XCTest
@testable import LocalAgentApp

final class OpenMinisModelExecutorTests: XCTestCase {
    func testRegistryRestoresFrozenRunPlanAndRouteAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appending(path: "provider-run-plans.json")
        let frozenPlan = plan("cloud-a", "cloud-b")
        let snapshots = Dictionary(
            uniqueKeysWithValues: frozenPlan.orderedCandidates.map {
                ($0.id, routeSnapshot(candidateID: $0.id))
            }
        )
        let first = OpenMinisModelExecutionRegistry(
            persistenceURL: storeURL
        )
        try await first.bind(
            runID: "run-recovered",
            plan: frozenPlan,
            routes: Dictionary(
                uniqueKeysWithValues: frozenPlan.orderedCandidates.map {
                    ($0.id, RecordingRestoredRoute() as any ProviderCandidateModelRoute)
                }
            ),
            routeSnapshots: snapshots
        )

        let restoration = RouteRestorationRecorder()
        let relaunched = OpenMinisModelExecutionRegistry(
            persistenceURL: storeURL
        ) { runID, snapshot in
            await restoration.record(runID: runID, candidateID: snapshot.candidateID)
            return RecordingRestoredRoute()
        }

        let relaunchedPlan = try await relaunched.plan(for: "run-recovered")
        XCTAssertEqual(relaunchedPlan, frozenPlan)
        try await relaunched.generate(
            request(runID: "run-recovered"),
            candidate: frozenPlan.orderedCandidates[0]
        ) { _ in }
        let restoredPairs = await restoration.restoredPairs()
        XCTAssertEqual(
            restoredPairs,
            [.init(runID: "run-recovered", candidateID: "cloud-a")]
        )

        await relaunched.finish(runID: "run-recovered")
        let afterFinish = OpenMinisModelExecutionRegistry(
            persistenceURL: storeURL
        )
        do {
            _ = try await afterFinish.plan(for: "run-recovered")
            XCTFail("finished run plan must not be restored")
        } catch {}
    }

    func testPlanIsFrozenForTheWholeRunAndReleasedOnFinish() async throws {
        let source = MutableProviderRunPlanSource(plan: plan("cloud-a"))
        let runtime = RecordingProviderCandidateRuntime(
            behavior: [
                "cloud-a": [.events([.toolCallDelta(
                    callID: "call-1",
                    toolName: "shell",
                    argumentsFragment: "{}"
                )]), .events([.textDelta("done")])],
                "cloud-b": [.events([.textDelta("new")])],
            ]
        )
        let executor = OpenMinisModelExecutor(
            plans: source,
            runtime: runtime
        )

        try await executor.generate(request(runID: "run-1")) { _ in }
        await source.replace(with: plan("cloud-b"))
        try await executor.generate(request(runID: "run-1")) { _ in }

        var candidateIDs = await runtime.candidateIDs()
        var resolveCount = await source.resolveCount()
        XCTAssertEqual(candidateIDs, ["cloud-a", "cloud-a"])
        XCTAssertEqual(resolveCount, 1)

        await executor.finish(runID: "run-1")
        try await executor.generate(request(runID: "run-1")) { _ in }

        candidateIDs = await runtime.candidateIDs()
        resolveCount = await source.resolveCount()
        let finishedRunIDs = await source.finishedRunIDs()
        XCTAssertEqual(candidateIDs, ["cloud-a", "cloud-a", "cloud-b"])
        XCTAssertEqual(resolveCount, 2)
        XCTAssertEqual(finishedRunIDs, ["run-1"])
    }

    func testStartupReconciliationRemovesOnlyOrphanedPlans() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appending(path: "provider-run-plans.json")
        let registry = OpenMinisModelExecutionRegistry(
            persistenceURL: storeURL
        )
        for runID in ["run-active", "run-orphaned"] {
            let runPlan = plan("cloud-a")
            try await registry.bind(
                runID: runID,
                plan: runPlan,
                routes: [
                    "cloud-a": RecordingRestoredRoute(),
                ],
                routeSnapshots: [
                    "cloud-a": routeSnapshot(candidateID: "cloud-a"),
                ]
            )
        }

        try await registry.reconcile(keeping: Set(["run-active"]))

        let relaunched = OpenMinisModelExecutionRegistry(
            persistenceURL: storeURL
        )
        let storedRunIDs = await relaunched.storedRunIDs
        XCTAssertEqual(storedRunIDs, Set(["run-active"]))
    }

    func testFinishRetainsPlanAndReportsPersistenceFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appending(path: "provider-run-plans.json")
        let registry = OpenMinisModelExecutionRegistry(
            persistenceURL: storeURL
        )
        let runPlan = plan("cloud-a")
        try await registry.bind(
            runID: "run-cleanup",
            plan: runPlan,
            routes: ["cloud-a": RecordingRestoredRoute()],
            routeSnapshots: [
                "cloud-a": routeSnapshot(candidateID: "cloud-a"),
            ]
        )
        try FileManager.default.removeItem(at: storeURL)
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )

        await registry.finish(runID: "run-cleanup")

        let storedRunIDs = await registry.storedRunIDs
        let persistenceError = await registry.lastPersistenceError
        XCTAssertEqual(storedRunIDs, Set(["run-cleanup"]))
        XCTAssertNotNil(persistenceError)
    }

    func testFallbackOccursOnlyBeforeModelContent() async throws {
        let source = MutableProviderRunPlanSource(
            plan: plan("primary", "fallback")
        )
        let runtime = RecordingProviderCandidateRuntime(
            behavior: [
                "primary": [.failBeforeContent],
                "fallback": [.events([.textDelta("fallback output")])],
            ]
        )
        let executor = OpenMinisModelExecutor(
            plans: source,
            runtime: runtime
        )
        let emitted = HostModelEventRecorder()

        try await executor.generate(request(runID: "run-fallback")) {
            await emitted.record($0)
        }

        let candidateIDs = await runtime.candidateIDs()
        let events = await emitted.events()
        XCTAssertEqual(
            candidateIDs,
            ["primary", "fallback"]
        )
        XCTAssertEqual(events, [.textDelta("fallback output")])
    }

    func testFallbackCandidateRemainsPinnedForLaterReactRounds() async throws {
        let source = MutableProviderRunPlanSource(
            plan: plan("primary", "fallback")
        )
        let runtime = RecordingProviderCandidateRuntime(
            behavior: [
                "primary": [
                    .events([.toolCallDelta(
                        callID: "primary-call",
                        toolName: "shell",
                        argumentsFragment: "{}"
                    )]),
                    .failBeforeContent,
                ],
                "fallback": [
                    .events([.toolCallDelta(
                        callID: "fallback-call",
                        toolName: "shell",
                        argumentsFragment: "{}"
                    )]),
                    .events([.textDelta("done")]),
                ],
            ]
        )
        let executor = OpenMinisModelExecutor(
            plans: source,
            runtime: runtime
        )

        try await executor.generate(request(runID: "run-pinned")) { _ in }
        try await executor.generate(request(runID: "run-pinned")) { _ in }
        try await executor.generate(request(runID: "run-pinned")) { _ in }

        let candidateIDs = await runtime.candidateIDs()
        XCTAssertEqual(
            candidateIDs,
            ["primary", "primary", "fallback", "fallback"]
        )
    }

    func testFailedCandidateRouteIsClosedBeforeFallbackStarts() async throws {
        let frozenPlan = plan("primary", "fallback")
        let primary = ScriptedProviderRoute(outcomes: [.failure])
        let fallback = ScriptedProviderRoute(outcomes: [.success])
        let registry = OpenMinisModelExecutionRegistry()
        try await registry.bind(
            runID: "run-close-failed",
            plan: frozenPlan,
            routes: [
                "primary": primary,
                "fallback": fallback,
            ]
        )
        let executor = OpenMinisModelExecutor(
            plans: registry,
            runtime: registry
        )

        try await executor.generate(request(runID: "run-close-failed")) { _ in }

        let primaryFinishCount = await primary.finishCount()
        let fallbackGenerateCount = await fallback.generateCount()
        XCTAssertEqual(primaryFinishCount, 1)
        XCTAssertEqual(fallbackGenerateCount, 1)
    }

    func testFailureAfterContentNeverStartsAnotherCandidate() async {
        let source = MutableProviderRunPlanSource(
            plan: plan("primary", "fallback")
        )
        let runtime = RecordingProviderCandidateRuntime(
            behavior: [
                "primary": [.emitThenFail(.reasoningDelta("started"))],
                "fallback": [.events([.textDelta("must not run")])],
            ]
        )
        let executor = OpenMinisModelExecutor(
            plans: source,
            runtime: runtime
        )
        let emitted = HostModelEventRecorder()

        do {
            try await executor.generate(request(runID: "run-output")) {
                await emitted.record($0)
            }
            XCTFail("expected generation failure")
        } catch {}

        let candidateIDs = await runtime.candidateIDs()
        let events = await emitted.events()
        XCTAssertEqual(candidateIDs, ["primary"])
        XCTAssertEqual(events, [.reasoningDelta("started")])
    }

    func testCancellationBeforeFirstTokenNeverStartsFallback() async {
        let source = MutableProviderRunPlanSource(
            plan: plan("primary", "fallback")
        )
        let runtime = RecordingProviderCandidateRuntime(
            behavior: [
                "primary": [.cancelled],
                "fallback": [.events([.textDelta("must not run")])],
            ]
        )
        let executor = OpenMinisModelExecutor(
            plans: source,
            runtime: runtime
        )

        do {
            try await executor.generate(request(runID: "run-cancel")) { _ in }
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let candidateIDs = await runtime.candidateIDs()
        XCTAssertEqual(candidateIDs, ["primary"])
    }

    func testConcurrentRunsDoNotShareEmissionState() async throws {
        let source = PerRunProviderPlanSource(plans: [
            "run-a": plan("a-primary", "a-fallback"),
            "run-b": plan("b-primary", "b-fallback"),
        ])
        let runtime = RecordingProviderCandidateRuntime(
            behavior: [
                "a-primary": [.emitThenFail(.textDelta("a"))],
                "a-fallback": [.events([.textDelta("must not run")])],
                "b-primary": [.failBeforeContent],
                "b-fallback": [.events([.textDelta("b")])],
            ]
        )
        let executor = OpenMinisModelExecutor(
            plans: source,
            runtime: runtime
        )

        async let runA: Void = {
            do {
                try await executor.generate(request(runID: "run-a")) { _ in }
                XCTFail("run-a should fail after output")
            } catch {}
        }()
        async let runB: Void = executor.generate(
            request(runID: "run-b")
        ) { _ in }
        _ = try await (runA, runB)

        let ids = await runtime.candidateIDs()
        XCTAssertFalse(ids.contains("a-fallback"))
        XCTAssertTrue(ids.contains("b-fallback"))
    }

    func testExplicitCancellationUsesOnlyTheActiveRunCandidate() async {
        let source = MutableProviderRunPlanSource(plan: plan("primary"))
        let runtime = RecordingProviderCandidateRuntime(
            behavior: ["primary": [.waitForCancellation]]
        )
        let executor = OpenMinisModelExecutor(
            plans: source,
            runtime: runtime
        )
        let generation = Task {
            try await executor.generate(request(runID: "run-active")) { _ in }
        }
        await runtime.waitUntilStarted()

        await executor.cancel(runID: "run-active")

        do {
            try await generation.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let cancelled = await runtime.cancelledPairs()
        XCTAssertEqual(
            cancelled,
            [.init(runID: "run-active", candidateID: "primary")]
        )
    }

    func testCancellationStillTerminatesWhenTheRouteReturnsNormally() async {
        let source = MutableProviderRunPlanSource(plan: plan("primary"))
        let runtime = RecordingProviderCandidateRuntime(
            behavior: ["primary": [.returnAfterCancellation]]
        )
        let executor = OpenMinisModelExecutor(plans: source, runtime: runtime)
        let generation = Task {
            try await executor.generate(request(runID: "run-normal-return")) { _ in }
        }
        await runtime.waitUntilStarted()

        await executor.cancel(runID: "run-normal-return")

        do {
            try await generation.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}

private func plan(_ candidateIDs: String...) -> ProviderRunPlan {
    ProviderRunPlan(
        logicalModelID: "logical-model",
        orderedCandidates: candidateIDs.map {
            ProviderRunCandidate(
                id: $0,
                kind: .cloud,
                providerConfigurationID: "provider-\($0)",
                providerType: "openAI",
                modelID: "model-\($0)",
                baseURL: URL(string: "https://example.com/v1"),
                presetID: .openAIChatCompletions
            )
        },
        modelContextWindow: ModelContextWindowDTO(
            contextWindowTokens: 128_000,
            maxOutputTokens: 8_192
        )
    )
}

private func request(runID: String) -> HostModelRequest {
    HostModelRequest(
        runID: runID,
        conversationStreamID: "conversation-\(runID)",
        systemPrompt: "system",
        orderedMessages: [
            HostModelMessage(role: "user", content: .string("hello")),
        ],
        attachmentReferences: [],
        orderedToolDefinitions: []
    )
}

private func routeSnapshot(candidateID: String) -> ProviderRunRouteSnapshot {
    let target = LLMTargetRevision(
        targetID: LLMTargetID(rawValue: "target-\(candidateID)"),
        revision: 1,
        kind: .cloud(providerProfileID: "provider-\(candidateID)", providerProfileRevision: 1),
        modelID: "model-\(candidateID)",
        defaultParameters: GenerationConfiguration()
    )
    return ProviderRunRouteSnapshot(
        candidateID: candidateID,
        configuration: AgentHostConfiguration(
            bindingID: "binding-\(candidateID)",
            revision: 1,
            agentProfileID: "profile",
            agentProfileRevision: 1,
            llmSlotID: "primary",
            requirementsHash: "requirements",
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
        ),
        target: target
    )
}

private actor RouteRestorationRecorder {
    struct Pair: Equatable {
        let runID: String
        let candidateID: String
    }

    private var pairs: [Pair] = []

    func record(runID: String, candidateID: String) {
        pairs.append(.init(runID: runID, candidateID: candidateID))
    }

    func restoredPairs() -> [Pair] { pairs }
}

private actor RecordingRestoredRoute: ProviderCandidateModelRoute {
    func generate(
        _: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        try await emit(.textDelta("restored"))
    }

    func cancel(runID _: String) async {}
    func finish(runID _: String) async {}
}

private actor ScriptedProviderRoute: ProviderCandidateModelRoute {
    enum Outcome {
        case success
        case failure
    }

    private var outcomes: [Outcome]
    private var generations = 0
    private var finishes = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func generate(
        _: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        generations += 1
        switch outcomes.removeFirst() {
        case .success:
            try await emit(.textDelta("done"))
        case .failure:
            throw TestModelFailure()
        }
    }

    func cancel(runID _: String) async {}

    func finish(runID _: String) async {
        finishes += 1
    }

    func generateCount() -> Int {
        generations
    }

    func finishCount() -> Int {
        finishes
    }
}

private actor MutableProviderRunPlanSource: ProviderRunPlanProviding {
    private var current: ProviderRunPlan
    private var resolutions = 0
    private var finished: [String] = []

    init(plan: ProviderRunPlan) {
        current = plan
    }

    func plan(for _: String) async throws -> ProviderRunPlan {
        resolutions += 1
        return current
    }

    func finish(runID: String) async {
        finished.append(runID)
    }

    func replace(with plan: ProviderRunPlan) {
        current = plan
    }

    func resolveCount() -> Int {
        resolutions
    }

    func finishedRunIDs() -> [String] {
        finished
    }
}

private actor PerRunProviderPlanSource: ProviderRunPlanProviding {
    let plans: [String: ProviderRunPlan]

    init(plans: [String: ProviderRunPlan]) {
        self.plans = plans
    }

    func plan(for runID: String) async throws -> ProviderRunPlan {
        guard let plan = plans[runID] else { throw TestModelFailure() }
        return plan
    }

    func finish(runID _: String) async {}
}

private actor RecordingProviderCandidateRuntime: ProviderCandidateModelExecuting {
    enum Behavior: Sendable {
        case events([HostModelEvent])
        case failBeforeContent
        case emitThenFail(HostModelEvent)
        case cancelled
        case waitForCancellation
        case returnAfterCancellation
    }

    struct CancelledPair: Equatable, Sendable {
        let runID: String
        let candidateID: String
    }

    private var behavior: [String: [Behavior]]
    private var invokedCandidateIDs: [String] = []
    private var cancelled: [CancelledPair] = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    init(behavior: [String: [Behavior]]) {
        self.behavior = behavior
    }

    func generate(
        _ request: HostModelRequest,
        candidate: ProviderRunCandidate,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        invokedCandidateIDs.append(candidate.id)
        let next = behavior[candidate.id]?.isEmpty == false
            ? behavior[candidate.id]?.removeFirst()
            : nil
        switch next {
        case let .events(events):
            for event in events {
                try await emit(event)
            }
        case .failBeforeContent:
            throw TestModelFailure()
        case let .emitThenFail(event):
            try await emit(event)
            throw TestModelFailure()
        case .cancelled:
            throw CancellationError()
        case .waitForCancellation:
            didStart = true
            startedContinuation?.resume()
            startedContinuation = nil
            await withCheckedContinuation { continuation in
                waiters[request.runID] = continuation
            }
            throw CancellationError()
        case .returnAfterCancellation:
            didStart = true
            startedContinuation?.resume()
            startedContinuation = nil
            await withCheckedContinuation { continuation in
                waiters[request.runID] = continuation
            }
            return
        case nil:
            throw TestModelFailure()
        }
    }

    func cancel(
        runID: String,
        candidate: ProviderRunCandidate
    ) async {
        cancelled.append(.init(runID: runID, candidateID: candidate.id))
        waiters.removeValue(forKey: runID)?.resume()
    }

    func finish(
        runID _: String,
        candidates _: [ProviderRunCandidate]
    ) async {}

    func candidateIDs() -> [String] {
        invokedCandidateIDs
    }

    func cancelledPairs() -> [CancelledPair] {
        cancelled
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }
}

private actor HostModelEventRecorder {
    private var recorded: [HostModelEvent] = []

    func record(_ event: HostModelEvent) {
        recorded.append(event)
    }

    func events() -> [HostModelEvent] {
        recorded
    }
}

private struct TestModelFailure: Error {}
