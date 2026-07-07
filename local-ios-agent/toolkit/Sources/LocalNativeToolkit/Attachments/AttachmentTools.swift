import Foundation
import LocalAgentBridge

public struct FilesDescribeAttachmentTool: NativeTool {
    public let schema: NativeToolSchema
    private let store: any NativeAttachmentByteStore

    public init(store: any NativeAttachmentByteStore) {
        self.store = store
        self.schema = Self.makeSchema()
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        guard let attachmentId = Self.decodeAttachmentId(argumentsJson) else {
            return Self.error(code: "invalid_arguments", displayText: "Expected attachment_id.")
        }
        do {
            let metadata = try await store.describe(attachmentId: attachmentId)
            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "Attachment: \(metadata.filename)",
                modelText: "Attachment metadata: \(metadata.filename), \(metadata.contentType), \(metadata.byteCount) bytes.",
                resultKind: "attachment_metadata",
                resultPayload: Self.metadataPayload(metadata),
                sourceKind: "attachment",
                sourceId: metadata.attachmentId,
                displayName: metadata.filename,
                attachmentIds: [metadata.attachmentId],
                trustLevel: .trustedToolResult,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "metadata_only",
                sourceLabel: "Attachment",
                auditSummary: "Described attachment \(metadata.attachmentId).",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch {
            return Self.error(code: "attachment_not_found", displayText: "Attachment was not found.")
        }
    }

    fileprivate static var manifest: NativeToolManifest {
        attachmentManifest(
            manifestId: "native.files.describe_attachment.v1",
            capabilityId: "files.describe_attachment",
            title: "Describe Attachment",
            description: "Read attachment metadata."
        )
    }

    fileprivate static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "files.describe_attachment",
            description: manifest.description,
            inputSchema: attachmentIdSchema(),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    fileprivate static func decodeAttachmentId(_ argumentsJson: String) -> String? {
        guard let data = argumentsJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["attachment_id"] as? String
    }

    fileprivate static func metadataPayload(_ metadata: NativeAttachmentStoredBytes) -> [String: JSONValue] {
        [
            "attachment_id": .string(metadata.attachmentId),
            "filename": .string(metadata.filename),
            "content_type": .string(metadata.contentType),
            "byte_count": .number(Double(metadata.byteCount)),
        ]
    }

    fileprivate static func error(code: String, displayText: String) -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: manifest.manifestId,
            toolName: "files.describe_attachment",
            toolCallId: "unknown",
            code: code,
            displayText: displayText,
            auditSummary: "Attachment metadata failed: \(code)",
            sensitivity: .private,
            retention: manifest.retention
        )
    }
}

public struct FilesReadAttachmentTool: NativeTool {
    public let schema: NativeToolSchema
    private let store: any NativeAttachmentByteStore
    private let maxBytes: Int

    public init(store: any NativeAttachmentByteStore, maxBytes: Int = 64_000) {
        self.store = store
        self.maxBytes = maxBytes
        self.schema = Self.makeSchema()
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        guard let attachmentId = FilesDescribeAttachmentTool.decodeAttachmentId(argumentsJson) else {
            return Self.error(code: "invalid_arguments", displayText: "Expected attachment_id.")
        }
        do {
            let metadata = try await store.describe(attachmentId: attachmentId)
            let data = try await store.read(attachmentId: attachmentId, maxBytes: maxBytes)
            let excerpt = String(decoding: data, as: UTF8.self)
            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "Read attachment: \(metadata.filename)",
                modelText: "External attachment content from \(metadata.filename):\n\(excerpt)",
                resultKind: "attachment_text",
                resultPayload: [
                    "attachment_id": .string(metadata.attachmentId),
                    "filename": .string(metadata.filename),
                    "content_type": .string(metadata.contentType),
                    "text_excerpt": .string(excerpt),
                    "truncated": .bool(metadata.byteCount > data.count),
                ],
                sourceKind: "attachment",
                sourceId: metadata.attachmentId,
                displayName: metadata.filename,
                attachmentIds: [metadata.attachmentId],
                trustLevel: .untrustedExternalContent,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "quote_or_summarize_only",
                sourceLabel: "Attachment",
                auditSummary: "Read attachment \(metadata.attachmentId).",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch {
            return Self.error(code: "attachment_not_found", displayText: "Attachment was not found.")
        }
    }

    fileprivate static var manifest: NativeToolManifest {
        attachmentManifest(
            manifestId: "native.files.read_attachment.v1",
            capabilityId: "files.read_attachment",
            title: "Read Attachment",
            description: "Read bounded text from an attachment.",
            trustLevel: .untrustedExternalContent,
            auditPolicy: .excerptOnly
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "files.read_attachment",
            description: manifest.description,
            inputSchema: attachmentIdSchema(),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    private static func error(code: String, displayText: String) -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: manifest.manifestId,
            toolName: "files.read_attachment",
            toolCallId: "unknown",
            code: code,
            displayText: displayText,
            auditSummary: "Attachment read failed: \(code)",
            sensitivity: .private,
            retention: manifest.retention
        )
    }
}

public struct PhotosDescribeAttachmentTool: NativeTool {
    public let schema: NativeToolSchema
    private let wrapped: FilesDescribeAttachmentTool

    public init(store: any NativeAttachmentByteStore) {
        self.wrapped = FilesDescribeAttachmentTool(store: store)
        self.schema = NativeToolSchema(
            name: "photos.describe_attachment",
            description: "Read selected photo attachment metadata.",
            inputSchema: attachmentIdSchema(),
            riskLevel: .readOnly,
            permissionScope: nil,
            availability: .available,
            manifest: attachmentManifest(
                manifestId: "native.photos.describe_attachment.v1",
                capabilityId: "photos.describe_attachment",
                title: "Describe Photo Attachment",
                description: "Read selected photo attachment metadata."
            )
        )
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        await wrapped.execute(argumentsJson: argumentsJson)
    }
}

private func attachmentIdSchema() -> JSONSchemaDTO {
    .object(properties: ["attachment_id": .string()], required: ["attachment_id"])
}

private func attachmentManifest(
    manifestId: String,
    capabilityId: String,
    title: String,
    description: String,
    trustLevel: NativeToolTrustLevel = .trustedToolResult,
    auditPolicy: NativeToolResultSummaryPolicy = .metadataOnly
) -> NativeToolManifest {
    NativeToolManifest(
        manifestId: manifestId,
        capabilityId: capabilityId,
        title: title,
        description: description,
        mode: .background,
        permissionScope: nil,
        requiredPrivacyKeys: [],
        requiresForegroundUI: false,
        minimumOS: "iOS 17.0",
        regionPolicy: "available_with_service_fallback",
        fallback: NativeToolFallback(kind: .none, message: ""),
        riskLevel: .readOnly,
        approvalPolicy: .never,
        trustLevel: trustLevel,
        retention: .runOnly,
        audit: NativeToolAudit(label: title, resultSummaryPolicy: auditPolicy)
    )
}
