import Foundation

final class ToolLoopDetectorRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var detectorsByRunID: [String: ToolLoopDetector] = [:]

    func detector(for runID: String) -> ToolLoopDetector {
        lock.lock()
        defer { lock.unlock() }
        if let existing = detectorsByRunID[runID] {
            return existing
        }
        let detector = ToolLoopDetector()
        detectorsByRunID[runID] = detector
        return detector
    }

    func remove(runID: String) {
        lock.lock()
        defer { lock.unlock() }
        detectorsByRunID.removeValue(forKey: runID)
    }

    func contains(runID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return detectorsByRunID[runID] != nil
    }
}
