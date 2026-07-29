import Foundation
import LocalAgentLLMContracts
import XCTest
@testable import LocalAgentApp

@MainActor
final class SkillStoreMigrationTests: XCTestCase {
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

    private func makeFixture() throws -> Fixture {
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
            overridesURL: root.appendingPathComponent("overrides.json")
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
