public protocol PermissionClient: Sendable {
    func readiness(_ requirements: [CapabilityRequirementDTO]) async throws -> PermissionReadinessUIModel
}

public actor MockPermissionClient: PermissionClient {
    private let model: PermissionReadinessUIModel

    public init(issues: [PermissionIssueDTO] = []) {
        self.model = PermissionReadinessUIModel(issues: issues)
    }

    public func readiness(_ requirements: [CapabilityRequirementDTO]) async throws -> PermissionReadinessUIModel {
        model
    }
}
