import Foundation
import Testing

@Suite("Shipping target ownership")
struct ShippingTargetOwnershipTests {
    @Test("LocalAgent remains the only shipping app")
    func localAgentRemainsTheOnlyShippingApp() throws {
        let project = try String(
            contentsOf: projectFileURL(),
            encoding: .utf8
        )

        #expect(project.contains("productName = LocalAgentApp;"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.localagent.app;"))
        #expect(!project.contains("productName = Minis;"))
        #expect(!project.contains("Minis.xcodeproj"))
    }

    @Test("migrated chat code remains presentation only")
    func migratedChatCodeRemainsPresentationOnly() throws {
        let sourceRoot = appRootURL()
            .appendingPathComponent("LocalAgentApp/ThirdParty/OpenMinis")
        let sourceFiles = try FileManager.default
            .subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
        let sources = try sourceFiles
            .map { try String(contentsOf: sourceRoot.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        for forbidden in [
            "runAgentLoop(",
            "SystemPromptBuilder",
            "SwiftAnthropic",
            "AnthropicService",
            "OpenAIService",
            "skillPromptFragment",
            "memory injection",
        ] {
            #expect(!sources.contains(forbidden), "Found forbidden agent/runtime dependency: \(forbidden)")
        }

        let project = try String(contentsOf: projectFileURL(), encoding: .utf8)
        for source in [
            "AIChatViewModel.swift in Sources",
            "ChatStore.swift in Sources",
            "OpenMinisProductShellView.swift in Sources",
            "MinisMarkdownParser.swift in Sources",
            "SwiftMathRenderer.swift in Sources",
            "KaTeXRenderer.swift in Sources",
            "OpenMinisMarkdownView.swift in Sources",
        ] {
            #expect(project.contains(source), "Missing Xcode source membership for \(source)")
        }
        #expect(project.contains("KaTeX in Resources"))
        #expect(project.contains("GPL-3.0.txt in Resources"))
        #expect(project.contains("THIRD_PARTY_LICENSES.md in Resources"))
    }

    private func appRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func projectFileURL() -> URL {
        appRootURL()
            .appendingPathComponent("LocalAgentApp.xcodeproj/project.pbxproj")
    }
}
