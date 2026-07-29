import Foundation
import LocalAgentBridge
import XCTest
@testable import LocalAgentApp

@MainActor
final class RustAgentInputSnapshotProviderTests: XCTestCase {
    func testSnapshotContainsPromptDescriptorsAndSharedToolCatalogOnly() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.promptStore.add(
            name: "Base",
            markdown: "Base instructions",
            source: "settings"
        )
        _ = try fixture.skillStore.importSkill(
            content: """
            ---
            name: Progressive Skill
            description: Read when relevant.
            ---
            SECRET_SKILL_BODY
            """
        )
        let provider = RustAgentInputSnapshotProvider(
            promptDocuments: fixture.promptStore,
            skills: fixture.skillStore
        ) {
            try OpenMinisToolDefinitionSnapshotProvider.productDefaults()
        }

        let snapshot = try await provider.snapshot(
            conversationStreamID: "conversation"
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(snapshot),
            as: UTF8.self
        )

        XCTAssertEqual(
            snapshot.orderedPromptDocuments.map(\.markdown),
            ["Base instructions"]
        )
        XCTAssertEqual(snapshot.skillDescriptors.map(\.id), ["progressive-skill"])
        XCTAssertTrue(
            snapshot.orderedToolDefinitions.map(\.name)
                .contains("browser_use")
        )
        XCTAssertFalse(encoded.contains("SECRET_SKILL_BODY"))
        XCTAssertFalse(encoded.contains(fixture.root.path))
        try snapshot.validate()
    }

    func testRunSnapshotIsImmutableAfterStoresChange() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let prompt = try fixture.promptStore.add(
            name: "Base",
            markdown: "Version one"
        )
        let provider = RustAgentInputSnapshotProvider(
            promptDocuments: fixture.promptStore,
            skills: fixture.skillStore
        ) {
            try OpenMinisToolDefinitionSnapshotProvider.productDefaults()
        }
        let first = try await provider.snapshot(conversationStreamID: nil)

        try fixture.promptStore.update(
            prompt.id,
            name: "Base",
            markdown: "Version two"
        )
        let second = try await provider.snapshot(conversationStreamID: nil)

        XCTAssertEqual(
            first.orderedPromptDocuments.first?.markdown,
            "Version one"
        )
        XCTAssertEqual(
            second.orderedPromptDocuments.first?.markdown,
            "Version two"
        )
        XCTAssertNotEqual(first.snapshotDigest, second.snapshotDigest)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return Fixture(
            root: root,
            promptStore: try PromptDocumentStore(
                fileURL: root.appendingPathComponent("prompts.json")
            ),
            skillStore: try SkillStore(
                skillsDirectory: root.appendingPathComponent("skills"),
                metadataURL: root.appendingPathComponent("skills.json"),
                overridesURL: root.appendingPathComponent("overrides.json")
            )
        )
    }

    private struct Fixture {
        let root: URL
        let promptStore: PromptDocumentStore
        let skillStore: SkillStore

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
