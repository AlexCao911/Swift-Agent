import Foundation
import LocalAgentLLMCloud

/// The non-secret part of an OpenMinis provider instance.
///
/// Credentials deliberately live outside this Codable value and are handed to
/// LocalAgent's existing credential vault only when a profile revision is
/// published.
struct OpenMinisProviderConfiguration: Codable, Equatable, Sendable {
    let id: String
    let rawProviderType: String
    let displayName: String
    let credentialMode: ProviderCredentialMode
    let customBaseURL: URL?
    let appendsV1: Bool
}

struct OpenMinisProviderConfigurationError: Error, Equatable, LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

enum OpenMinisProviderConfigurationAdapter {
    static func makeDraft(
        _ configuration: OpenMinisProviderConfiguration,
        replacingRevision: UInt64? = nil,
        retentionMode: ProviderRetentionMode = .statelessRequired,
        secret: SecretBytes?
    ) throws -> ProviderProfileProductDraft {
        let mapping = ProviderProductCompatibility.mapping(
            rawProviderType: configuration.rawProviderType
        )
        guard mapping.isGenerationSupported,
              let presetID = mapping.presetID
        else {
            throw failure(
                "provider.unsupported",
                "This provider type is preserved but is not executable in this build."
            )
        }
        guard mapping.credentialModes.contains(configuration.credentialMode) else {
            throw failure(
                "provider.credential_mode_unsupported",
                "The selected credential mode is not supported by this provider."
            )
        }
        guard let preset = ProviderPreset.shipped.first(where: {
            $0.id == presetID
        }) else {
            throw failure(
                "provider.preset_missing",
                "The provider preset is unavailable."
            )
        }

        return ProviderProfileProductDraft(
            profileID: configuration.id,
            replacingRevision: replacingRevision,
            presetID: presetID,
            displayName: configuration.displayName,
            baseURL: try effectiveBaseURL(
                custom: configuration.customBaseURL,
                preset: preset,
                appendsV1: configuration.appendsV1
            ),
            retentionMode: retentionMode,
            credentialMode: configuration.credentialMode,
            initialSecret: secret
        )
    }

    static func rawProviderType(for presetID: ProviderPresetID) -> String? {
        [
            "openAI",
            "openAIResponses",
            "anthropic",
            "gemini",
            "openRouter",
            "xAI",
            "kimiCode",
            "antigravity",
        ].first {
            ProviderProductCompatibility.mapping(rawProviderType: $0).presetID
                == presetID
        }
    }

    private static func effectiveBaseURL(
        custom: URL?,
        preset: ProviderPreset,
        appendsV1: Bool
    ) throws -> URL {
        guard let custom else { return preset.defaultBaseURL }
        guard custom.scheme?.lowercased() == "https", custom.host != nil else {
            throw failure(
                "provider.base_url_invalid",
                "Base URL must be an exact HTTPS URL."
            )
        }
        guard appendsV1 else { return custom }

        var components = URLComponents(
            url: custom,
            resolvingAgainstBaseURL: false
        )
        let path = components?.path ?? ""
        if path.isEmpty || path == "/" {
            components?.path = "/v1"
        } else if !path.hasSuffix("/v1") {
            components?.path = path.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            ).withLeadingSlash + "/v1"
        }
        guard let result = components?.url else {
            throw failure(
                "provider.base_url_invalid",
                "Base URL could not be normalized."
            )
        }
        return result
    }

    private static func failure(
        _ code: String,
        _ message: String
    ) -> OpenMinisProviderConfigurationError {
        OpenMinisProviderConfigurationError(code: code, message: message)
    }
}

private extension String {
    var withLeadingSlash: String {
        hasPrefix("/") ? self : "/\(self)"
    }
}
