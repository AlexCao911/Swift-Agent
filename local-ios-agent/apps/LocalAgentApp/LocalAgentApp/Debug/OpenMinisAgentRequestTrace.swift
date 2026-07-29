#if DEBUG
import Foundation

final class OpenMinisAgentRequestTrace: @unchecked Sendable {
    enum Milestone: String, Equatable, Sendable {
        case requestStarted
        case firstVisibleEvent
        case toolBatchStarted
        case toolBatchCompleted
        case projectionCompleted
        case cancellationCleanedUp
    }

    struct Snapshot: Equatable, Sendable {
        let runID: String
        let milestones: [Milestone]
        let firstVisibleEventNanoseconds: UInt64?
        let toolBatchDurationNanoseconds: UInt64?
        let projectionCompletionNanoseconds: UInt64?
        let cancellationCleanupNanoseconds: UInt64?
        let peakActiveToolProcesses: Int
        let activeToolProcesses: Int
    }

    private let runID: String
    private let performance: OpenMinisPerfTrace
    private let lock = NSLock()
    private var milestones: [Milestone] = []
    private var activeToolProcesses = 0
    private var peakActiveToolProcesses = 0

    init(
        runID: String,
        performance: OpenMinisPerfTrace = OpenMinisPerfTrace()
    ) {
        self.runID = runID
        self.performance = performance
    }

    func requestStarted() {
        record(.requestStarted)
    }

    func firstVisibleEvent() {
        record(.firstVisibleEvent)
    }

    func toolBatchStarted() {
        record(.toolBatchStarted)
    }

    func toolBatchCompleted() {
        record(.toolBatchCompleted)
    }

    func projectionCompleted() {
        record(.projectionCompleted)
    }

    func cancellationCleanedUp() {
        record(.cancellationCleanedUp)
    }

    func toolProcessStarted() {
        lock.withLock {
            activeToolProcesses += 1
            peakActiveToolProcesses = max(
                peakActiveToolProcesses,
                activeToolProcesses
            )
        }
    }

    func toolProcessFinished() {
        lock.withLock {
            activeToolProcesses = max(0, activeToolProcesses - 1)
        }
    }

    func snapshot() -> Snapshot {
        let state = lock.withLock {
            (
                milestones,
                peakActiveToolProcesses,
                activeToolProcesses
            )
        }
        return Snapshot(
            runID: runID,
            milestones: state.0,
            firstVisibleEventNanoseconds: performance.elapsedNanoseconds(
                from: Milestone.requestStarted.rawValue,
                to: Milestone.firstVisibleEvent.rawValue
            ),
            toolBatchDurationNanoseconds: performance.elapsedNanoseconds(
                from: Milestone.toolBatchStarted.rawValue,
                to: Milestone.toolBatchCompleted.rawValue
            ),
            projectionCompletionNanoseconds: performance.elapsedNanoseconds(
                from: Milestone.requestStarted.rawValue,
                to: Milestone.projectionCompleted.rawValue
            ),
            cancellationCleanupNanoseconds: performance.elapsedNanoseconds(
                from: Milestone.requestStarted.rawValue,
                to: Milestone.cancellationCleanedUp.rawValue
            ),
            peakActiveToolProcesses: state.1,
            activeToolProcesses: state.2
        )
    }

    private func record(_ milestone: Milestone) {
        performance.mark(milestone.rawValue)
        lock.withLock {
            milestones.append(milestone)
        }
    }
}
#endif
