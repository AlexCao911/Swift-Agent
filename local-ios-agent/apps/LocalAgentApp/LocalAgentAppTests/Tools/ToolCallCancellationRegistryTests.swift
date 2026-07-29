import Foundation
import Testing
@testable import LocalAgentApp

@Suite("OpenMinis tool cancellation registry")
struct ToolCallCancellationRegistryTests {
    @Test
    func sameCallIDInDifferentBatchesCancelsOnlyRequestedBatch() async {
        let cancellations = CancellationProbe()
        let registry = ToolCallCancellationRegistry()
        await registry.beginBatch(batchID: "batch-a", runID: "run-a")
        await registry.beginBatch(batchID: "batch-b", runID: "run-b")
        await registry.register(
            batchID: "batch-a",
            callID: "same",
            runID: "run-a"
        ) {
            await cancellations.record("a")
        }
        await registry.register(
            batchID: "batch-b",
            callID: "same",
            runID: "run-b"
        ) {
            await cancellations.record("b")
        }

        await registry.cancel(batchID: "batch-a")

        #expect(await cancellations.values == ["a"])
        #expect(await registry.contains(batchID: "batch-b", callID: "same"))
    }

    @Test
    func cancellationBeforeLateHandleAndPIDRegistrationCancelsBothImmediately() async {
        let cancellations = CancellationProbe()
        let pids = PIDProbe()
        let registry = ToolCallCancellationRegistry { pid in
            await pids.record(pid)
        }
        await registry.beginBatch(batchID: "batch", runID: "run")
        await registry.cancel(batchID: "batch")

        await registry.register(
            batchID: "batch",
            callID: "late",
            runID: "run"
        ) {
            await cancellations.record("late")
        }
        await registry.record(pid: 42, batchID: "batch", callID: "late")

        #expect(await cancellations.values == ["late"])
        #expect(await pids.values == [42])
    }

    @Test
    func finishRemovesBatchEntries() async {
        let registry = ToolCallCancellationRegistry()
        await registry.beginBatch(batchID: "batch", runID: "run")
        await registry.register(
            batchID: "batch",
            callID: "call",
            runID: "run"
        ) {}

        await registry.finishBatch(batchID: "batch")

        #expect(await registry.contains(batchID: "batch", callID: "call") == false)
    }
}

private actor CancellationProbe {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private actor PIDProbe {
    private(set) var values: [Int32] = []

    func record(_ value: Int32) {
        values.append(value)
    }
}
