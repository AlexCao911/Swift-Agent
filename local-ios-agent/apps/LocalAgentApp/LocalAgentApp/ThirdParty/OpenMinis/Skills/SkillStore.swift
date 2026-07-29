import Combine
import Compression
import Foundation
import LocalAgentBridge

enum SkillImportSource: Codable, Equatable, Sendable {
    case url(String)
    case file
    case bundled
    case session
}

struct Skill: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var description: String
    var version: String
    var importSource: SkillImportSource
    var isEnabled: Bool
    var installedAt: Date
    var updatedAt: Date
    var sortOrder: Int
}

enum SkillStoreChange: Equatable, Sendable {
    case upsert(String)
    case delete(String)
}

enum SkillStoreError: LocalizedError, Equatable {
    case invalidContent
    case invalidURL
    case downloadFailed(Int)
    case noSkillDocument
    case invalidArchive
    case unsafeArchivePath
    case archiveTooLarge
    case invalidRelativePath

    var errorDescription: String? {
        switch self {
        case .invalidContent:
            "SKILL.md must contain valid UTF-8 text and a non-empty name."
        case .invalidURL:
            "The Skill URL is invalid."
        case .downloadFailed(let status):
            "The Skill download failed with HTTP \(status)."
        case .noSkillDocument:
            "No SKILL.md was found."
        case .invalidArchive:
            "The Skill archive is invalid or unsupported."
        case .unsafeArchivePath:
            "The Skill archive contains an unsafe path."
        case .archiveTooLarge:
            "The Skill archive exceeds the import limit."
        case .invalidRelativePath:
            "The requested Skill file path is invalid."
        }
    }
}

@MainActor
final class SkillStore: ObservableObject {
    static let shared: SkillStore = {
        let mounts = LocalAgentToolMounts.configurations()
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("LocalAgent", isDirectory: true)
        return try! SkillStore(
            skillsDirectory: mounts[.skills]!.rootURL,
            metadataURL: applicationSupport.appendingPathComponent("skills.json"),
            overridesURL: applicationSupport.appendingPathComponent(
                "skill-conversation-overrides.json"
            )
        )
    }()

    static let maximumDescriptors = RunStartSnapshotDTO.maximumSkillDescriptors
    private static let maximumArchiveBytes = 50 * 1024 * 1024
    private static let maximumArchiveEntries = 500

    @Published private(set) var skills: [Skill]
    @Published private(set) var conversationOverrideVersion = 0

    private let fileManager: FileManager
    private let skillsDirectory: URL
    private let metadataURL: URL
    private let overridesURL: URL
    private let onEligibleGlobalChange: @Sendable (SkillStoreChange) -> Void
    private var overrides: [String: [String: Bool]]

    init(
        skillsDirectory: URL,
        metadataURL: URL,
        overridesURL: URL,
        fileManager: FileManager = .default,
        onEligibleGlobalChange: @escaping @Sendable (SkillStoreChange) -> Void
            = { _ in }
    ) throws {
        self.fileManager = fileManager
        self.skillsDirectory = skillsDirectory
        self.metadataURL = metadataURL
        self.overridesURL = overridesURL
        self.onEligibleGlobalChange = onEligibleGlobalChange
        try fileManager.createDirectory(
            at: skillsDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.skills = try Self.decodeIfPresent(
            [Skill].self,
            at: metadataURL
        ) ?? []
        self.overrides = try Self.decodeIfPresent(
            [String: [String: Bool]].self,
            at: overridesURL
        ) ?? [:]
        try reconcileFiles()
    }

    func reload() throws {
        skills = try Self.decodeIfPresent(
            [Skill].self,
            at: metadataURL
        ) ?? []
        overrides = try Self.decodeIfPresent(
            [String: [String: Bool]].self,
            at: overridesURL
        ) ?? [:]
        try reconcileFiles()
    }

    func skillDirectoryURL(for skillID: String) -> URL {
        skillsDirectory.appendingPathComponent(skillID, isDirectory: true)
    }

    @discardableResult
    func importSkill(
        content: String,
        source: SkillImportSource = .file
    ) throws -> Skill {
        let parsed = Self.parse(skillDocument: content)
        guard !parsed.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw SkillStoreError.invalidContent
        }
        let id = Self.slugify(parsed.name)
        guard !id.isEmpty else {
            throw SkillStoreError.invalidContent
        }
        return try install(
            content: content,
            parsed: parsed,
            id: id,
            source: source
        )
    }

    @discardableResult
    func importFromFile(at url: URL) throws -> Skill {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true else {
            throw SkillStoreError.invalidRelativePath
        }
        if values.isDirectory == true {
            return try importFromDirectory(at: url)
        }
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "zip"
            || url.pathExtension.lowercased() == "skill"
            || Self.looksLikeZip(data) {
            return try importFromArchive(data: data)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw SkillStoreError.invalidContent
        }
        return try importSkill(content: content, source: .file)
    }

    @discardableResult
    func importFromURL(_ urlString: String) async throws -> Skill {
        let sourceURL = try Self.downloadURL(from: urlString)
        let (data, response) = try await URLSession.shared.data(from: sourceURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw SkillStoreError.downloadFailed(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        guard data.count <= Self.maximumArchiveBytes else {
            throw SkillStoreError.archiveTooLarge
        }
        if Self.looksLikeZip(data) {
            return try importFromArchive(
                data: data,
                source: .url(urlString)
            )
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw SkillStoreError.invalidContent
        }
        return try importSkill(content: content, source: .url(urlString))
    }

    func installBundledSkills(from urls: [URL]) throws {
        for url in urls {
            let skill = try importFromFile(at: url)
            if let index = skills.firstIndex(where: { $0.id == skill.id }) {
                skills[index].importSource = .bundled
            }
        }
        try saveMetadata()
    }

    func updateSkillContent(_ skillID: String, content: String) throws {
        guard let existing = skills.first(where: { $0.id == skillID }) else {
            return
        }
        let parsed = Self.parse(skillDocument: content)
        guard !parsed.name.isEmpty else {
            throw SkillStoreError.invalidContent
        }
        _ = try install(
            content: content,
            parsed: parsed,
            id: skillID,
            source: existing.importSource
        )
    }

    func setEnabled(_ skillID: String, enabled: Bool) throws {
        guard let index = skills.firstIndex(where: { $0.id == skillID }) else {
            return
        }
        skills[index].isEnabled = enabled
        skills[index].updatedAt = Date()
        try saveMetadata()
        onEligibleGlobalChange(.upsert(skillID))
    }

    func setConversationOverride(
        skillID: String,
        conversationStreamID: String,
        enabled: Bool
    ) {
        guard let skill = skills.first(where: { $0.id == skillID }) else {
            return
        }
        if enabled == skill.isEnabled {
            overrides[conversationStreamID]?[skillID] = nil
            if overrides[conversationStreamID]?.isEmpty == true {
                overrides[conversationStreamID] = nil
            }
        } else {
            overrides[conversationStreamID, default: [:]][skillID] = enabled
        }
        try? saveOverrides()
        conversationOverrideVersion += 1
    }

    func isEnabled(
        _ skillID: String,
        for conversationStreamID: String?
    ) -> Bool {
        guard let skill = skills.first(where: { $0.id == skillID }) else {
            return false
        }
        guard let conversationStreamID else {
            return skill.isEnabled
        }
        return overrides[conversationStreamID]?[skillID] ?? skill.isEnabled
    }

    func rustDescriptors(
        for conversationStreamID: String?
    ) throws -> [RustSkillDescriptorDTO] {
        skills
            .filter { isEnabled($0.id, for: conversationStreamID) }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.id < $1.id
            }
            .prefix(Self.maximumDescriptors)
            .map {
                RustSkillDescriptorDTO(
                    id: $0.id,
                    name: $0.name,
                    description: String($0.description.prefix(200)),
                    location: "/var/localagent/skills/\($0.id)/SKILL.md",
                    enabled: true
                )
            }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) throws {
        var ordered = skills.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            return $0.id < $1.id
        }
        let moving = fromOffsets.sorted().map { ordered[$0] }
        for index in fromOffsets.sorted(by: >) {
            ordered.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let insertionIndex = min(
            max(0, toOffset - removedBeforeDestination),
            ordered.count
        )
        ordered.insert(contentsOf: moving, at: insertionIndex)
        for index in ordered.indices {
            ordered[index].sortOrder = index
            ordered[index].updatedAt = Date()
        }
        skills = ordered
        try saveMetadata()
    }

    func deleteSkill(_ skillID: String) throws {
        skills.removeAll { $0.id == skillID }
        for streamID in Array(overrides.keys) {
            overrides[streamID]?[skillID] = nil
            if overrides[streamID]?.isEmpty == true {
                overrides[streamID] = nil
            }
        }
        try? fileManager.removeItem(at: skillDirectoryURL(for: skillID))
        try saveMetadata()
        try saveOverrides()
        onEligibleGlobalChange(.delete(skillID))
    }

    func readSkillContent(_ skillID: String) -> String? {
        readSkillFile(skillID, relativePath: "SKILL.md")
    }

    func readSkillFile(
        _ skillID: String,
        relativePath: String
    ) -> String? {
        guard let url = try? safeSkillFileURL(
            skillID: skillID,
            relativePath: relativePath
        ) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func listSkillFiles(_ skillID: String) -> [String] {
        let root = skillDirectoryURL(for: skillID)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL,
                  (try? url.resourceValues(
                      forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true else {
                return nil
            }
            return String(url.path.dropFirst(root.path.count + 1))
        }.sorted()
    }

    private func install(
        content: String,
        parsed: ParsedSkillDocument,
        id: String,
        source: SkillImportSource
    ) throws -> Skill {
        let now = Date()
        let prior = skills.first { $0.id == id }
        let skill = Skill(
            id: id,
            name: parsed.name,
            description: parsed.description,
            version: parsed.version,
            importSource: source,
            isEnabled: prior?.isEnabled ?? true,
            installedAt: prior?.installedAt ?? now,
            updatedAt: now,
            sortOrder: prior?.sortOrder ?? skills.count
        )
        let directory = skillDirectoryURL(for: id)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(
            to: directory.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        if let index = skills.firstIndex(where: { $0.id == id }) {
            skills[index] = skill
        } else {
            skills.append(skill)
        }
        try saveMetadata()
        onEligibleGlobalChange(.upsert(id))
        return skill
    }

    private func importFromDirectory(at directory: URL) throws -> Skill {
        let skillDocument = try locateSkillDocument(in: directory)
        guard let content = try? String(
            contentsOf: skillDocument,
            encoding: .utf8
        ) else {
            throw SkillStoreError.invalidContent
        }
        let skill = try importSkill(content: content, source: .file)
        try copySiblingFiles(
            from: skillDocument.deletingLastPathComponent(),
            to: skillDirectoryURL(for: skill.id)
        )
        return skill
    }

    private func importFromArchive(
        data: Data,
        source: SkillImportSource = .file
    ) throws -> Skill {
        let entries = try Self.readZipEntries(data: data)
        guard let skillEntry = entries
            .filter({ !$0.isDirectory })
            .filter({
                $0.name == "SKILL.md" || $0.name.hasSuffix("/SKILL.md")
            })
            .min(by: {
                $0.name.split(separator: "/").count
                    < $1.name.split(separator: "/").count
            }),
            let content = String(data: skillEntry.data, encoding: .utf8) else {
            throw SkillStoreError.noSkillDocument
        }
        let skill = try importSkill(content: content, source: source)
        let prefix = String(
            skillEntry.name.dropLast("SKILL.md".count)
        )
        let destination = skillDirectoryURL(for: skill.id)
        var totalBytes = 0
        for entry in entries where !entry.isDirectory {
            var relative = entry.name
            if !prefix.isEmpty, relative.hasPrefix(prefix) {
                relative.removeFirst(prefix.count)
            }
            if relative == "SKILL.md" || relative.isEmpty {
                continue
            }
            totalBytes += entry.data.count
            guard totalBytes <= Self.maximumArchiveBytes else {
                throw SkillStoreError.archiveTooLarge
            }
            let file = try safeURL(relativePath: relative, inside: destination)
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.data.write(to: file, options: .atomic)
        }
        return skill
    }

    private func locateSkillDocument(in root: URL) throws -> URL {
        let direct = root.appendingPathComponent("SKILL.md")
        if fileManager.fileExists(atPath: direct.path) {
            return direct
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SkillStoreError.noSkillDocument
        }
        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw SkillStoreError.invalidRelativePath
            }
            if values.isRegularFile == true, url.lastPathComponent == "SKILL.md" {
                candidates.append(url)
            }
        }
        guard let selected = candidates.min(by: {
            $0.pathComponents.count < $1.pathComponents.count
        }) else {
            throw SkillStoreError.noSkillDocument
        }
        return selected
    }

    private func copySiblingFiles(from source: URL, to destination: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard values.isSymbolicLink != true else {
                throw SkillStoreError.invalidRelativePath
            }
            let relative = String(
                url.path.dropFirst(source.path.count + 1)
            )
            if relative == "SKILL.md" || relative.isEmpty {
                continue
            }
            let target = try safeURL(
                relativePath: relative,
                inside: destination
            )
            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
            } else if values.isRegularFile == true {
                totalBytes += values.fileSize ?? 0
                guard totalBytes <= Self.maximumArchiveBytes else {
                    throw SkillStoreError.archiveTooLarge
                }
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: url, to: target)
            }
        }
    }

    private func safeSkillFileURL(
        skillID: String,
        relativePath: String
    ) throws -> URL {
        try safeURL(
            relativePath: relativePath,
            inside: skillDirectoryURL(for: skillID)
        )
    }

    private func safeURL(relativePath: String, inside root: URL) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else {
            throw SkillStoreError.invalidRelativePath
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw SkillStoreError.invalidRelativePath
        }
        let candidate = components.reduce(root) {
            $0.appendingPathComponent($1)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalCandidate = candidate.standardizedFileURL
            .resolvingSymlinksInPath()
        guard canonicalCandidate.path == canonicalRoot.path
                || canonicalCandidate.path.hasPrefix(canonicalRoot.path + "/") else {
            throw SkillStoreError.invalidRelativePath
        }
        return candidate
    }

    private func reconcileFiles() throws {
        let valid = skills.filter {
            fileManager.fileExists(
                atPath: skillDirectoryURL(for: $0.id)
                    .appendingPathComponent("SKILL.md").path
            )
        }
        if valid != skills {
            skills = valid
            try saveMetadata()
        }
    }

    private func saveMetadata() throws {
        try Self.writeJSON(skills, to: metadataURL)
    }

    private func saveOverrides() throws {
        try Self.writeJSON(overrides, to: overridesURL)
    }

    private static func decodeIfPresent<T: Decodable>(
        _ type: T.Type,
        at url: URL
    ) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private static func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private struct ParsedSkillDocument {
    var name = ""
    var description = ""
    var version = "1.0.0"
    var body = ""
}

extension SkillStore {
    private static func parse(
        skillDocument content: String
    ) -> ParsedSkillDocument {
        var result = ParsedSkillDocument()
        let lines = content.components(separatedBy: "\n")
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOpeningFence = trimmed.hasPrefix("---")
        let scanStart = hasOpeningFence ? 1 : 0
        var frontmatterEnd: Int?
        if scanStart < lines.count {
            for index in scanStart..<lines.count
            where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                frontmatterEnd = index
                break
            }
        }
        guard let end = frontmatterEnd else {
            result.body = content
            return result
        }

        if !hasOpeningFence {
            var recognized = false
            let valid = (scanStart..<end).allSatisfy { index in
                let line = lines[index]
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty || line.first?.isWhitespace == true {
                    return true
                }
                guard let colon = line.firstIndex(of: ":") else {
                    return false
                }
                let key = line[..<colon].trimmingCharacters(
                    in: .whitespaces
                ).lowercased()
                if ["name", "description", "version"].contains(key) {
                    recognized = true
                }
                return key.allSatisfy {
                    $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
                }
            }
            guard valid, recognized else {
                result.body = content
                return result
            }
        }

        var index = scanStart
        while index < end {
            let line = lines[index]
            guard let colon = line.firstIndex(of: ":") else {
                index += 1
                continue
            }
            let key = line[..<colon].trimmingCharacters(
                in: .whitespaces
            ).lowercased()
            let rawValue = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            let value: String
            if let first = rawValue.first,
               first == "|" || first == ">",
               rawValue.dropFirst().allSatisfy({
                   $0 == "-" || $0 == "+" || $0.isNumber
               }) {
                var block: [String] = []
                var next = index + 1
                while next < end {
                    let line = lines[next]
                    guard line.isEmpty || line.first?.isWhitespace == true else {
                        break
                    }
                    block.append(
                        line.trimmingCharacters(in: .whitespaces)
                    )
                    next += 1
                }
                value = block.joined(
                    separator: first == ">" ? " " : "\n"
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                index = next
            } else {
                value = String(rawValue)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                index += 1
            }
            switch key {
            case "name":
                result.name = value
            case "description":
                result.description = value
            case "version":
                result.version = value
            default:
                break
            }
        }
        if end + 1 < lines.count {
            result.body = lines[(end + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }
        return result
    }

    static func slugify(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-")
        )
        return name.lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static func downloadURL(from raw: String) throws -> URL {
        let normalized = raw.hasPrefix("http://") || raw.hasPrefix("https://")
            ? raw
            : "https://\(raw)"
        guard let url = URL(string: normalized) else {
            throw SkillStoreError.invalidURL
        }
        if url.host == "raw.githubusercontent.com" {
            return url.lastPathComponent.uppercased() == "SKILL.MD"
                ? url
                : url.appendingPathComponent("SKILL.md")
        }
        guard url.host == "github.com" else {
            return url
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4,
              parts[2] == "blob" || parts[2] == "tree" else {
            throw SkillStoreError.invalidURL
        }
        var path = parts.dropFirst(4).joined(separator: "/")
        if !path.hasSuffix("SKILL.md") {
            path = path.isEmpty ? "SKILL.md" : "\(path)/SKILL.md"
        }
        guard let rawURL = URL(
            string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/\(parts[3])/\(path)"
        ) else {
            throw SkillStoreError.invalidURL
        }
        return rawURL
    }

    private static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4
            && data[0] == 0x50
            && data[1] == 0x4B
            && [0x03, 0x05, 0x07].contains(data[2])
    }
}

extension SkillStore {
    private struct ZipEntry {
        let name: String
        let isDirectory: Bool
        let data: Data
    }

    private static func readZipEntries(data: Data) throws -> [ZipEntry] {
        guard data.count >= 22 else {
            throw SkillStoreError.invalidArchive
        }
        var endOffset = -1
        let searchStart = max(0, data.count - 65_557)
        for index in stride(
            from: data.count - 22,
            through: searchStart,
            by: -1
        ) {
            if data[index] == 0x50,
               data[index + 1] == 0x4B,
               data[index + 2] == 0x05,
               data[index + 3] == 0x06 {
                endOffset = index
                break
            }
        }
        guard endOffset >= 0 else {
            throw SkillStoreError.invalidArchive
        }
        let entryCount = Int(readU16(data, at: endOffset + 10))
        guard entryCount <= maximumArchiveEntries else {
            throw SkillStoreError.archiveTooLarge
        }
        var position = Int(readU32(data, at: endOffset + 16))
        var output: [ZipEntry] = []
        var totalBytes = 0

        for _ in 0..<entryCount {
            guard position + 46 <= data.count,
                  readU32(data, at: position) == 0x02014B50 else {
                throw SkillStoreError.invalidArchive
            }
            let method = readU16(data, at: position + 10)
            let compressedSize = Int(readU32(data, at: position + 20))
            let uncompressedSize = Int(readU32(data, at: position + 24))
            let nameLength = Int(readU16(data, at: position + 28))
            let extraLength = Int(readU16(data, at: position + 30))
            let commentLength = Int(readU16(data, at: position + 32))
            let localOffset = Int(readU32(data, at: position + 42))
            guard position + 46 + nameLength <= data.count else {
                throw SkillStoreError.invalidArchive
            }
            let name = String(
                data: data[(position + 46)..<(position + 46 + nameLength)],
                encoding: .utf8
            ) ?? ""
            try validateArchivePath(name)
            position += 46 + nameLength + extraLength + commentLength

            guard localOffset + 30 <= data.count else {
                throw SkillStoreError.invalidArchive
            }
            let localNameLength = Int(readU16(data, at: localOffset + 26))
            let localExtraLength = Int(readU16(data, at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard compressedSize >= 0,
                  dataStart >= 0,
                  dataStart + compressedSize <= data.count else {
                throw SkillStoreError.invalidArchive
            }
            totalBytes += uncompressedSize
            guard totalBytes <= maximumArchiveBytes else {
                throw SkillStoreError.archiveTooLarge
            }
            let isDirectory = name.hasSuffix("/")
            let compressed = Data(
                data[dataStart..<(dataStart + compressedSize)]
            )
            let bytes: Data
            if isDirectory || uncompressedSize == 0 {
                bytes = Data()
            } else if method == 0 {
                bytes = compressed
            } else if method == 8,
                      let inflated = inflate(
                          compressed,
                          expectedSize: uncompressedSize
                      ) {
                bytes = inflated
            } else {
                throw SkillStoreError.invalidArchive
            }
            output.append(
                ZipEntry(
                    name: name,
                    isDirectory: isDirectory,
                    data: bytes
                )
            )
        }
        return output
    }

    private static func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0") else {
            throw SkillStoreError.unsafeArchivePath
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw SkillStoreError.unsafeArchivePath
        }
    }

    private static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func inflate(
        _ data: Data,
        expectedSize: Int
    ) -> Data? {
        guard expectedSize > 0 else {
            return Data()
        }
        var output = Data(count: expectedSize)
        let count = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    expectedSize,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard count == expectedSize else {
            return nil
        }
        return output
    }
}
