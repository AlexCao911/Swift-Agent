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
            "OpenMinisContentView.swift in Sources",
            "OpenMinisChatView.swift in Sources",
            "OpenMinisProviderInstancesView.swift in Sources",
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

    @Test("OpenMinis navigation and chat surfaces own the shipping shell")
    func openMinisSurfacesOwnShippingShell() throws {
        let appRoot = appRootURL().appendingPathComponent("LocalAgentApp")
        let shell = try String(
            contentsOf: appRoot.appendingPathComponent("App/AppShellView.swift"),
            encoding: .utf8
        )
        let content = try String(
            contentsOf: appRoot.appendingPathComponent(
                "ThirdParty/OpenMinis/Product/OpenMinisContentView.swift"
            ),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: appRoot.appendingPathComponent(
                "ThirdParty/OpenMinis/Product/OpenMinisChatView.swift"
            ),
            encoding: .utf8
        )
        let project = try String(contentsOf: projectFileURL(), encoding: .utf8)

        #expect(shell.contains("OpenMinisContentView("))
        #expect(!shell.contains("TabView("))
        #expect(content.contains("NavigationSplitView"))
        #expect(content.contains("NavigationStack"))
        #expect(content.contains("OpenMinisChatView("))
        #expect(content.contains("NavigationSplitView(columnVisibility:"))
        #expect(content.contains("DraggableFAB("))
        #expect(content.contains("OpenMinisSettingsSheet("))
        #expect(content.contains("activeToolSheet"))
        #expect(chat.contains("struct OpenMinisChatView"))
        #expect(project.contains("OpenMinisContentView.swift in Sources"))
        #expect(project.contains("OpenMinisChatView.swift in Sources"))
        #expect(!project.contains("OpenMinisProductShellView.swift in Sources"))
    }

    @Test("OpenMinis model picker keeps the donor provider-section interaction")
    func openMinisModelPickerKeepsDonorInteraction() throws {
        let picker = try String(
            contentsOf: appRootURL().appendingPathComponent(
                "LocalAgentApp/ThirdParty/OpenMinis/Providers/UnifiedModelPicker.swift"
            ),
            encoding: .utf8
        )

        for donorInteraction in [
            "collapsedProviderIDs",
            "providerSection(",
            "Show \\(provider.options.count) models",
            "navigationBarDrawer(displayMode: .always)",
            "checkmark.circle.fill",
        ] {
            #expect(
                picker.contains(donorInteraction),
                "Missing OpenMinis model-picker interaction: \(donorInteraction)"
            )
        }
    }

    @Test("LocalAgent product screens are embedded in the OpenMinis settings flow")
    func localProductScreensAreEmbeddedInOpenMinisSettings() throws {
        let content = try String(
            contentsOf: appRootURL().appendingPathComponent(
                "LocalAgentApp/ThirdParty/OpenMinis/Product/OpenMinisContentView.swift"
            ),
            encoding: .utf8
        )

        for productView in [
            "AgentBuilderView(",
            "ModelCenterView(",
            "OpenMinisProviderInstancesView(",
            "ToolCenterView(",
            "PrivacySettingsView(",
            "AppearanceSettingsView(",
            "AboutLocalAgentView(",
        ] {
            #expect(
                content.contains(productView),
                "Missing LocalAgent product destination: \(productView)"
            )
        }
    }

    @Test("settings use monochrome SF Symbols and chat exposes slash Skills")
    func settingsAndSlashSkillsUseNativePresentation() throws {
        let appRoot = appRootURL().appendingPathComponent("LocalAgentApp")
        let content = try String(
            contentsOf: appRoot.appendingPathComponent(
                "ThirdParty/OpenMinis/Product/OpenMinisContentView.swift"
            ),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: appRoot.appendingPathComponent(
                "ThirdParty/OpenMinis/Product/OpenMinisChatView.swift"
            ),
            encoding: .utf8
        )

        #expect(!content.contains(".background(color, in: Circle())"))
        #expect(chat.contains("slashSkillMatches"))
        #expect(chat.contains("activateFromSlash"))
    }

    @Test("migrated provider surfaces cannot bypass the LocalAgent transport boundary")
    func migratedProviderSurfacesCannotBypassTransportBoundary() throws {
        let providersRoot = appRootURL().appendingPathComponent(
            "LocalAgentApp/ThirdParty/OpenMinis/Providers"
        )
        let sourceFiles = try FileManager.default
            .subpathsOfDirectory(atPath: providersRoot.path)
            .filter { $0.hasSuffix(".swift") }
        let sources = try sourceFiles
            .map {
                try String(
                    contentsOf: providersRoot.appendingPathComponent($0),
                    encoding: .utf8
                )
            }
            .joined(separator: "\n")

        for forbidden in [
            "URLSession.shared",
            ".data(for:",
            ".bytes(for:",
            "ASWebAuthenticationSession",
        ] {
            #expect(
                !sources.contains(forbidden),
                "Migrated provider UI bypasses the LocalAgent transport boundary: \(forbidden)"
            )
        }

        let editor = try String(
            contentsOf: appRootURL().appendingPathComponent(
                "LocalAgentApp/Presentation/Models/ProviderProfileEditorView.swift"
            ),
            encoding: .utf8
        )
        #expect(editor.contains("OAuthCallbackServer"))
        #expect(editor.contains("SFSafariViewController"))
        #expect(!editor.contains("ASWebAuthenticationSession"))
    }

    @Test("shipping target relies on the signed LocalAgent catalog, not a miniature donor resource")
    func shippingTargetDoesNotShipAnInertOpenMinisModelMetadataResource() throws {
        let resource = appRootURL().appendingPathComponent(
            "LocalAgentApp/Resources/models-dev-api.json"
        )
        #expect(!FileManager.default.fileExists(atPath: resource.path))

        let project = try String(contentsOf: projectFileURL(), encoding: .utf8)
        #expect(!project.contains("models-dev-api.json"))

        let discovery = try String(
            contentsOf: appRootURL().appendingPathComponent(
                "../../toolkit/Sources/LocalAgentLLMCloud/CloudModelDiscoveryService.swift"
            ).standardized,
            encoding: .utf8
        )
        #expect(discovery.contains("case signedCatalog"))
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
