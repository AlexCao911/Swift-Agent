import Foundation

public protocol AgentPackageClient: Sendable {
    func inspectPackage(_ url: URL) async throws -> PackageInspectReportDTO
    func previewInstall(_ url: URL) async throws -> PackageInstallPreviewUIModel
    func installPackage(_ request: PackageInstallRequestDTO) async throws -> AgentProfileDTO
}

public actor MockAgentPackageClient: AgentPackageClient {
    private let preview: PackageInstallPreviewUIModel

    public init(preview: PackageInstallPreviewUIModel) {
        self.preview = preview
    }

    public static func previewing(profileName: String) -> Self {
        Self(preview: PackageInstallPreviewUIModel(
            profileName: profileName,
            operations: [
                PackageInstallOperationUIModel(code: "profile.create", title: "Create profile"),
                PackageInstallOperationUIModel(code: "model_binding.create", title: "Bind model"),
            ]
        ))
    }

    public func inspectPackage(_ url: URL) async throws -> PackageInspectReportDTO {
        PackageInspectReportDTO(packageName: url.lastPathComponent, issues: preview.issues)
    }

    public func previewInstall(_ url: URL) async throws -> PackageInstallPreviewUIModel {
        preview
    }

    public func installPackage(_ request: PackageInstallRequestDTO) async throws -> AgentProfileDTO {
        AgentProfileDTO(
            profileId: "profile_1",
            profileRevisionId: 1,
            displayName: preview.profileName
        )
    }
}
