import Combine
import Foundation
import LocalAgentBridge

struct PromptDocumentRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var source: String
    var markdown: String
    var isEnabled: Bool
    var sortOrder: Int
}

@MainActor
final class PromptDocumentStore: ObservableObject {
    static let shared: PromptDocumentStore = {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("LocalAgent", isDirectory: true)
        return try! PromptDocumentStore(
            fileURL: root.appendingPathComponent("prompt-documents.json")
        )
    }()

    @Published private(set) var documents: [PromptDocumentRecord]

    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: fileURL.path) {
            documents = try JSONDecoder().decode(
                [PromptDocumentRecord].self,
                from: Data(contentsOf: fileURL)
            )
        } else {
            documents = []
        }
        normalizeOrder()
    }

    @discardableResult
    func add(
        name: String,
        markdown: String,
        source: String = "settings"
    ) throws -> PromptDocumentRecord {
        let record = PromptDocumentRecord(
            id: UUID().uuidString.lowercased(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source,
            markdown: markdown,
            isEnabled: true,
            sortOrder: documents.count
        )
        documents.append(record)
        try save()
        return record
    }

    @discardableResult
    func importMarkdown(at url: URL) throws -> PromptDocumentRecord {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        return try add(
            name: url.deletingPathExtension().lastPathComponent,
            markdown: markdown,
            source: "file:\(url.lastPathComponent)"
        )
    }

    func update(
        _ id: String,
        name: String,
        markdown: String
    ) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            return
        }
        documents[index].name = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        documents[index].markdown = markdown
        try save()
    }

    func setEnabled(_ id: String, enabled: Bool) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            return
        }
        documents[index].isEnabled = enabled
        try save()
    }

    func remove(_ id: String) throws {
        documents.removeAll { $0.id == id }
        normalizeOrder()
        try save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) throws {
        var ordered = documents.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            return $0.id < $1.id
        }
        let moving = fromOffsets.sorted().map { ordered[$0] }
        for index in fromOffsets.sorted(by: >) {
            ordered.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.filter {
            $0 < toOffset
        }.count
        let insertionIndex = min(
            max(0, toOffset - removedBeforeDestination),
            ordered.count
        )
        ordered.insert(contentsOf: moving, at: insertionIndex)
        documents = ordered
        normalizeOrder()
        try save()
    }

    func enabledSnapshots() -> [PromptDocumentSnapshotDTO] {
        documents
            .filter(\.isEnabled)
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.id < $1.id
            }
            .map {
                PromptDocumentSnapshotDTO(
                    id: $0.id,
                    source: $0.source,
                    markdown: $0.markdown
                )
            }
    }

    private func normalizeOrder() {
        documents.sort {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            return $0.id < $1.id
        }
        for index in documents.indices {
            documents[index].sortOrder = index
        }
    }

    private func save() throws {
        normalizeOrder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(documents).write(to: fileURL, options: .atomic)
    }
}
