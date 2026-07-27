public protocol LegacyProfileMigrationClient: Sendable {
    func begin(
        _ request: BeginLegacyProfileMigrationDTO
    ) async throws -> LegacyMigrationActionDTO
    func records() async throws -> [LegacyProfileMigrationRecordDTO]
    func actions() async throws -> [LegacyMigrationActionDTO]
    func prepareProfilePublish(
        _ request: ProfilePublishPreparationDTO
    ) async throws -> HostBindingOperationDTO
    func commitProfilePublish(
        _ request: HostBindingCommitDTO
    ) async throws -> HostBindingCrossLinkDTO
    func complete(
        _ confirmation: HostBindingActivationConfirmationDTO
    ) async throws -> LegacyProfileMigrationRecordDTO
}

public struct RustLegacyProfileMigrationClient: LegacyProfileMigrationClient {
    private let gateway: any RustAgentOSBridgeGateway

    public init(gateway: any RustAgentOSBridgeGateway) {
        self.gateway = gateway
    }

    public func begin(
        _ request: BeginLegacyProfileMigrationDTO
    ) async throws -> LegacyMigrationActionDTO {
        try await gateway.request(
            .beginLegacyProfileMigration,
            request,
            as: LegacyMigrationActionDTO.self
        )
    }

    public func records() async throws -> [LegacyProfileMigrationRecordDTO] {
        try await gateway.request(
            .listLegacyProfileMigrations,
            EmptyAgentOSRequestDTO(),
            as: [LegacyProfileMigrationRecordDTO].self
        )
    }

    public func actions() async throws -> [LegacyMigrationActionDTO] {
        try await gateway.request(
            .listLegacyProfileMigrationActions,
            EmptyAgentOSRequestDTO(),
            as: [LegacyMigrationActionDTO].self
        )
    }

    public func prepareProfilePublish(
        _ request: ProfilePublishPreparationDTO
    ) async throws -> HostBindingOperationDTO {
        try await gateway.request(
            .prepareProfilePublish,
            request,
            as: HostBindingOperationDTO.self
        )
    }

    public func commitProfilePublish(
        _ request: HostBindingCommitDTO
    ) async throws -> HostBindingCrossLinkDTO {
        try await gateway.request(
            .commitProfilePublish,
            request,
            as: HostBindingCrossLinkDTO.self
        )
    }

    public func complete(
        _ confirmation: HostBindingActivationConfirmationDTO
    ) async throws -> LegacyProfileMigrationRecordDTO {
        try await gateway.request(
            .completeLegacyProfileMigration,
            confirmation,
            as: LegacyProfileMigrationRecordDTO.self
        )
    }
}
