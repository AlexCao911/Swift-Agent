import Foundation
import XCTest
@testable import LocalAgentApp

@MainActor
final class PromptDocumentStoreTests: XCTestCase {
    func testEnabledDocumentsPersistInExplicitOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("prompt-documents.json")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try PromptDocumentStore(fileURL: file)
        let first = try store.add(
            name: "Base",
            markdown: "Base prompt",
            source: "settings"
        )
        let second = try store.add(
            name: "Project",
            markdown: "Project prompt",
            source: "import"
        )
        try store.setEnabled(first.id, enabled: false)
        try store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        let reloaded = try PromptDocumentStore(fileURL: file)

        XCTAssertEqual(reloaded.documents.map(\.id), [second.id, first.id])
        XCTAssertEqual(
            reloaded.enabledSnapshots().map(\.markdown),
            ["Project prompt"]
        )
    }

    func testImportsMarkdownWithoutTemplateExpansion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("AGENTS.md")
        let markdown = "Keep {{literal}} and $VARIABLE unchanged."
        try markdown.write(to: source, atomically: true, encoding: .utf8)
        let store = try PromptDocumentStore(
            fileURL: root.appendingPathComponent("documents.json")
        )

        let record = try store.importMarkdown(at: source)

        XCTAssertEqual(record.markdown, markdown)
        XCTAssertEqual(store.enabledSnapshots().first?.markdown, markdown)
        XCTAssertEqual(store.enabledSnapshots().first?.source, "file:AGENTS.md")
    }
}
