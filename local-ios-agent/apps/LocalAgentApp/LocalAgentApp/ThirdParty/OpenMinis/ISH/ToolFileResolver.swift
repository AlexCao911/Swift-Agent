import Foundation

enum FileAccess: String, Codable, Sendable {
    case read
    case write
}

enum ResolvedFileBackend: Sendable {
    case guestRootfs(linuxPath: String, localURL: URL)
    case hostMount(mount: ToolFileResolver.HostMount, localURL: URL)
}

struct ResolvedToolFile: Sendable {
    let toolPath: String
    let backend: ResolvedFileBackend
    let access: FileAccess
}

struct ToolFileResolverError: Error, Equatable, Sendable {
    let code: String
}

struct ToolFileResolver: Sendable {
    enum HostMount: String, CaseIterable, Sendable {
        case skills
        case shared
        case attachments
        case mounts
    }

    struct MountConfiguration: Sendable {
        let rootURL: URL
        let isWritable: Bool
    }

    private let guestRootURL: URL
    private let hostMounts: [HostMount: MountConfiguration]

    init(
        guestRootURL: URL,
        hostMounts: [HostMount: MountConfiguration]
    ) {
        self.guestRootURL = guestRootURL
        self.hostMounts = hostMounts
    }

    func resolve(
        _ toolPath: String,
        access: FileAccess
    ) throws -> ResolvedToolFile {
        let components = try normalizedComponents(of: toolPath)

        if components.count >= 2,
           components[0] == "var",
           components[1] == "localagent" {
            return try resolveHostMount(
                toolPath: toolPath,
                components: components,
                access: access
            )
        }

        let candidate = components.reduce(guestRootURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        try requireContained(candidate, within: guestRootURL)
        return ResolvedToolFile(
            toolPath: toolPath,
            backend: .guestRootfs(linuxPath: toolPath, localURL: candidate),
            access: access
        )
    }

    private func resolveHostMount(
        toolPath: String,
        components: [String],
        access: FileAccess
    ) throws -> ResolvedToolFile {
        guard components.count >= 3,
              let mount = HostMount(rawValue: components[2]),
              let configuration = hostMounts[mount] else {
            throw ToolFileResolverError(code: "tool_file.unknown_host_mount")
        }
        if access == .write, configuration.isWritable == false {
            throw ToolFileResolverError(code: "tool_file.mount_read_only")
        }

        let candidate = components.dropFirst(3).reduce(configuration.rootURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        try requireContained(candidate, within: configuration.rootURL)
        return ResolvedToolFile(
            toolPath: toolPath,
            backend: .hostMount(mount: mount, localURL: candidate),
            access: access
        )
    }

    private func normalizedComponents(of path: String) throws -> [String] {
        guard path.first == "/", path.contains("\0") == false else {
            throw ToolFileResolverError(code: "tool_file.path_not_absolute")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ToolFileResolverError(code: "tool_file.path_not_normalized")
        }
        return components
    }

    private func requireContained(_ candidate: URL, within root: URL) throws {
        let standardizedRoot = root.standardizedFileURL
        let standardizedCandidate = candidate.standardizedFileURL
        guard isContained(standardizedCandidate, within: standardizedRoot) else {
            throw ToolFileResolverError(code: "tool_file.symlink_escape")
        }

        var existingAncestor = standardizedCandidate
        while existingAncestor.path != standardizedRoot.path,
              FileManager.default.fileExists(atPath: existingAncestor.path) == false {
            existingAncestor.deleteLastPathComponent()
        }

        let canonicalRoot = standardizedRoot.resolvingSymlinksInPath()
        let canonicalAncestor = existingAncestor.resolvingSymlinksInPath()
        guard isContained(canonicalAncestor, within: canonicalRoot) else {
            throw ToolFileResolverError(code: "tool_file.symlink_escape")
        }
    }

    private func isContained(_ candidate: URL, within root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/")
            ? String(root.path.dropLast())
            : root.path
        return candidate.path == rootPath
            || candidate.path.hasPrefix(rootPath + "/")
    }
}

enum LocalAgentToolMounts {
    private static var baseURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("LocalAgent/ToolMounts", isDirectory: true)
    }

    static func configurations() -> [ToolFileResolver.HostMount: ToolFileResolver.MountConfiguration] {
        let base = baseURL
        let mounts: [ToolFileResolver.HostMount: ToolFileResolver.MountConfiguration] = [
            .skills: .init(
                rootURL: base.appendingPathComponent("skills", isDirectory: true),
                isWritable: false
            ),
            .shared: .init(
                rootURL: base.appendingPathComponent("shared", isDirectory: true),
                isWritable: true
            ),
            .attachments: .init(
                rootURL: base.appendingPathComponent("attachments", isDirectory: true),
                isWritable: false
            ),
            .mounts: .init(
                rootURL: base.appendingPathComponent("mounts", isDirectory: true),
                isWritable: false
            ),
        ]
        for configuration in mounts.values {
            try? FileManager.default.createDirectory(
                at: configuration.rootURL,
                withIntermediateDirectories: true
            )
        }
        return mounts
    }

    static func makeDefaultResolver() -> ToolFileResolver {
        return ToolFileResolver(
            guestRootURL: RootfsManager.shared.dataPath,
            hostMounts: configurations()
        )
    }
}
