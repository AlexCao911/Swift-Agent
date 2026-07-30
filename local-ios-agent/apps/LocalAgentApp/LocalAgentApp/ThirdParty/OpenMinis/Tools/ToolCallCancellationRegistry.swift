import Foundation

actor ToolCallCancellationRegistry {
    typealias Cancellation = @Sendable () async -> Void
    typealias ProcessCancellation = @Sendable (Int32) async -> Void

    struct Entry: Sendable {
        var runID: String
        var cancel: Cancellation?
        var pids: Set<Int32>
    }

    private var entriesByBatch: [String: [String: Entry]] = [:]
    private var runIDByBatch: [String: String] = [:]
    private var cancelledBatchIDs: Set<String> = []
    private let cancelProcess: ProcessCancellation

    init(
        cancelProcess: @escaping ProcessCancellation = { _ in }
    ) {
        self.cancelProcess = cancelProcess
    }

    func beginBatch(batchID: String, runID: String) {
        entriesByBatch[batchID] = [:]
        runIDByBatch[batchID] = runID
        cancelledBatchIDs.remove(batchID)
    }

    func register(
        batchID: String,
        callID: String,
        runID: String,
        cancel: @escaping Cancellation
    ) async {
        guard runIDByBatch[batchID] == runID else { return }
        if cancelledBatchIDs.contains(batchID) {
            await cancel()
            return
        }
        var entry = entriesByBatch[batchID]?[callID]
            ?? Entry(runID: runID, cancel: nil, pids: [])
        entry.cancel = cancel
        entriesByBatch[batchID]?[callID] = entry
    }

    func record(pid: Int32, batchID: String, callID: String) async {
        guard let runID = runIDByBatch[batchID] else { return }
        if cancelledBatchIDs.contains(batchID) {
            await cancelProcess(pid)
            return
        }
        var entry = entriesByBatch[batchID]?[callID]
            ?? Entry(runID: runID, cancel: nil, pids: [])
        entry.pids.insert(pid)
        entriesByBatch[batchID]?[callID] = entry
    }

    func cancel(batchID: String) async {
        guard runIDByBatch[batchID] != nil else { return }
        cancelledBatchIDs.insert(batchID)
        let entries = Array(entriesByBatch[batchID, default: [:]].values)
        for entry in entries {
            if let cancel = entry.cancel {
                await cancel()
            }
            for pid in entry.pids {
                await cancelProcess(pid)
            }
        }
    }

    func isCancelled(batchID: String) -> Bool {
        cancelledBatchIDs.contains(batchID)
    }

    func finishBatch(batchID: String) {
        entriesByBatch.removeValue(forKey: batchID)
        runIDByBatch.removeValue(forKey: batchID)
        cancelledBatchIDs.remove(batchID)
    }

    func contains(batchID: String, callID: String) -> Bool {
        entriesByBatch[batchID]?[callID] != nil
    }
}
