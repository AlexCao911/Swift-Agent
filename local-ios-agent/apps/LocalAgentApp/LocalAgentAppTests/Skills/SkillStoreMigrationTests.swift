import Foundation
import LocalAgentLLMContracts
import XCTest
@testable import LocalAgentApp

@MainActor
final class SkillStoreMigrationTests: XCTestCase {
    func testURLImportUsesTheBoundedDownloaderContract() async throws {
        let downloader = RecordingSkillDownloader(
            payload: SkillDownloadPayload(
                data: Data("""
                ---
                name: Downloaded Skill
                description: Imported safely.
                ---
                Body
                """.utf8),
                response: try XCTUnwrap(HTTPURLResponse(
                    url: URL(string: "https://example.com/SKILL.md")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        )
        let fixture = try makeFixture(downloader: downloader)
        defer { fixture.cleanup() }

        let skill = try await fixture.store.importFromURL(
            "https://example.com/SKILL.md"
        )

        XCTAssertEqual(skill.id, "downloaded-skill")
        let recordedRequest = await downloader.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url.absoluteString, "https://example.com/SKILL.md")
        XCTAssertEqual(request.maximumBytes, 50 * 1024 * 1024)
    }

    func testControlledDownloaderValidatesRedirectBeforeFollowingIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SkillDownloadURLProtocol.self]
        SkillDownloadURLProtocol.install { request in
            if request.url?.host == "public.example" {
                return .redirect(URL(string: "https://127.0.0.1/private")!)
            }
            return .response(status: 200, chunks: [Data("secret".utf8)])
        }
        defer { SkillDownloadURLProtocol.reset() }
        let validator = RecordingSkillURLValidator(
            deniedHosts: ["127.0.0.1"]
        )
        let downloader = ControlledSkillDownloader(
            validator: validator,
            configuration: configuration
        )

        do {
            _ = try await downloader.download(
                from: URL(string: "https://public.example/SKILL.md")!,
                maximumBytes: 1_024
            )
            XCTFail("private redirect must be rejected")
        } catch let error as ControlledSkillDownloadError {
            XCTAssertEqual(error, .policyDenied)
        }

        let validatedHosts = await validator.validatedHosts()
        XCTAssertEqual(validatedHosts, ["public.example", "127.0.0.1"])
        XCTAssertEqual(
            SkillDownloadURLProtocol.requestedHosts(),
            ["public.example"]
        )
    }

    func testControlledDownloaderStopsAtTheStreamingByteLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SkillDownloadURLProtocol.self]
        SkillDownloadURLProtocol.install { _ in
            .response(
                status: 200,
                chunks: [
                    Data("1234".utf8),
                    Data("5678".utf8),
                    Data("overflow".utf8),
                ]
            )
        }
        defer { SkillDownloadURLProtocol.reset() }
        let downloader = ControlledSkillDownloader(
            validator: RecordingSkillURLValidator(),
            configuration: configuration
        )

        do {
            _ = try await downloader.download(
                from: URL(string: "https://public.example/SKILL.md")!,
                maximumBytes: 8
            )
            XCTFail("stream exceeding the byte limit must be cancelled")
        } catch let error as ControlledSkillDownloadError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testDescriptorContainsOnlyMetadataAndVirtualSkillPath() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let secretBody = "Never preload this body: INTERNAL_BODY_SENTINEL"

        _ = try fixture.store.importSkill(
            content: """
            ---
            name: Demo Skill
            description: Use for demonstrations.
            version: 1.2.3
            ---
            \(secretBody)
            """,
            source: .file
        )

        let descriptors = try fixture.store.rustDescriptors(
            for: "conversation-1"
        )
        let descriptor = try XCTUnwrap(descriptors.first)
        let encoded = String(
            decoding: try JSONEncoder().encode(descriptor),
            as: UTF8.self
        )

        XCTAssertEqual(descriptor.id, "demo-skill")
        XCTAssertEqual(
            descriptor.location,
            "/var/localagent/skills/demo-skill/SKILL.md"
        )
        XCTAssertFalse(encoded.contains(secretBody))
        XCTAssertFalse(encoded.contains(fixture.root.path))
    }

    func testConversationOverrideDoesNotChangeGlobalDefault() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let skill = try fixture.store.importSkill(
            content: """
            ---
            name: Override Demo
            description: Tests local overrides.
            ---
            Body
            """
        )

        fixture.store.setConversationOverride(
            skillID: skill.id,
            conversationStreamID: "conversation-a",
            enabled: false
        )

        XCTAssertTrue(skill.isEnabled)
        XCTAssertTrue(
            try fixture.store.rustDescriptors(for: "conversation-a").isEmpty
        )
        XCTAssertEqual(
            try fixture.store.rustDescriptors(for: "conversation-b")
                .map(\.id),
            [skill.id]
        )
    }

    func testDirectoryImportCopiesSiblingFilesWithoutPreloadingThem() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let importRoot = fixture.root.appendingPathComponent(
            "incoming",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: importRoot.appendingPathComponent("references"),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: Directory Demo
        description: Reads references only on demand.
        ---
        Read references/details.md when needed.
        """.write(
            to: importRoot.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "REFERENCE_SENTINEL".write(
            to: importRoot.appendingPathComponent("references/details.md"),
            atomically: true,
            encoding: .utf8
        )

        let skill = try fixture.store.importFromFile(at: importRoot)
        let descriptor = try XCTUnwrap(
            fixture.store.rustDescriptors(for: nil).first
        )
        let skillBody = try XCTUnwrap(
            fixture.store.readSkillContent(skill.id)
        )

        XCTAssertEqual(descriptor.id, skill.id)
        XCTAssertFalse(skillBody.contains("REFERENCE_SENTINEL"))
        XCTAssertEqual(
            fixture.store.readSkillFile(
                skill.id,
                relativePath: "references/details.md"
            ),
            "REFERENCE_SENTINEL"
        )
    }

    func testOrdinaryFileToolReadsSelectedSkillThroughVirtualMount() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.importSkill(
            content: """
            ---
            name: Read On Demand
            description: Read only after selection.
            ---
            BODY_FROM_FILE_TOOL
            """
        )
        let resolver = ToolFileResolver(
            guestRootURL: fixture.root.appendingPathComponent("guest"),
            hostMounts: [
                .skills: .init(
                    rootURL: fixture.skillsRoot,
                    isWritable: false
                ),
            ]
        )
        let dispatcher = OpenMinisProductToolDispatcher(
            ish: SkillStoreISHStub(),
            browser: SkillStoreBrowserStub(),
            files: resolver
        )

        let result = await dispatcher.execute(
            HostToolCall(
                callID: "read-skill",
                toolName: "file_read",
                argumentsJSON: #"{"path":"/var/localagent/skills/read-on-demand/SKILL.md"}"#
            ),
            context: OpenMinisToolExecutionContext(
                batchID: "batch",
                runID: "run",
                onProcessStarted: { _ in }
            )
        )

        XCTAssertFalse(result.isError)
        guard case .string(let text) = result.result else {
            return XCTFail("Expected text")
        }
        XCTAssertTrue(text.contains("BODY_FROM_FILE_TOOL"))
        XCTAssertFalse(text.contains(fixture.root.path))
    }

    private func makeFixture(
        downloader: any SkillDownloading = ControlledSkillDownloader()
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsRoot = root.appendingPathComponent(
            "skills",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: skillsRoot,
            withIntermediateDirectories: true
        )
        let store = try SkillStore(
            skillsDirectory: skillsRoot,
            metadataURL: root.appendingPathComponent("skills.json"),
            overridesURL: root.appendingPathComponent("overrides.json"),
            downloader: downloader
        )
        return Fixture(root: root, skillsRoot: skillsRoot, store: store)
    }

    private struct Fixture {
        let root: URL
        let skillsRoot: URL
        let store: SkillStore

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private actor RecordingSkillDownloader: SkillDownloading {
    struct Request {
        let url: URL
        let maximumBytes: Int
    }

    private let payload: SkillDownloadPayload
    private var request: Request?

    init(payload: SkillDownloadPayload) {
        self.payload = payload
    }

    func download(
        from url: URL,
        maximumBytes: Int
    ) async throws -> SkillDownloadPayload {
        request = Request(url: url, maximumBytes: maximumBytes)
        return payload
    }

    func lastRequest() -> Request? { request }
}

private actor RecordingSkillURLValidator: SkillURLValidating {
    private let deniedHosts: Set<String>
    private var hosts: [String] = []

    init(deniedHosts: Set<String> = []) {
        self.deniedHosts = deniedHosts
    }

    func validate(_ url: URL) async throws {
        let host = url.host ?? ""
        hosts.append(host)
        if deniedHosts.contains(host) {
            throw ControlledSkillDownloadError.policyDenied
        }
    }

    func validatedHosts() -> [String] { hosts }
}

private final class SkillDownloadURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    enum Result {
        case redirect(URL)
        case response(status: Int, chunks: [Data])
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler:
        (@Sendable (URLRequest) -> Result)?
    nonisolated(unsafe) private static var hosts: [String] = []

    static func install(
        _ handler: @escaping @Sendable (URLRequest) -> Result
    ) {
        lock.lock()
        self.handler = handler
        hosts = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        hosts = []
        lock.unlock()
    }

    static func requestedHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.hosts.append(request.url?.host ?? "")
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        switch handler(request) {
        case let .redirect(target):
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: target),
                redirectResponse: response
            )
            client?.urlProtocolDidFinishLoading(self)
        case let .response(status, chunks):
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/markdown"]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private actor SkillStoreISHStub: OpenMinisISHRunning {
    func execute(
        executable: String,
        arguments: [String],
        stdin: Data?,
        onProcessStarted: @escaping @Sendable (Int32) async -> Void
    ) async -> ISHCommandResult {
        ISHCommandResult(
            pid: -1,
            exitCode: 1,
            stdout: "",
            stderr: "unexpected iSH call",
            duration: 0,
            wasCancelled: false
        )
    }
}

private struct SkillStoreBrowserStub: OpenMinisBrowserRunning {
    func execute(
        runID: String,
        argumentsJSON: String
    ) async -> OpenMinisBrowserExecutionResult {
        OpenMinisBrowserExecutionResult(value: .string("unexpected"), isError: true)
    }

    func finish(runID: String) async {}
}
