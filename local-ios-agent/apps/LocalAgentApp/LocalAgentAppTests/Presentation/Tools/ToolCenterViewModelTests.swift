import Foundation
import LocalAgentBridge
import LocalNativeToolkit
import Testing
@testable import LocalAgentApp

@Suite("Tool Center view model")
@MainActor
struct ToolCenterViewModelTests {
    @Test("rows are sorted by title then name")
    func rowsAreSortedByTitleThenName() async {
        let viewModel = ToolCenterViewModel(
            client: StaticNativeToolkitClient(schemas: [
                schema(name: "zeta.tool", auditLabel: "Zeta Tool"),
                schema(name: "alpha.tool", auditLabel: "Alpha Tool"),
            ]),
            permissionGateway: StaticPermissionGateway()
        )

        await viewModel.reload()

        #expect(viewModel.rows.map(\.title) == ["Alpha Tool", "Zeta Tool"])
    }

    @Test("metadata comes from manifest schema json")
    func metadataComesFromManifestSchemaJSON() async {
        let viewModel = ToolCenterViewModel(
            client: StaticNativeToolkitClient(schemas: [
                schema(
                    name: "web.fetch_url_text",
                    auditLabel: "Fetch Web Page",
                    mode: .background,
                    riskLevel: .confirm,
                    permissionScope: "web.fetch.approved",
                    approvalPolicy: .perCall
                ),
            ]),
            permissionGateway: StaticPermissionGateway()
        )

        await viewModel.reload()

        #expect(viewModel.rows.first == ToolCenterRowState(
            id: "web.fetch_url_text",
            name: "web.fetch_url_text",
            title: "Fetch Web Page",
            mode: .background,
            riskLevel: .confirm,
            permissionScope: "web.fetch.approved",
            approvalPolicy: .perCall,
            readiness: .ready
        ))
    }

    @Test("missing manifest marks row unavailable")
    func missingManifestMarksRowUnavailable() async {
        let viewModel = ToolCenterViewModel(
            client: StaticNativeToolkitClient(schemas: [
                ToolSchemaDTO(
                    name: "legacy.tool",
                    description: "Legacy tool",
                    parametersJsonSchema: #"{"type":"object"}"#,
                    riskLevel: .readOnly,
                    metadataJson: nil
                ),
            ]),
            permissionGateway: StaticPermissionGateway()
        )

        await viewModel.reload()

        #expect(viewModel.rows.first?.name == "legacy.tool")
        #expect(viewModel.rows.first?.title == "legacy.tool")
        #expect(viewModel.rows.first?.readiness == .unavailable(
            scope: NativePermissionScope("legacy.tool"),
            reason: "missing_manifest_metadata"
        ))
    }

    @Test("denied permission shows repair state")
    func deniedPermissionShowsRepairState() async {
        let denied = NativePermissionReadiness.denied(
            scope: NativePermissionScope("calendar.events.read_full"),
            repair: NativePermissionRepair(
                title: "Calendar Access Denied",
                message: "Open Settings",
                action: .openSettings
            )
        )
        let viewModel = ToolCenterViewModel(
            client: StaticNativeToolkitClient(schemas: [
                schema(
                    name: "calendar.search_events",
                    auditLabel: "Search Calendar",
                    permissionScope: "calendar.events.read_full"
                ),
            ]),
            permissionGateway: StaticPermissionGateway(states: ["calendar.events.read_full": denied])
        )

        await viewModel.reload()

        #expect(viewModel.rows.first?.readiness == denied)
    }

    @Test("user mediated tools show picker required state")
    func userMediatedToolsShowPickerRequiredState() async {
        let viewModel = ToolCenterViewModel(
            client: StaticNativeToolkitClient(schemas: [
                schema(
                    name: "photos.pick_images",
                    auditLabel: "Pick Photos",
                    mode: .userMediated,
                    approvalPolicy: .perCall
                ),
            ]),
            permissionGateway: StaticPermissionGateway()
        )

        await viewModel.reload()

        #expect(viewModel.rows.first?.mode == .userMediated)
        #expect(viewModel.rows.first?.interactionLabel == "Picker required")
    }
}

private struct StaticNativeToolkitClient: NativeToolkitClientProtocol {
    var schemas: [ToolSchemaDTO]

    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot {
        NativeToolkitRegistrationSnapshot(
            schemas: schemas,
            toolNames: schemas.map(\.name)
        )
    }

    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: "native.test.v1",
            toolName: request.toolName,
            toolCallId: request.toolCallId,
            code: "not_used",
            displayText: "Not used",
            auditSummary: "Not used"
        )
    }
}

private struct StaticPermissionGateway: NativePermissionGateway {
    var states: [String: NativePermissionReadiness] = [:]

    func readiness(for scope: NativePermissionScope?) async -> NativePermissionReadiness {
        guard let scope else {
            return .ready
        }
        return states[scope.name] ?? .ready
    }

    func requestPermission(for scope: NativePermissionScope) async -> NativePermissionReadiness {
        states[scope.name] ?? .ready
    }
}

private func schema(
    name: String,
    auditLabel: String,
    mode: NativeToolMode = .background,
    riskLevel: RiskLevelDTO = .readOnly,
    permissionScope: String? = nil,
    approvalPolicy: NativeToolApprovalPolicy = .never
) -> ToolSchemaDTO {
    ToolSchemaDTO(
        name: name,
        description: auditLabel,
        parametersJsonSchema: #"{"type":"object"}"#,
        riskLevel: riskLevel,
        metadataJson: metadataJson(
            manifestId: "native.\(name).v1",
            capabilityId: name,
            auditLabel: auditLabel,
            mode: mode,
            riskLevel: riskLevel,
            permissionScope: permissionScope,
            approvalPolicy: approvalPolicy
        )
    )
}

private func metadataJson(
    manifestId: String,
    capabilityId: String,
    auditLabel: String,
    mode: NativeToolMode,
    riskLevel: RiskLevelDTO,
    permissionScope: String?,
    approvalPolicy: NativeToolApprovalPolicy
) -> String {
    let metadata = NativeToolSchemaMetadataV1(
        schemaVersion: 1,
        manifestId: manifestId,
        capabilityId: capabilityId,
        toolMode: mode,
        permissionScope: permissionScope,
        approvalPolicy: approvalPolicy,
        riskLevel: riskLevel,
        contextTrustLevel: .trustedToolResult,
        availability: NativeToolSchemaMetadataV1.Availability(
            state: "available",
            osMinimum: "iOS 17.0",
            regionPolicy: "available_with_service_fallback"
        ),
        fallback: NativeToolFallback(kind: .none, message: ""),
        audit: NativeToolAudit(label: auditLabel, resultSummaryPolicy: .metadataOnly)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(metadata)
    return String(decoding: data, as: UTF8.self)
}
