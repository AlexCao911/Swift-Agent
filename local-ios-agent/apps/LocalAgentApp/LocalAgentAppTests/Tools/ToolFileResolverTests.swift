import Foundation
import Testing
@testable import LocalAgentApp

@Suite("OpenMinis virtual tool file resolver")
struct ToolFileResolverTests {
    @Test
    func routesOrdinaryLinuxPathsToGuestRootfs() throws {
        let fixture = try ResolverFixture()

        for path in ["/tmp/result.txt", "/root/.config/tool.json", "/usr/bin/env"] {
            let resolved = try fixture.resolver.resolve(path, access: .read)
            guard case let .guestRootfs(linuxPath, _) = resolved.backend else {
                Issue.record("Expected guest rootfs backend for \(path)")
                continue
            }
            #expect(linuxPath == path)
        }
    }

    @Test
    func routesStableVirtualSkillPathWithoutExposingHostRoot() throws {
        let fixture = try ResolverFixture()
        let resolved = try fixture.resolver.resolve(
            "/var/localagent/skills/demo/SKILL.md",
            access: .read
        )

        guard case let .hostMount(mount, localURL) = resolved.backend else {
            Issue.record("Expected host mount")
            return
        }
        #expect(mount == .skills)
        #expect(localURL.lastPathComponent == "SKILL.md")
        #expect(resolved.toolPath == "/var/localagent/skills/demo/SKILL.md")
        #expect(resolved.toolPath.contains(fixture.root.path) == false)
    }

    @Test
    func rejectsTraversalUnknownNamespacesAndReadOnlyWrites() throws {
        let fixture = try ResolverFixture()

        #expect(throws: ToolFileResolverError.self) {
            try fixture.resolver.resolve(
                "/var/localagent/skills/../shared/secret",
                access: .read
            )
        }
        #expect(throws: ToolFileResolverError.self) {
            try fixture.resolver.resolve("/var/localagent/private/secret", access: .read)
        }
        #expect(throws: ToolFileResolverError.self) {
            try fixture.resolver.resolve(
                "/var/localagent/mounts/read-only.txt",
                access: .write
            )
        }
    }

    @Test
    func rejectsHostAndGuestSymlinkEscapesButAllowsContainedGuestSymlink() throws {
        let fixture = try ResolverFixture()
        let fileManager = FileManager.default

        let guestTarget = fixture.guestRoot.appendingPathComponent("tmp/inside", isDirectory: true)
        try fileManager.createDirectory(at: guestTarget, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: fixture.guestRoot.appendingPathComponent("tmp/link"),
            withDestinationURL: guestTarget
        )
        let contained = try fixture.resolver.resolve("/tmp/link/file.txt", access: .write)
        guard case .guestRootfs = contained.backend else {
            Issue.record("Expected contained guest symlink to remain in guest backend")
            return
        }

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: fixture.guestRoot.appendingPathComponent("tmp/escape"),
            withDestinationURL: outside
        )
        #expect(throws: ToolFileResolverError.self) {
            try fixture.resolver.resolve("/tmp/escape/secret", access: .read)
        }

        try fileManager.createSymbolicLink(
            at: fixture.skillsRoot.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        #expect(throws: ToolFileResolverError.self) {
            try fixture.resolver.resolve(
                "/var/localagent/skills/escape/secret",
                access: .read
            )
        }
    }
}

private struct ResolverFixture {
    let root: URL
    let guestRoot: URL
    let skillsRoot: URL
    let resolver: ToolFileResolver

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guestRoot = root.appendingPathComponent("guest", isDirectory: true)
        skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let sharedRoot = root.appendingPathComponent("shared", isDirectory: true)
        let attachmentsRoot = root.appendingPathComponent("attachments", isDirectory: true)
        let mountsRoot = root.appendingPathComponent("mounts", isDirectory: true)
        for directory in [guestRoot, skillsRoot, sharedRoot, attachmentsRoot, mountsRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: guestRoot.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        resolver = ToolFileResolver(
            guestRootURL: guestRoot,
            hostMounts: [
                .skills: .init(rootURL: skillsRoot, isWritable: false),
                .shared: .init(rootURL: sharedRoot, isWritable: true),
                .attachments: .init(rootURL: attachmentsRoot, isWritable: false),
                .mounts: .init(rootURL: mountsRoot, isWritable: false),
            ]
        )
    }
}
