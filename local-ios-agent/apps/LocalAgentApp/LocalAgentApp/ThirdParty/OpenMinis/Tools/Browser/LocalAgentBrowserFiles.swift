import Foundation

enum LocalAgentBrowserFiles {
    static func workspace(
        for sessionID: String,
        mounts: [ToolFileResolver.HostMount: ToolFileResolver.MountConfiguration]
            = LocalAgentToolMounts.configurations()
    ) -> URL {
        let shared = mounts[.shared]!.rootURL
        return shared
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(safeComponent(sessionID), isDirectory: true)
    }

    static func resolve(
        _ url: URL,
        mounts: [ToolFileResolver.HostMount: ToolFileResolver.MountConfiguration]
            = LocalAgentToolMounts.configurations()
    ) -> URL? {
        guard url.scheme == "localagent", let host = url.host else { return nil }
        let decoded = url.path.removingPercentEncoding ?? url.path
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }

        guard let mount = ToolFileResolver.HostMount(rawValue: host),
              let root = mounts[mount]?.rootURL else {
            return nil
        }

        let candidate = components.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalCandidate.path == canonicalRoot.path
                || canonicalCandidate.path.hasPrefix(canonicalRoot.path + "/") else {
            return nil
        }
        return FileManager.default.fileExists(atPath: canonicalCandidate.path)
            ? canonicalCandidate
            : nil
    }

    static func safeComponent(_ raw: String) -> String {
        let value = raw.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "_",
            options: .regularExpression
        )
        return value == "." || value == ".." || value.isEmpty ? "download" : value
    }

    static func downloadToolURL(sessionID: String, filename: String) -> String {
        "localagent://shared/downloads/\(safeComponent(sessionID))/\(safeComponent(filename))"
    }

    static func downloadLinuxPath(sessionID: String, filename: String) -> String {
        "/var/localagent/shared/downloads/\(safeComponent(sessionID))/\(safeComponent(filename))"
    }
}
