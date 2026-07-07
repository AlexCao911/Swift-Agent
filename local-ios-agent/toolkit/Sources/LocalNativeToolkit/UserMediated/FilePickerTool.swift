import Foundation
import LocalAgentBridge

public struct FilesPickDocumentTool: NativeTool {
    public let schema: NativeToolSchema

    public init() {
        let manifest = Self.manifest
        self.schema = NativeToolSchema(
            name: "files.pick_document",
            description: manifest.description,
            inputSchema: .object(),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        pendingInteractionResult(
            manifest: Self.manifest,
            toolName: schema.name,
            interactionKind: "file_picker",
            displayText: "Choose a document to continue."
        )
    }

    private static var manifest: NativeToolManifest {
        userMediatedManifest(
            manifestId: "native.files.pick_document.v1",
            capabilityId: "files.pick_document",
            title: "Pick Document",
            description: "Ask the user to choose a document."
        )
    }
}

func pendingInteractionResult(
    manifest: NativeToolManifest,
    toolName: String,
    interactionKind: String,
    displayText: String
) -> ToolResultDTO {
    NativeToolResultBuilder.success(
        manifestId: manifest.manifestId,
        toolName: toolName,
        toolCallId: "unknown",
        displayText: displayText,
        modelText: "\(toolName) requires user interaction: \(interactionKind).",
        resultKind: "pending_user_interaction",
        resultPayload: [
            "interaction_kind": .string(interactionKind),
            "status": .string("requested"),
        ],
        sourceKind: "app",
        sourceId: toolName,
        displayName: manifest.title,
        attachmentIds: [],
        trustLevel: .trustedAppPolicy,
        sensitivity: .public,
        retention: manifest.retention,
        modelTextPolicy: "status_only",
        sourceLabel: "App",
        auditSummary: "\(toolName) requested user interaction.",
        auditRedaction: manifest.audit.resultSummaryPolicy.rawValue
    )
}

func userMediatedManifest(
    manifestId: String,
    capabilityId: String,
    title: String,
    description: String
) -> NativeToolManifest {
    NativeToolManifest(
        manifestId: manifestId,
        capabilityId: capabilityId,
        title: title,
        description: description,
        mode: .userMediated,
        permissionScope: nil,
        requiredPrivacyKeys: [],
        requiresForegroundUI: true,
        minimumOS: "iOS 17.0",
        regionPolicy: "available_with_service_fallback",
        fallback: NativeToolFallback(kind: .userMediated, message: "User selection is required."),
        riskLevel: .confirm,
        approvalPolicy: .perCall,
        trustLevel: .trustedAppPolicy,
        retention: .runOnly,
        audit: NativeToolAudit(label: title, resultSummaryPolicy: .metadataOnly)
    )
}
