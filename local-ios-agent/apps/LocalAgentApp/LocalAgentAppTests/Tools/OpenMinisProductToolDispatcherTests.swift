import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import LocalNativeToolkit
import XCTest
@testable import LocalAgentApp

final class OpenMinisProductToolDispatcherTests: XCTestCase {
    func testISHOutputBufferKeepsBoundedHeadAndTailWithMarker() {
        let buffer = ISHBoundedOutputBuffer(maximumCharacters: 32)

        buffer.append("HEAD-0123456789")
        buffer.append(String(repeating: "x", count: 100))
        buffer.append("TAIL-9876543210")
        let output = buffer.snapshot()

        XCTAssertTrue(output.hasPrefix("HEAD-"))
        XCTAssertTrue(output.hasSuffix("TAIL-9876543210"))
        XCTAssertTrue(output.contains("[truncated "))
        XCTAssertLessThan(output.count, 160)
        XCTAssertGreaterThan(buffer.totalCharacters, UInt(32))
    }

    func testHostMountedWriteAndReadUseVirtualPathWithoutISH() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = ToolFileResolver(
            guestRootURL: root.appendingPathComponent("guest", isDirectory: true),
            hostMounts: [
                .shared: .init(rootURL: shared, isWritable: true),
            ]
        )
        let ish = RecordingISHRuntime()
        let dispatcher = OpenMinisProductToolDispatcher(
            ish: ish,
            browser: StubBrowserRuntime(),
            files: resolver
        )
        let context = OpenMinisToolExecutionContext(
            batchID: "batch",
            runID: "run",
            onProcessStarted: { _ in }
        )

        let write = await dispatcher.execute(
            HostToolCall(
                callID: "write",
                toolName: "file_write",
                argumentsJSON: #"{"tool_title":"Write","path":"/var/localagent/shared/note.txt","content":"hello"}"#
            ),
            context: context
        )
        let read = await dispatcher.execute(
            HostToolCall(
                callID: "read",
                toolName: "file_read",
                argumentsJSON: #"{"tool_title":"Read","path":"/var/localagent/shared/note.txt"}"#
            ),
            context: context
        )

        XCTAssertFalse(write.isError)
        XCTAssertEqual(read.result, .string("hello"))
        let invocationCount = await ish.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testCredentialShapedOutputIsRedacted() {
        let raw = """
        Authorization: Bearer secret-token
        api_key=abcdef123456789
        sk-abcdefghijklmnopqrstuvwxyz
        """

        let redacted = ToolResultCredentialRedactor.redact(raw)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("abcdef123456789"))
        XCTAssertFalse(redacted.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertEqual(redacted.components(separatedBy: "[REDACTED]").count - 1, 3)
    }

    func testBrowserVirtualURLUsesTheSameSharedMountAsFileTools() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root
            .appendingPathComponent("downloads/run", isDirectory: true)
            .appendingPathComponent("report.html")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ok".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = LocalAgentBrowserFiles.resolve(
            URL(string: "localagent://shared/downloads/run/report.html")!,
            mounts: [
                .shared: .init(rootURL: root, isWritable: true),
            ]
        )

        XCTAssertEqual(resolved, file)
        XCTAssertEqual(
            LocalAgentBrowserFiles.downloadToolURL(
                sessionID: "../run",
                filename: "../report.html"
            ),
            "localagent://shared/downloads/.._run/.._report.html"
        )
    }

    func testNativeToolUsesExistingHostDriver() async {
        let native = RecordingNativeHostDriver()
        let dispatcher = OpenMinisProductToolDispatcher(
            ish: RecordingISHRuntime(),
            browser: StubBrowserRuntime(),
            nativeTools: native
        )

        let output = await dispatcher.execute(
            HostToolCall(
                callID: "native-1",
                toolName: "calendar.search_events",
                argumentsJSON: #"{"query":"planning"}"#
            ),
            context: OpenMinisToolExecutionContext(
                batchID: "batch",
                runID: "run",
                onProcessStarted: { _ in }
            )
        )

        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.result, .string("native result"))
        XCTAssertEqual(output.highestSensitivity, "private")
        let executedToolName = await native.executedToolName
        XCTAssertEqual(executedToolName, "calendar.search_events")
    }

    func testReadImagePublishesAResolvableModelAttachment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        try png.write(to: shared.appendingPathComponent("pixel.png"))
        let store = OpenMinisAttachmentRepository(directory: attachments)
        let dispatcher = OpenMinisProductToolDispatcher(
            ish: RecordingISHRuntime(),
            browser: StubBrowserRuntime(),
            files: ToolFileResolver(
                guestRootURL: root.appendingPathComponent("guest", isDirectory: true),
                hostMounts: [.shared: .init(rootURL: shared, isWritable: true)]
            ),
            attachmentStore: store
        )

        let output = await dispatcher.execute(
            HostToolCall(
                callID: "image-1",
                toolName: "read_image",
                argumentsJSON: #"{"tool_title":"Inspect pixel","path":"/var/localagent/shared/pixel.png"}"#
            ),
            context: OpenMinisToolExecutionContext(
                batchID: "batch",
                runID: "run",
                onProcessStarted: { _ in }
            )
        )

        XCTAssertFalse(output.isError)
        let reference = output.result.objectValue(forKey: "attachment_reference")
        guard case let .string(attachmentID)? = reference?
            .objectValue(forKey: "attachment_id") else {
            return XCTFail("read_image did not return an attachment identifier")
        }
        XCTAssertEqual(reference?.objectValue(forKey: "modality"), .string("image"))
        XCTAssertEqual(reference?.objectValue(forKey: "media_type"), .string("image/rgb8"))
        let stored = try await store.read(attachmentId: attachmentID, maxBytes: 16)
        XCTAssertEqual(stored.count, 3)
    }
}

private actor RecordingISHRuntime: OpenMinisISHRunning {
    private(set) var invocationCount = 0

    func execute(
        executable: String,
        arguments: [String],
        stdin: Data?,
        onProcessStarted: @escaping @Sendable (Int32) async -> Void
    ) async -> ISHCommandResult {
        invocationCount += 1
        return ISHCommandResult(
            pid: 1,
            exitCode: 0,
            stdout: "",
            stderr: "",
            duration: 0,
            wasCancelled: false
        )
    }
}

private struct StubBrowserRuntime: OpenMinisBrowserRunning {
    func execute(
        runID: String,
        argumentsJSON: String
    ) async -> OpenMinisBrowserExecutionResult {
        OpenMinisBrowserExecutionResult(value: .string("ok"), isError: false)
    }

    func finish(runID: String) async {}
}

private actor RecordingNativeHostDriver: HostToolDriving {
    private(set) var executedToolName: String?

    func schemas() async -> [ToolSchemaDTO] {
        []
    }

    func execute(
        _ request: ToolExecutionRequestDTO,
        continuationIndex: Int
    ) async -> ToolResultDTO? {
        executedToolName = request.toolName
        return ToolResultDTO(
            displayText: "native result",
            modelText: "native result",
            structuredJson: "{}",
            auditText: "native result",
            sensitivity: .private,
            retention: .runOnly,
            isError: false
        )
    }
}
