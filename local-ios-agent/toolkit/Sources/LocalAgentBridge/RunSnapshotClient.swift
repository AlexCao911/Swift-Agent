public protocol RunSnapshotClient: Sendable {
    func previewSnapshot(_ profileId: String) async throws -> RunSnapshotPreviewUIModel
    func readiness(_ profileId: String) async throws -> RunSnapshotReadinessUIModel
}

public actor MockRunSnapshotClient: RunSnapshotClient {
    private let model: RunSnapshotReadinessUIModel

    public init(model: RunSnapshotReadinessUIModel) {
        self.model = model
    }

    public static func ready(profileId: String) -> Self {
        Self(model: RunSnapshotReadinessUIModel(profileId: profileId, isReady: true))
    }

    public static func blocked(profileId: String, issues: [PermissionIssueDTO]) -> Self {
        Self(model: RunSnapshotReadinessUIModel(profileId: profileId, isReady: false, issues: issues))
    }

    public func previewSnapshot(_ profileId: String) async throws -> RunSnapshotPreviewUIModel {
        RunSnapshotPreviewUIModel(profileId: profileId, isReady: model.isReady, issues: model.issues)
    }

    public func readiness(_ profileId: String) async throws -> RunSnapshotReadinessUIModel {
        RunSnapshotReadinessUIModel(profileId: profileId, isReady: model.isReady, issues: model.issues)
    }
}
