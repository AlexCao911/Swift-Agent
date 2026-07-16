import Foundation
import Testing
@testable import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore

@Suite("Cloud provider boundary")
struct CloudProviderBoundaryTests {
    @Test
    func providerPresetIDsAreStableProviderNeutralIdentities() throws {
        let values: [ProviderPresetID] = [
            .openAI, .anthropic, .gemini, .xAI, .deepSeek, .miniMax, .glm,
        ]

        #expect(values.map(\.rawValue) == [
            "openai", "anthropic", "gemini", "xai", "deepseek", "minimax", "glm",
        ])
        #expect(try JSONDecoder().decode(
            ProviderPresetID.self,
            from: JSONEncoder().encode(ProviderPresetID.openAI)
        ) == .openAI)
    }

    @Test
    func wireRequestIsRelativeAndContainsNoCredentialField() throws {
        let request = try CloudWireRequest(
            method: "POST",
            path: "/responses",
            queryItems: [],
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"stream":true}"#.utf8)
        )

        #expect(request.method == "POST")
        #expect(request.path == "/responses")
        #expect(!request.headers.keys.contains(where: {
            ["authorization", "x-api-key", "x-goog-api-key"].contains($0.lowercased())
        }))
        #expect(!String(reflecting: request).lowercased().contains("credential"))
    }

    @Test
    func wireRequestRejectsAbsoluteURLsAndAuthenticationMaterial() {
        #expect(throws: CloudWireRequestFailure.self) {
            try CloudWireRequest(
                method: "POST",
                path: "https://api.example.com/responses",
                queryItems: [],
                headers: [:],
                body: nil
            )
        }
        #expect(throws: CloudWireRequestFailure.self) {
            try CloudWireRequest(
                method: "POST",
                path: "/responses",
                queryItems: [],
                headers: ["Authorization": "Bearer fixture-secret"],
                body: nil
            )
        }
        #expect(throws: CloudWireRequestFailure.self) {
            try CloudWireRequest(
                method: "POST",
                path: "/responses",
                queryItems: [URLQueryItem(name: "api_key", value: "fixture-secret")],
                headers: [:],
                body: nil
            )
        }
        #expect(throws: CloudWireRequestFailure.self) {
            try CloudWireRequest(
                method: "POST",
                path: "/responses?api_key=fixture-secret",
                queryItems: [],
                headers: [:],
                body: nil
            )
        }
    }

    @Test
    func cloudTargetDoesNotLeakIntoRustCppOrLocalRuntimeSources() throws {
        let root = repositoryRoot
        for relativePath in ["rust-core", "inference"] {
            let files = try recursiveSourceFiles(root.appendingPathComponent(relativePath))
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(!source.contains("LocalAgentLLMCloud"), "forbidden cloud dependency in \(file.path)")
            }
        }
        for relativePath in [
            "toolkit/Sources/LocalAgentLLMLocal",
            "apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterView.swift",
            "apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterViewModel.swift",
        ] {
            let url = root.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
            #expect(exists, "expected boundary path is missing: \(url.path)")
            let files = isDirectory.boolValue ? try recursiveSourceFiles(url) : [url]
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(!source.contains("import LocalAgentLLMCloud"), "forbidden import in \(file.path)")
            }
        }
    }

    @Test
    func cloudTargetHasNoProviderSDKAppUIOrLocalInferenceDependency() throws {
        let cloudRoot = repositoryRoot.appendingPathComponent("toolkit/Sources/LocalAgentLLMCloud")
        let source = try recursiveSourceFiles(cloudRoot)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        #expect(!source.contains("import LocalAgentLLMLocal"))
        #expect(!source.contains("import LocalAgentBridge"))
        #expect(!source.contains("SwiftUI"))
        #expect(!source.contains("OpenAIKit"))
        #expect(!source.contains("AnthropicSDK"))
        #expect(!source.contains("GoogleGenerativeAI"))
    }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func recursiveSourceFiles(_ root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    return enumerator.compactMap { item in
        guard let url = item as? URL,
              ["swift", "rs", "c", "cc", "cpp", "h", "hpp"].contains(url.pathExtension)
        else {
            return nil
        }
        return url
    }
}
