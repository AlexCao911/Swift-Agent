# Swift Agent Builder Native Toolkit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Agent Builder / Native Toolkit contract layer so Swift can publish immutable agent revisions, export native tool manifests to Rust, return trusted tool-result envelopes, and support safe first-stage native tools.

**Architecture:** Swift remains the product and toolkit owner. Rust remains the agent kernel and execution snapshot owner. This plan builds the contract foundation first: manifest metadata, tool-result envelopes, pending interaction records, web-fetch policy, and profile revision pinning. The visual Conversation Workspace runtime cards are covered by `2026-07-07-swift-conversation-workspace-design.md` and should be implemented after these contracts exist.

**Tech Stack:** Swift 6 package targets `LocalNativeToolkit` and `LocalAgentBridge`, Swift Testing, Rust `rust-core`, serde JSON FFI, existing C ABI bridge.

## Global Constraints

- Conversation domain prepares `conversation_run_frame_ref`; it must not consume `profile_revision_id`.
- Execution domain starts runs with `profile_revision_id + conversation_run_frame_ref`.
- `NativeToolManifest` is the single source for Builder cards, Rust schema export, runtime approval, permission readiness, and audit metadata.
- `ToolSchemaDTO.metadata_json` must use a stable schema, not ad hoc keys.
- `ToolResultDTO.structuredJson` must carry trust/provenance/context policy through `ToolResultEnvelopeV1`.
- External web/file/OCR/share/speech/vision content must be labelled `untrusted_external_content`.
- `web.fetch_url_text` must use `WebFetchPolicyV1`: no cookies/auth headers, no JS, no private network by default, bounded redirects, bounded MIME/size/time.
- `WebFetchPolicyV1` private-network blocking is host-string based in this plan. It blocks IPv4 private ranges and common IPv6 local ranges, but does not validate DNS-resolved IP addresses; DNS rebinding and split-horizon DNS remain known risks for a later network-layer hardening pass.
- User-mediated tools must persist a durable `pending_user_interaction` record before presenting system UI.
- Production run start must fail when no `profile_revision_id` is selected; only explicit seed/mock clients may use revision `1`.
- Avoid full visual node editor work in this plan.

---

## File Structure

Swift toolkit files:

- Create `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolManifest.swift`
  Defines manifest enums and `NativeToolSchemaMetadataV1`.
- Modify `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeTool.swift`
  Adds optional manifest to `NativeToolSchema`.
- Modify `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift`
  Exports stable metadata JSON from manifest.
- Create `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolResultEnvelope.swift`
  Defines `ToolResultEnvelopeV1`, provenance, context policy, and builders.
- Modify `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolExecutor.swift`
  Returns envelope-shaped error results.
- Create `local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebFetchPolicy.swift`
  Defines WebFetchPolicyV1 validator.
- Create `local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebTools.swift`
  Adds `web.fetch_url_text` using `WebFetchPolicyV1`, redirect-aware fetch reporting, and injectable fetcher.
- Create `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeAttachmentStore.swift`
  Adds attachment records and access states.
- Create `local-ios-agent/toolkit/Sources/LocalNativeToolkit/PendingUserInteraction.swift`
  Adds pending interaction record, durable store protocol, file-backed store, and test in-memory store.
- Modify `local-ios-agent/toolkit/Sources/LocalNativeToolkit/CalendarTools.swift`
- Modify `local-ios-agent/toolkit/Sources/LocalNativeToolkit/ReminderTools.swift`
- Modify `local-ios-agent/toolkit/Sources/LocalNativeToolkit/MetaTools.swift`
  Attach manifests and return envelope-shaped results.

Swift bridge/app files:

- Modify `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
  Adds `profileRevisionId` to published profile and start-run DTOs.
- Modify `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentBuilderClient.swift`
  Makes mock publish return revision ids.
- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ChatInteractionCoordinator.swift`
  Starts execution with profile revision id.
- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
  Stores selected profile revision id and passes it to coordinator path.
- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderViewModel.swift`
  Adds minimal draft lifecycle and publish result state.

Rust files:

- Modify `local-ios-agent/rust-core/src/run_snapshot/snapshot.rs`
  Adds profile revision field to `StartRunRequest`.
- Modify `local-ios-agent/rust-core/src/run_snapshot/resolver.rs`
  Resolves exact profile revision instead of latest for run start.
- Modify `local-ios-agent/rust-core/src/execution/execution_service.rs`
  Passes revision-pinned request to snapshot resolver.
- Modify `local-ios-agent/rust-core/src/ffi_bridge.rs`
  Adds `profile_revision_id` to start-run JSON.

Tests:

- Modify `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeToolSchemaExportTests.swift`
- Create `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeToolResultEnvelopeTests.swift`
- Create `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/WebFetchPolicyTests.swift`
- Create `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeAttachmentStoreTests.swift`
- Create `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentProfileRevisionDTOTests.swift`
- Modify `local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`.
- Modify `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`.

---

### Task 1: NativeToolManifest And Schema Metadata

**Files:**
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolManifest.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeTool.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeToolSchemaExportTests.swift`

**Interfaces:**
- Produces: `NativeToolManifest`, `NativeToolMode`, `NativeToolApprovalPolicy`, `NativeToolTrustLevel`, `NativeToolSchemaMetadataV1`.
- Consumes: existing `NativeToolSchema`, `NativePermissionScope`, `NativeToolAvailability`, `ToolSchemaDTO`.

- [ ] **Step 1: Write failing metadata export test**

Add this test to `NativeToolSchemaExportTests.swift`:

```swift
@Test
func exportsManifestMetadataV1() throws {
    let manifest = NativeToolManifest(
        manifestId: "native.calendar.search_events.v1",
        capabilityId: "calendar.events.search",
        title: "Search Calendar",
        description: "Search calendar events",
        mode: .background,
        permissionScope: NativePermissionScope("calendar.events.read_full"),
        requiredPrivacyKeys: ["NSCalendarsFullAccessUsageDescription"],
        requiresForegroundUI: false,
        minimumOS: "iOS 17.0",
        regionPolicy: "available_with_service_fallback",
        fallback: NativeToolFallback(kind: .openSettings, message: "Calendar access is required."),
        riskLevel: .readOnly,
        approvalPolicy: .perCall,
        trustLevel: .trustedToolResult,
        retention: .runOnly,
        audit: NativeToolAudit(label: "Calendar Search", resultSummaryPolicy: .metadataOnly)
    )
    let catalog = try NativeToolCatalog(tools: [
        ExportStubTool(
            schema: NativeToolSchema(
                name: "calendar.search_events",
                description: "Search calendar events",
                inputSchema: .object(properties: ["query": .string()], required: ["query"]),
                riskLevel: .readOnly,
                permissionScope: NativePermissionScope("calendar.events.read_full"),
                availability: .available,
                manifest: manifest
            )
        ),
    ])

    let exported = NativeToolSchemaExport.exportSchemas(from: catalog)
    #expect(exported.count == 1)
    let metadata = try #require(exported[0].metadataJson)
    let data = try #require(metadata.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["schema_version"] as? Int == 1)
    #expect(object["manifest_id"] as? String == "native.calendar.search_events.v1")
    #expect(object["capability_id"] as? String == "calendar.events.search")
    #expect(object["tool_mode"] as? String == "background")
    #expect(object["permission_scope"] as? String == "calendar.events.read_full")
    #expect(object["approval_policy"] as? String == "per_call")
    #expect(object["context_trust_level"] as? String == "trusted_tool_result")

    let availability = try #require(object["availability"] as? [String: Any])
    let audit = try #require(object["audit"] as? [String: Any])
    #expect(availability["os_minimum"] as? String == "iOS 17.0")
    #expect(availability["region_policy"] as? String == "available_with_service_fallback")
    #expect(audit["result_summary_policy"] as? String == "metadata_only")
    #expect(audit["resultSummaryPolicy"] == nil)
}
```

- [ ] **Step 2: Write missing-manifest and risk-conflict tests**

Add these tests to `NativeToolSchemaExportTests.swift`:

```swift
@Test
func missingManifestDoesNotSynthesizeProductMetadata() throws {
    let catalog = try NativeToolCatalog(tools: [
        ExportStubTool(
            schema: NativeToolSchema(
                name: "legacy.tool",
                description: "Legacy tool",
                inputSchema: .object(properties: [:], required: []),
                riskLevel: .readOnly,
                permissionScope: nil,
                availability: .available
            )
        ),
    ])

    let exported = NativeToolSchemaExport.exportSchemas(from: catalog)

    #expect(exported.count == 1)
    #expect(exported[0].metadataJson == nil)
}

@Test
func riskMismatchExportsMoreRestrictiveRisk() throws {
    let manifest = NativeToolManifest(
        manifestId: "native.reminders.create.v1",
        capabilityId: "reminders.create",
        title: "Create Reminder",
        description: "Create reminders",
        mode: .background,
        permissionScope: NativePermissionScope("reminders.full"),
        requiredPrivacyKeys: ["NSRemindersUsageDescription"],
        requiresForegroundUI: false,
        minimumOS: "iOS 17.0",
        regionPolicy: "available_with_service_fallback",
        fallback: NativeToolFallback(kind: .openSettings, message: "Reminders access is required."),
        riskLevel: .confirm,
        approvalPolicy: .perCall,
        trustLevel: .trustedToolResult,
        retention: .runOnly,
        audit: NativeToolAudit(label: "Create Reminder", resultSummaryPolicy: .metadataOnly)
    )
    let catalog = try NativeToolCatalog(tools: [
        ExportStubTool(
            schema: NativeToolSchema(
                name: "reminders.create",
                description: "Create reminders",
                inputSchema: .object(properties: ["title": .string()], required: ["title"]),
                riskLevel: .readOnly,
                permissionScope: NativePermissionScope("reminders.full"),
                availability: .available,
                manifest: manifest
            )
        ),
    ])

    let exported = NativeToolSchemaExport.exportSchemas(from: catalog)
    let metadata = try #require(exported[0].metadataJson)
    let metadataData = try #require(metadata.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])

    #expect(exported[0].riskLevel == .confirm)
    #expect(object["risk_level"] as? String == "confirm")
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter NativeToolSchemaExportTests/exportsManifestMetadataV1
```

Expected: FAIL because `NativeToolManifest` and the new `NativeToolSchema` initializer argument do not exist.

- [ ] **Step 4: Add manifest model**

Create `NativeToolManifest.swift`:

```swift
import Foundation
import LocalAgentBridge

public enum NativeToolMode: String, Codable, Sendable, Equatable {
    case background
    case userMediated = "user_mediated"
    case systemActionAdapter = "system_action_adapter"
}

public enum NativeToolApprovalPolicy: String, Codable, Sendable, Equatable {
    case never
    case perCall = "per_call"
    case perSession = "per_session"
    case alwaysDenyUntilConfigured = "always_deny_until_configured"
}

public enum NativeToolTrustLevel: String, Codable, Sendable, Equatable {
    case trustedAppPolicy = "trusted_app_policy"
    case userInstruction = "user_instruction"
    case trustedToolResult = "trusted_tool_result"
    case untrustedExternalContent = "untrusted_external_content"
}

public enum NativeToolFallbackKind: String, Codable, Sendable, Equatable {
    case none
    case openSettings = "open_settings"
    case userMediated = "user_mediated"
    case unavailable
}

public enum NativeToolResultSummaryPolicy: String, Codable, Sendable, Equatable {
    case metadataOnly = "metadata_only"
    case excerptOnly = "excerpt_only"
    case fullText = "full_text"
}

public struct NativeToolFallback: Codable, Sendable, Equatable {
    public var kind: NativeToolFallbackKind
    public var message: String

    public init(kind: NativeToolFallbackKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct NativeToolAudit: Codable, Sendable, Equatable {
    public var label: String
    public var resultSummaryPolicy: NativeToolResultSummaryPolicy

    public init(label: String, resultSummaryPolicy: NativeToolResultSummaryPolicy) {
        self.label = label
        self.resultSummaryPolicy = resultSummaryPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case resultSummaryPolicy = "result_summary_policy"
    }
}

public struct NativeToolManifest: Sendable, Equatable {
    public var manifestId: String
    public var capabilityId: String
    public var title: String
    public var description: String
    public var mode: NativeToolMode
    public var permissionScope: NativePermissionScope?
    public var requiredPrivacyKeys: [String]
    public var requiresForegroundUI: Bool
    public var minimumOS: String
    public var regionPolicy: String
    public var fallback: NativeToolFallback
    public var riskLevel: NativeToolRiskLevel
    public var approvalPolicy: NativeToolApprovalPolicy
    public var trustLevel: NativeToolTrustLevel
    public var retention: RetentionPolicyDTO
    public var audit: NativeToolAudit

    public init(
        manifestId: String,
        capabilityId: String,
        title: String,
        description: String,
        mode: NativeToolMode,
        permissionScope: NativePermissionScope?,
        requiredPrivacyKeys: [String],
        requiresForegroundUI: Bool,
        minimumOS: String,
        regionPolicy: String,
        fallback: NativeToolFallback,
        riskLevel: NativeToolRiskLevel,
        approvalPolicy: NativeToolApprovalPolicy,
        trustLevel: NativeToolTrustLevel,
        retention: RetentionPolicyDTO,
        audit: NativeToolAudit
    ) {
        self.manifestId = manifestId
        self.capabilityId = capabilityId
        self.title = title
        self.description = description
        self.mode = mode
        self.permissionScope = permissionScope
        self.requiredPrivacyKeys = requiredPrivacyKeys
        self.requiresForegroundUI = requiresForegroundUI
        self.minimumOS = minimumOS
        self.regionPolicy = regionPolicy
        self.fallback = fallback
        self.riskLevel = riskLevel
        self.approvalPolicy = approvalPolicy
        self.trustLevel = trustLevel
        self.retention = retention
        self.audit = audit
    }
}

public struct NativeToolSchemaMetadataV1: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var manifestId: String
    public var capabilityId: String
    public var toolMode: NativeToolMode
    public var permissionScope: String?
    public var approvalPolicy: NativeToolApprovalPolicy
    public var riskLevel: RiskLevelDTO
    public var contextTrustLevel: NativeToolTrustLevel
    public var availability: Availability
    public var fallback: NativeToolFallback
    public var audit: NativeToolAudit

    public struct Availability: Codable, Sendable, Equatable {
        public var state: String
        public var osMinimum: String
        public var regionPolicy: String

        private enum CodingKeys: String, CodingKey {
            case state
            case osMinimum = "os_minimum"
            case regionPolicy = "region_policy"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manifestId = "manifest_id"
        case capabilityId = "capability_id"
        case toolMode = "tool_mode"
        case permissionScope = "permission_scope"
        case approvalPolicy = "approval_policy"
        case riskLevel = "risk_level"
        case contextTrustLevel = "context_trust_level"
        case availability
        case fallback
        case audit
    }
}
```

- [ ] **Step 5: Extend NativeToolSchema**

Modify `NativeTool.swift`:

```swift
public struct NativeToolSchema: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONSchemaDTO
    public var riskLevel: NativeToolRiskLevel
    public var permissionScope: NativePermissionScope?
    public var availability: NativeToolAvailability
    public var manifest: NativeToolManifest?

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchemaDTO,
        riskLevel: NativeToolRiskLevel,
        permissionScope: NativePermissionScope?,
        availability: NativeToolAvailability,
        manifest: NativeToolManifest? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.riskLevel = riskLevel
        self.permissionScope = permissionScope
        self.availability = availability
        self.manifest = manifest
    }
}
```

- [ ] **Step 6: Export metadata from manifest**

Replace `metadataJSON(for:)` in `NativeToolSchemaExport.swift` with:

```swift
private static func metadataJSON(for schema: NativeToolSchema) -> String? {
    guard let manifest = schema.manifest else {
        return nil
    }
    let riskLevel = effectiveRiskLevel(schema.riskLevel, manifest.riskLevel)
    let metadata = NativeToolSchemaMetadataV1(
        schemaVersion: 1,
        manifestId: manifest.manifestId,
        capabilityId: manifest.capabilityId,
        toolMode: manifest.mode,
        permissionScope: manifest.permissionScope?.name,
        approvalPolicy: manifest.approvalPolicy,
        riskLevel: bridgeRiskLevel(for: riskLevel),
        contextTrustLevel: manifest.trustLevel,
        availability: NativeToolSchemaMetadataV1.Availability(
            state: availabilityState(schema.availability),
            osMinimum: manifest.minimumOS,
            regionPolicy: manifest.regionPolicy
        ),
        fallback: manifest.fallback,
        audit: manifest.audit
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(metadata) else {
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}

private static func effectiveRiskLevel(
    _ schemaRisk: NativeToolRiskLevel,
    _ manifestRisk: NativeToolRiskLevel
) -> NativeToolRiskLevel {
    rank(manifestRisk) >= rank(schemaRisk) ? manifestRisk : schemaRisk
}

private static func rank(_ risk: NativeToolRiskLevel) -> Int {
    switch risk {
    case .readOnly:
        0
    case .confirm:
        1
    case .destructive:
        2
    }
}

private static func availabilityState(_ availability: NativeToolAvailability) -> String {
    switch availability {
    case .available:
        "available"
    case .unavailable:
        "unavailable"
    }
}
```

Update the DTO construction call inside `exportSchemas(from:)`:

```swift
public static func exportSchemas(from catalog: NativeToolCatalog) -> [ToolSchemaDTO] {
    catalog.schemas.compactMap { schema in
        guard schema.availability == .available else {
            return nil
        }
        let effectiveRisk = schema.manifest.map {
            effectiveRiskLevel(schema.riskLevel, $0.riskLevel)
        } ?? schema.riskLevel

        return ToolSchemaDTO(
            name: schema.name,
            description: schema.description,
            parametersJsonSchema: schema.inputSchema.jsonString,
            riskLevel: bridgeRiskLevel(for: effectiveRisk),
            metadataJson: metadataJSON(for: schema)
        )
    }
}
```

- [ ] **Step 7: Run focused tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter NativeToolSchemaExportTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolManifest.swift \
  local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeTool.swift \
  local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift \
  local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeToolSchemaExportTests.swift
git commit -m "feat: add native tool manifest metadata"
```

---

### Task 2: ToolResultEnvelopeV1

**Files:**
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolResultEnvelope.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolExecutor.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeToolResultEnvelopeTests.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeToolExecutorTests.swift`

**Interfaces:**
- Consumes: `ToolResultDTO`, `NativeToolTrustLevel`, `SensitivityDTO`, `RetentionPolicyDTO`.
- Produces: `ToolResultEnvelopeV1`, recursive `JSONValue`, `NativeToolResultBuilder.success(...)`, `NativeToolResultBuilder.error(...)`, `NativeToolResultEnvelopeValidator.validate(...)`.

- [ ] **Step 1: Write failing envelope tests**

Create `NativeToolResultEnvelopeTests.swift`:

```swift
import Foundation
import Testing
import LocalAgentBridge
@testable import LocalNativeToolkit

@Suite("Native tool result envelope")
struct NativeToolResultEnvelopeTests {
    @Test
    func successEnvelopeCarriesTrustAndProvenance() throws {
        let result = NativeToolResultBuilder.success(
            manifestId: "native.web.fetch_url_text.v1",
            toolName: "web.fetch_url_text",
            toolCallId: "call_1",
            displayText: "Fetched example.com",
            modelText: "External content from example.com:\nhello",
            resultKind: "web_text",
            resultPayload: ["text_excerpt": .string("hello")],
            sourceKind: "web",
            sourceId: "https://example.com",
            displayName: "example.com",
            attachmentIds: [],
            trustLevel: .untrustedExternalContent,
            sensitivity: .public,
            retention: .runOnly,
            modelTextPolicy: "summarize_or_quote_only",
            sourceLabel: "Web",
            auditSummary: "Fetched text from example.com",
            auditRedaction: "excerpt_only"
        )

        let data = try #require(result.structuredJson.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provenance = try #require(object["provenance"] as? [String: Any])
        let contextPolicy = try #require(object["context_policy"] as? [String: Any])

        #expect(object["schema_version"] as? Int == 1)
        #expect(object["manifest_id"] as? String == "native.web.fetch_url_text.v1")
        #expect(provenance["trust_level"] as? String == "untrusted_external_content")
        #expect(provenance["retention"] as? String == "run_only")
        #expect(contextPolicy["model_text_policy"] as? String == "summarize_or_quote_only")
        #expect(result.sensitivity == .public)
        #expect(result.retention == .runOnly)
        #expect(result.isError == false)
    }

    @Test
    func envelopeSupportsNestedArraysAndObjects() throws {
        let result = NativeToolResultBuilder.success(
            manifestId: "native.native.list_tools.v1",
            toolName: "native.list_tools",
            toolCallId: "call_1",
            displayText: "2 tools available",
            modelText: "Available tools: calendar.search_events, reminders.create",
            resultKind: "native_tool_status",
            resultPayload: [
                "tools": .array([
                    .object(["name": .string("calendar.search_events")]),
                    .object(["name": .string("reminders.create")]),
                ]),
                "permissions": .array([
                    .object(["scope": .string("calendar.events.read_full")]),
                ]),
            ],
            sourceKind: "tool",
            sourceId: "native.list_tools",
            displayName: "List Tools",
            attachmentIds: [],
            trustLevel: .trustedToolResult,
            sensitivity: .public,
            retention: .runOnly,
            modelTextPolicy: "tool_status",
            sourceLabel: "Tool",
            auditSummary: "Listed tools",
            auditRedaction: "metadata_only"
        )

        let data = try #require(result.structuredJson.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["result"] as? [String: Any])
        let tools = try #require(payload["tools"] as? [[String: Any]])

        #expect(tools.map { $0["name"] as? String } == [
            "calendar.search_events",
            "reminders.create",
        ])
    }

    @Test
    func errorEnvelopeUsesSafePolicyFields() throws {
        let result = NativeToolResultBuilder.error(
            manifestId: "native.executor.v1",
            toolName: "missing.tool",
            toolCallId: "unknown",
            code: "unknown_tool",
            displayText: "Unknown native tool",
            auditSummary: "Unknown native tool: missing.tool"
        )

        let data = try #require(result.structuredJson.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])

        #expect(resultObject["code"] as? String == "unknown_tool")
        #expect(result.isError == true)
        #expect(result.sensitivity == .public)
        #expect(result.retention == .runOnly)
    }

    @Test
    func validatorRejectsErrorFlagMismatch() throws {
        let result = NativeToolResultBuilder.error(
            manifestId: "native.executor.v1",
            toolName: "native.executor",
            toolCallId: "call_1",
            code: "tool_executor_error",
            displayText: "Tool failed",
            auditSummary: "Tool failed"
        )
        let mismatched = ToolResultDTO(
            displayText: result.displayText,
            modelText: result.modelText,
            structuredJson: result.structuredJson,
            auditText: result.auditText,
            sensitivity: result.sensitivity,
            retention: result.retention,
            isError: false
        )

        #expect(throws: NativeToolResultEnvelopeValidationError.self) {
            try NativeToolResultEnvelopeValidator.validate(mismatched)
        }
    }

    @Test
    func validatorKeepsConservativeSensitivity() throws {
        let result = NativeToolResultBuilder.success(
            manifestId: "native.files.read_attachment.v1",
            toolName: "files.read_attachment",
            toolCallId: "call_1",
            displayText: "Read file",
            modelText: "File text",
            resultKind: "attachment_text",
            resultPayload: ["attachment_id": .string("att_1")],
            sourceKind: "attachment",
            sourceId: "att_1",
            displayName: "notes.txt",
            attachmentIds: ["att_1"],
            trustLevel: .untrustedExternalContent,
            sensitivity: .private,
            retention: .runOnly,
            modelTextPolicy: "summarize_or_quote_only",
            sourceLabel: "File",
            auditSummary: "Read attachment",
            auditRedaction: "metadata_only"
        )
        let weakened = ToolResultDTO(
            displayText: result.displayText,
            modelText: result.modelText,
            structuredJson: result.structuredJson,
            auditText: result.auditText,
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )

        let validated = try NativeToolResultEnvelopeValidator.validate(weakened)

        #expect(validated.sensitivity == .private)
        #expect(validated.retention == .runOnly)
    }

    @Test
    func validatorRejectsRetentionMismatch() throws {
        let result = NativeToolResultBuilder.success(
            manifestId: "native.files.read_attachment.v1",
            toolName: "files.read_attachment",
            toolCallId: "call_1",
            displayText: "Read file",
            modelText: "File text",
            resultKind: "attachment_text",
            resultPayload: ["attachment_id": .string("att_1")],
            sourceKind: "attachment",
            sourceId: "att_1",
            displayName: "notes.txt",
            attachmentIds: ["att_1"],
            trustLevel: .untrustedExternalContent,
            sensitivity: .private,
            retention: .runOnly,
            modelTextPolicy: "summarize_or_quote_only",
            sourceLabel: "File",
            auditSummary: "Read attachment",
            auditRedaction: "metadata_only"
        )
        let mismatched = ToolResultDTO(
            displayText: result.displayText,
            modelText: result.modelText,
            structuredJson: result.structuredJson,
            auditText: result.auditText,
            sensitivity: result.sensitivity,
            retention: .session,
            isError: false
        )

        #expect(throws: NativeToolResultEnvelopeValidationError.self) {
            try NativeToolResultEnvelopeValidator.validate(mismatched)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter NativeToolResultEnvelopeTests
```

Expected: FAIL because `NativeToolResultBuilder` does not exist.

- [ ] **Step 3: Add envelope types and builder**

Create `NativeToolResultEnvelope.swift`:

```swift
import Foundation
import LocalAgentBridge

public struct ToolResultEnvelopeV1: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var manifestId: String
    public var toolName: String
    public var toolCallId: String
    public var result: [String: JSONValue]
    public var provenance: Provenance
    public var contextPolicy: ContextPolicy
    public var audit: Audit

    public struct Provenance: Codable, Sendable, Equatable {
        public var sourceKind: String
        public var sourceId: String
        public var displayName: String
        public var attachmentIds: [String]
        public var trustLevel: NativeToolTrustLevel
        public var sensitivity: SensitivityDTO
        public var retention: RetentionPolicyDTO

        private enum CodingKeys: String, CodingKey {
            case sourceKind = "source_kind"
            case sourceId = "source_id"
            case displayName = "display_name"
            case attachmentIds = "attachment_ids"
            case trustLevel = "trust_level"
            case sensitivity
            case retention
        }
    }

    public struct ContextPolicy: Codable, Sendable, Equatable {
        public var modelTextPolicy: String
        public var trustLevel: NativeToolTrustLevel
        public var sourceLabel: String

        private enum CodingKeys: String, CodingKey {
            case modelTextPolicy = "model_text_policy"
            case trustLevel = "trust_level"
            case sourceLabel = "source_label"
        }
    }

    public struct Audit: Codable, Sendable, Equatable {
        public var summary: String
        public var redaction: String
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manifestId = "manifest_id"
        case toolName = "tool_name"
        case toolCallId = "tool_call_id"
        case result
        case provenance
        case contextPolicy = "context_policy"
        case audit
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public enum NativeToolResultBuilder {
    public static func success(
        manifestId: String,
        toolName: String,
        toolCallId: String,
        displayText: String,
        modelText: String,
        resultKind: String,
        resultPayload: [String: JSONValue],
        sourceKind: String,
        sourceId: String,
        displayName: String,
        attachmentIds: [String],
        trustLevel: NativeToolTrustLevel,
        sensitivity: SensitivityDTO,
        retention: RetentionPolicyDTO,
        modelTextPolicy: String,
        sourceLabel: String,
        auditSummary: String,
        auditRedaction: String
    ) -> ToolResultDTO {
        var result = resultPayload
        result["kind"] = .string(resultKind)
        let envelope = ToolResultEnvelopeV1(
            schemaVersion: 1,
            manifestId: manifestId,
            toolName: toolName,
            toolCallId: toolCallId,
            result: result,
            provenance: ToolResultEnvelopeV1.Provenance(
                sourceKind: sourceKind,
                sourceId: sourceId,
                displayName: displayName,
                attachmentIds: attachmentIds,
                trustLevel: trustLevel,
                sensitivity: sensitivity,
                retention: retention
            ),
            contextPolicy: ToolResultEnvelopeV1.ContextPolicy(
                modelTextPolicy: modelTextPolicy,
                trustLevel: trustLevel,
                sourceLabel: sourceLabel
            ),
            audit: ToolResultEnvelopeV1.Audit(summary: auditSummary, redaction: auditRedaction)
        )
        return ToolResultDTO(
            displayText: displayText,
            modelText: modelText,
            structuredJson: encode(envelope),
            auditText: auditSummary,
            sensitivity: sensitivity,
            retention: retention,
            isError: false
        )
    }

    public static func error(
        manifestId: String,
        toolName: String,
        toolCallId: String,
        code: String,
        displayText: String,
        auditSummary: String
    ) -> ToolResultDTO {
        success(
            manifestId: manifestId,
            toolName: toolName,
            toolCallId: toolCallId,
            displayText: displayText,
            modelText: "Tool error `\(code)`: \(displayText)",
            resultKind: "error",
            resultPayload: ["code": .string(code)],
            sourceKind: "tool",
            sourceId: toolName,
            displayName: toolName,
            attachmentIds: [],
            trustLevel: .trustedToolResult,
            sensitivity: .public,
            retention: .runOnly,
            modelTextPolicy: "error_summary_only",
            sourceLabel: "Tool",
            auditSummary: auditSummary,
            auditRedaction: "metadata_only"
        ).withErrorFlag()
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return #"{"schema_version":1,"result":{"kind":"encoding_failed"}}"#
        }
    }
}

private extension ToolResultDTO {
    func withErrorFlag() -> ToolResultDTO {
        ToolResultDTO(
            displayText: displayText,
            modelText: modelText,
            structuredJson: structuredJson,
            auditText: auditText,
            sensitivity: sensitivity,
            retention: retention,
            isError: true
        )
    }
}

public enum NativeToolResultEnvelopeValidationError: Error, Equatable {
    case invalidStructuredJson
    case isErrorMismatch
    case retentionMismatch
}

public enum NativeToolResultEnvelopeValidator {
    public static func validate(_ result: ToolResultDTO) throws -> ToolResultDTO {
        guard let data = result.structuredJson.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ToolResultEnvelopeV1.self, from: data)
        else {
            throw NativeToolResultEnvelopeValidationError.invalidStructuredJson
        }
        let envelopeIsError = envelope.result["kind"] == .string("error")
        guard envelopeIsError == result.isError else {
            throw NativeToolResultEnvelopeValidationError.isErrorMismatch
        }
        guard envelope.provenance.retention == result.retention else {
            throw NativeToolResultEnvelopeValidationError.retentionMismatch
        }
        return ToolResultDTO(
            displayText: result.displayText,
            modelText: result.modelText,
            structuredJson: result.structuredJson,
            auditText: result.auditText,
            sensitivity: moreSensitive(result.sensitivity, envelope.provenance.sensitivity),
            retention: result.retention,
            isError: result.isError
        )
    }

    private static func moreSensitive(_ lhs: SensitivityDTO, _ rhs: SensitivityDTO) -> SensitivityDTO {
        sensitivityRank(rhs) >= sensitivityRank(lhs) ? rhs : lhs
    }

    private static func sensitivityRank(_ value: SensitivityDTO) -> Int {
        if value == .public {
            0
        } else if value == .private {
            1
        } else if value == .secret {
            2
        } else {
            2
        }
    }
}
```

- [ ] **Step 4: Update executor error results**

In `NativeToolExecutor.swift`, replace `errorResult(...)` with:

```swift
private static func errorResult(
    displayText: String,
    modelText: String,
    structuredJson: String,
    auditText: String
) -> ToolResultDTO {
    NativeToolResultBuilder.error(
        manifestId: "native.executor.v1",
        toolName: "native.executor",
        toolCallId: "unknown",
        code: "tool_executor_error",
        displayText: displayText,
        auditSummary: auditText
    )
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter NativeToolResultEnvelopeTests
swift test --filter NativeToolExecutorTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolResultEnvelope.swift \
  local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolExecutor.swift \
  local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeToolResultEnvelopeTests.swift \
  local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeToolExecutorTests.swift
git commit -m "feat: add native tool result envelope"
```

---

### Task 3: WebFetchPolicyV1 And Web Fetch Tool

**Files:**
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebFetchPolicy.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebTools.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/WebFetchPolicyTests.swift`

**Interfaces:**
- Consumes: `NativeToolManifest`, `NativeToolResultBuilder`.
- Produces: `WebFetchPolicyV1`, `WebFetchURLTextTool`, `WebFetchResponse`, redirect-aware `WebFetching`.

- [ ] **Step 1: Write failing policy tests**

Create `WebFetchPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import LocalNativeToolkit

@Suite("Web fetch policy")
struct WebFetchPolicyTests {
    @Test
    func allowsHttpsTextRequestWithoutCredentials() throws {
        var request = URLRequest(url: try #require(URL(string: "https://example.com/article")))
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let decision = WebFetchPolicyV1.default.validate(request)

        #expect(decision == .allowed)
    }

    @Test
    func rejectsUnsafeSchemesAndCredentials() throws {
        let fileDecision = WebFetchPolicyV1.default.validate(URLRequest(url: URL(fileURLWithPath: "/etc/passwd")))
        #expect(fileDecision == .denied(code: "web_fetch.scheme_denied"))

        var request = URLRequest(url: try #require(URL(string: "https://example.com/private")))
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        #expect(WebFetchPolicyV1.default.validate(request) == .denied(code: "web_fetch.credentials_denied"))
    }

    @Test
    func rejectsLocalAndPrivateHosts() throws {
        let localhost = URLRequest(url: try #require(URL(string: "https://localhost:8080")))
        let privateLan = URLRequest(url: try #require(URL(string: "https://192.168.1.10/status")))

        #expect(WebFetchPolicyV1.default.validate(localhost) == .denied(code: "web_fetch.private_network_denied"))
        #expect(WebFetchPolicyV1.default.validate(privateLan) == .denied(code: "web_fetch.private_network_denied"))
    }

    @Test
    func rejectsIPv6LocalHosts() throws {
        let loopback = URLRequest(url: try #require(URL(string: "https://[::1]/admin")))
        let uniqueLocal = URLRequest(url: try #require(URL(string: "https://[fd00::1]/status")))
        let linkLocal = URLRequest(url: try #require(URL(string: "https://[fe80::1]/status")))

        #expect(WebFetchPolicyV1.default.validate(loopback) == .denied(code: "web_fetch.private_network_denied"))
        #expect(WebFetchPolicyV1.default.validate(uniqueLocal) == .denied(code: "web_fetch.private_network_denied"))
        #expect(WebFetchPolicyV1.default.validate(linkLocal) == .denied(code: "web_fetch.private_network_denied"))
    }

    @Test
    func rejectsRedirectToPrivateNetworkBeforeFollow() throws {
        let source = URLRequest(url: try #require(URL(string: "https://example.com/article")))
        let redirected = URLRequest(url: try #require(URL(string: "https://localhost:8080/private")))

        let decision = WebFetchPolicyV1.default.validateRedirect(
            from: source,
            to: redirected,
            redirectCount: 1
        )

        #expect(decision == .denied(code: "web_fetch.private_network_denied"))
    }

    @Test
    func rejectsRedirectCountOverLimit() throws {
        let source = URLRequest(url: try #require(URL(string: "https://example.com/article")))
        let redirected = URLRequest(url: try #require(URL(string: "https://example.org/next")))
        let policy = WebFetchPolicyV1(
            maxResponseBytes: 512_000,
            maxExtractedTextCharacters: 100_000,
            timeoutSeconds: 20,
            maxRedirects: 1
        )

        let decision = policy.validateRedirect(
            from: source,
            to: redirected,
            redirectCount: 2
        )

        #expect(decision == .denied(code: "web_fetch.redirect_limit_exceeded"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter WebFetchPolicyTests
```

Expected: FAIL because `WebFetchPolicyV1` does not exist.

- [ ] **Step 3: Add WebFetchPolicyV1**

Create `WebFetchPolicy.swift`:

```swift
import Foundation

public enum WebFetchPolicyDecision: Sendable, Equatable {
    case allowed
    case denied(code: String)
}

public struct WebFetchPolicyV1: Sendable, Equatable {
    public var maxResponseBytes: Int
    public var maxExtractedTextCharacters: Int
    public var timeoutSeconds: TimeInterval
    public var maxRedirects: Int

    public static let `default` = WebFetchPolicyV1(
        maxResponseBytes: 512_000,
        maxExtractedTextCharacters: 100_000,
        timeoutSeconds: 20,
        maxRedirects: 5
    )

    public func validate(_ request: URLRequest) -> WebFetchPolicyDecision {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased()
        else {
            return .denied(code: "web_fetch.invalid_url")
        }
        guard scheme == "https" else {
            return .denied(code: "web_fetch.scheme_denied")
        }
        guard request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil
        else {
            return .denied(code: "web_fetch.credentials_denied")
        }
        guard !isPrivateHost(url.host(percentEncoded: false) ?? "") else {
            return .denied(code: "web_fetch.private_network_denied")
        }
        return .allowed
    }

    public func validateRedirect(
        from: URLRequest,
        to redirectedRequest: URLRequest,
        redirectCount: Int
    ) -> WebFetchPolicyDecision {
        guard redirectCount <= maxRedirects else {
            return .denied(code: "web_fetch.redirect_limit_exceeded")
        }
        return validate(redirectedRequest)
    }

    public func allowsMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else {
            return false
        }
        return mimeType.hasPrefix("text/")
            || mimeType == "application/json"
            || mimeType == "application/ld+json"
    }

    private func isPrivateHost(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lower == "localhost" || lower.hasSuffix(".local") {
            return true
        }
        if lower == "::1" || lower == "0:0:0:0:0:0:0:1" {
            return true
        }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            return true
        }
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") {
            return true
        }
        if lower.hasPrefix("::ffff:") {
            return isPrivateHost(String(lower.dropFirst("::ffff:".count)))
        }
        if lower.hasPrefix("127.") || lower.hasPrefix("10.") || lower.hasPrefix("192.168.") {
            return true
        }
        if lower.hasPrefix("169.254.") {
            return true
        }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2,
               let second = Int(parts[1]),
               (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Add web fetch tool**

Create `WebTools.swift`:

```swift
import Foundation
import LocalAgentBridge

public struct WebFetchResponse: Sendable {
    public var data: Data
    public var response: URLResponse
    public var redirectChain: [URLRequest]

    public init(data: Data, response: URLResponse, redirectChain: [URLRequest]) {
        self.data = data
        self.response = response
        self.redirectChain = redirectChain
    }
}

public protocol WebFetching: Sendable {
    func fetch(_ request: URLRequest, policy: WebFetchPolicyV1) async throws -> WebFetchResponse
}

public struct URLSessionWebFetcher: WebFetching {
    public init() {}

    public func fetch(_ request: URLRequest, policy: WebFetchPolicyV1) async throws -> WebFetchResponse {
        let delegate = RedirectRecordingDelegate(policy: policy)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
        }
        let (data, response) = try await session.data(for: request)
        if let code = delegate.redirectFailureCode {
            throw WebFetchError.policyDenied(code)
        }
        return WebFetchResponse(data: data, response: response, redirectChain: delegate.redirectChain)
    }
}

public enum WebFetchError: Error, Sendable, Equatable {
    case policyDenied(String)
}

private final class RedirectRecordingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let policy: WebFetchPolicyV1
    private var redirectCount: Int = 0
    private var storedRedirectChain: [URLRequest] = []
    private var storedFailureCode: String?

    var redirectChain: [URLRequest] {
        lock.withLock { storedRedirectChain }
    }

    var redirectFailureCode: String? {
        lock.withLock { storedFailureCode }
    }

    init(policy: WebFetchPolicyV1) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        storedRedirectChain.append(request)
        lock.unlock()

        let decision = policy.validateRedirect(
            from: task.originalRequest ?? request,
            to: request,
            redirectCount: count
        )
        switch decision {
        case .allowed:
            completionHandler(request)
        case .denied(let code):
            lock.withLock {
                storedFailureCode = code
            }
            completionHandler(nil)
        }
    }
}

public struct WebFetchURLTextTool: NativeTool {
    public let schema: NativeToolSchema
    private let policy: WebFetchPolicyV1
    private let fetcher: any WebFetching

    public init(
        policy: WebFetchPolicyV1 = .default,
        fetcher: any WebFetching = URLSessionWebFetcher()
    ) {
        self.policy = policy
        self.fetcher = fetcher
        let manifest = NativeToolManifest(
            manifestId: "native.web.fetch_url_text.v1",
            capabilityId: "web.fetch_url_text",
            title: "Fetch URL Text",
            description: "Fetch bounded text from a public HTTPS URL.",
            mode: .background,
            permissionScope: NativePermissionScope("web.fetch.approved"),
            requiredPrivacyKeys: [],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .unavailable, message: "The URL cannot be fetched under the web fetch policy."),
            riskLevel: .confirm,
            approvalPolicy: .perCall,
            trustLevel: .untrustedExternalContent,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Web Fetch", resultSummaryPolicy: .excerptOnly)
        )
        self.schema = NativeToolSchema(
            name: "web.fetch_url_text",
            description: manifest.description,
            inputSchema: .object(properties: ["url": .string()], required: ["url"]),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        guard let url = Self.decodeURL(argumentsJson) else {
            return NativeToolResultBuilder.error(
                manifestId: "native.web.fetch_url_text.v1",
                toolName: "web.fetch_url_text",
                toolCallId: "unknown",
                code: "web_fetch.invalid_arguments",
                displayText: "Expected a URL string.",
                auditSummary: "Web fetch failed: invalid arguments"
            )
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = policy.timeoutSeconds
        request.httpShouldHandleCookies = false
        request.setValue("text/html, text/plain, application/json", forHTTPHeaderField: "Accept")

        switch policy.validate(request) {
        case .allowed:
            break
        case .denied(let code):
            return NativeToolResultBuilder.error(
                manifestId: "native.web.fetch_url_text.v1",
                toolName: "web.fetch_url_text",
                toolCallId: "unknown",
                code: code,
                displayText: "This URL is blocked by the web fetch policy.",
                auditSummary: "Web fetch blocked: \(code)"
            )
        }

        do {
            let fetched = try await fetcher.fetch(request, policy: policy)
            for redirect in fetched.redirectChain {
                switch policy.validate(redirect) {
                case .allowed:
                    break
                case .denied(let code):
                    return NativeToolResultBuilder.error(
                        manifestId: "native.web.fetch_url_text.v1",
                        toolName: "web.fetch_url_text",
                        toolCallId: "unknown",
                        code: code,
                        displayText: "A redirect was blocked by the web fetch policy.",
                        auditSummary: "Web fetch blocked redirect: \(code)"
                    )
                }
            }
            guard fetched.data.count <= policy.maxResponseBytes else {
                return NativeToolResultBuilder.error(
                    manifestId: "native.web.fetch_url_text.v1",
                    toolName: "web.fetch_url_text",
                    toolCallId: "unknown",
                    code: "web_fetch.response_too_large",
                    displayText: "The response is too large.",
                    auditSummary: "Web fetch failed: response too large"
                )
            }
            if let http = fetched.response as? HTTPURLResponse,
               !policy.allowsMimeType(http.mimeType) {
                return NativeToolResultBuilder.error(
                    manifestId: "native.web.fetch_url_text.v1",
                    toolName: "web.fetch_url_text",
                    toolCallId: "unknown",
                    code: "web_fetch.mime_denied",
                    displayText: "The response type is not allowed.",
                    auditSummary: "Web fetch failed: MIME denied"
                )
            }
            let text = String(decoding: fetched.data, as: UTF8.self)
            let excerpt = String(text.prefix(policy.maxExtractedTextCharacters))
            return NativeToolResultBuilder.success(
                manifestId: "native.web.fetch_url_text.v1",
                toolName: "web.fetch_url_text",
                toolCallId: "unknown",
                displayText: "Fetched text from \(url.host() ?? url.absoluteString)",
                modelText: "External web content from \(url.absoluteString):\n\(excerpt)",
                resultKind: "web_text",
                resultPayload: [
                    "url": .string(url.absoluteString),
                    "text_excerpt": .string(excerpt),
                    "truncated": .bool(excerpt.count < text.count),
                ],
                sourceKind: "web",
                sourceId: url.absoluteString,
                displayName: url.host() ?? url.absoluteString,
                attachmentIds: [],
                trustLevel: .untrustedExternalContent,
                sensitivity: .public,
                retention: .runOnly,
                modelTextPolicy: "summarize_or_quote_only",
                sourceLabel: "Web",
                auditSummary: "Fetched text from \(url.absoluteString)",
                auditRedaction: "excerpt_only"
            )
        } catch {
            return NativeToolResultBuilder.error(
                manifestId: "native.web.fetch_url_text.v1",
                toolName: "web.fetch_url_text",
                toolCallId: "unknown",
                code: "web_fetch.network_error",
                displayText: "The URL could not be fetched.",
                auditSummary: "Web fetch failed: \(error.localizedDescription)"
            )
        }
    }

    private static func decodeURL(_ argumentsJson: String) -> URL? {
        guard let data = argumentsJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["url"] as? String
        else {
            return nil
        }
        return URL(string: value)
    }
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter WebFetchPolicyTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebFetchPolicy.swift \
  local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebTools.swift \
  local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/WebFetchPolicyTests.swift
git commit -m "feat: add bounded web fetch policy"
```

---

### Task 4: NativeAttachmentStore And PendingUserInteraction

**Files:**
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeAttachmentStore.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/PendingUserInteraction.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeAttachmentStoreTests.swift`

**Interfaces:**
- Produces: `NativeAttachmentRecord`, `NativeAttachmentAccessState`, `InMemoryNativeAttachmentStore`, `PendingUserInteractionRecord`, `PendingUserInteractionStore`, `FileBackedPendingUserInteractionStore`, `InMemoryPendingUserInteractionStore`, `PendingInteractionPresentationGate`.

- [ ] **Step 1: Write failing store tests**

Create `NativeAttachmentStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import LocalNativeToolkit

@Suite("Native attachment and pending interaction stores")
struct NativeAttachmentStoreTests {
    @Test
    func attachmentStoreTracksRepairStates() async throws {
        let store = InMemoryNativeAttachmentStore()
        let record = NativeAttachmentRecord(
            id: "att_1",
            sourceFamily: "files",
            contentType: "text/plain",
            displayName: "notes.txt",
            accessState: .available,
            sizeBytes: 12,
            sensitivity: .private,
            trustLevel: .untrustedExternalContent
        )

        await store.put(record)
        #expect(await store.get("att_1")?.accessState == .available)

        await store.markNeedsUserReselection("att_1")
        #expect(await store.get("att_1")?.accessState == .needsUserReselection)
    }

    @Test
    func pendingInteractionStoreRestoresByRunAndToolCall() async throws {
        let store = InMemoryPendingUserInteractionStore()
        let record = PendingUserInteractionRecord(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.photos.pick_images.v1",
            interactionKind: .photosPicker,
            state: .requested,
            resumablePayloadSummary: "Pick images",
            expiresAtMillis: nil
        )

        await store.put(record)
        let restored = await store.pending(runId: "run_1", toolCallId: "call_1")

        #expect(restored?.id == "pending_1")
        #expect(restored?.interactionKind == .photosPicker)
    }

    @Test
    func fileBackedPendingInteractionStoreSurvivesRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pending-interactions-\(UUID().uuidString)")
        let record = PendingUserInteractionRecord(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.files.pick_document.v1",
            interactionKind: .filePicker,
            state: .requested,
            resumablePayloadSummary: "Pick a document",
            expiresAtMillis: nil
        )

        let writer = try FileBackedPendingUserInteractionStore(directory: directory)
        try await writer.put(record)
        let reader = try FileBackedPendingUserInteractionStore(directory: directory)
        let restored = try await reader.pending(runId: "run_1", toolCallId: "call_1")

        #expect(restored?.id == "pending_1")
        #expect(restored?.state == .requested)
    }

    @Test
    func presentationGatePersistsBeforePresentingSystemUI() async throws {
        let store = InMemoryPendingUserInteractionStore()
        let record = PendingUserInteractionRecord(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.photos.pick_images.v1",
            interactionKind: .photosPicker,
            state: .requested,
            resumablePayloadSummary: "Pick images",
            expiresAtMillis: nil
        )
        var persistedBeforePresentation = false

        try await PendingInteractionPresentationGate.persistBeforePresenting(
            record,
            store: store
        ) {
            persistedBeforePresentation = try await store.pending(
                runId: "run_1",
                toolCallId: "call_1"
            ) != nil
        }

        #expect(persistedBeforePresentation)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter NativeAttachmentStoreTests
```

Expected: FAIL because the store types do not exist.

- [ ] **Step 3: Add attachment store**

Create `NativeAttachmentStore.swift`:

```swift
import Foundation
import LocalAgentBridge

public enum NativeAttachmentAccessState: String, Codable, Sendable, Equatable {
    case available
    case needsUserReselection = "needs_user_reselection"
    case unavailable
}

public struct NativeAttachmentRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sourceFamily: String
    public var contentType: String
    public var displayName: String
    public var accessState: NativeAttachmentAccessState
    public var sizeBytes: Int
    public var sensitivity: SensitivityDTO
    public var trustLevel: NativeToolTrustLevel

    public init(
        id: String,
        sourceFamily: String,
        contentType: String,
        displayName: String,
        accessState: NativeAttachmentAccessState,
        sizeBytes: Int,
        sensitivity: SensitivityDTO,
        trustLevel: NativeToolTrustLevel
    ) {
        self.id = id
        self.sourceFamily = sourceFamily
        self.contentType = contentType
        self.displayName = displayName
        self.accessState = accessState
        self.sizeBytes = sizeBytes
        self.sensitivity = sensitivity
        self.trustLevel = trustLevel
    }
}

public actor InMemoryNativeAttachmentStore {
    private var records: [String: NativeAttachmentRecord] = [:]

    public init() {}

    public func put(_ record: NativeAttachmentRecord) {
        records[record.id] = record
    }

    public func get(_ id: String) -> NativeAttachmentRecord? {
        records[id]
    }

    public func markNeedsUserReselection(_ id: String) {
        guard var record = records[id] else {
            return
        }
        record.accessState = .needsUserReselection
        records[id] = record
    }
}
```

- [ ] **Step 4: Add pending interaction store**

Create `PendingUserInteraction.swift`:

```swift
import Foundation

public enum PendingInteractionKind: String, Codable, Sendable, Equatable {
    case filePicker = "file_picker"
    case photosPicker = "photos_picker"
    case documentScanner = "document_scanner"
    case systemConfirmation = "system_confirmation"
}

public enum PendingInteractionState: String, Codable, Sendable, Equatable {
    case requested
    case awaitingUserAction = "awaiting_user_action"
    case presentingSystemUI = "presenting_system_ui"
    case completed
    case cancelledByUser = "cancelled_by_user"
    case interrupted
    case needsRepair = "needs_repair"
    case expired
    case failed
}

public struct PendingUserInteractionRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var runId: String
    public var toolCallId: String
    public var manifestId: String
    public var interactionKind: PendingInteractionKind
    public var state: PendingInteractionState
    public var resumablePayloadSummary: String
    public var expiresAtMillis: UInt64?

    public init(
        id: String,
        runId: String,
        toolCallId: String,
        manifestId: String,
        interactionKind: PendingInteractionKind,
        state: PendingInteractionState,
        resumablePayloadSummary: String,
        expiresAtMillis: UInt64?
    ) {
        self.id = id
        self.runId = runId
        self.toolCallId = toolCallId
        self.manifestId = manifestId
        self.interactionKind = interactionKind
        self.state = state
        self.resumablePayloadSummary = resumablePayloadSummary
        self.expiresAtMillis = expiresAtMillis
    }
}

public protocol PendingUserInteractionStore: Sendable {
    func put(_ record: PendingUserInteractionRecord) async throws
    func pending(runId: String, toolCallId: String) async throws -> PendingUserInteractionRecord?
}

public actor InMemoryPendingUserInteractionStore: PendingUserInteractionStore {
    private var records: [String: PendingUserInteractionRecord] = [:]

    public init() {}

    public func put(_ record: PendingUserInteractionRecord) async throws {
        records[record.id] = record
    }

    public func pending(runId: String, toolCallId: String) async throws -> PendingUserInteractionRecord? {
        records.values.first { record in
            record.runId == runId && record.toolCallId == toolCallId
        }
    }
}

public actor FileBackedPendingUserInteractionStore: PendingUserInteractionStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    public func put(_ record: PendingUserInteractionRecord) async throws {
        let data = try encoder.encode(record)
        try data.write(to: fileURL(for: record.id), options: [.atomic])
    }

    public func pending(runId: String, toolCallId: String) async throws -> PendingUserInteractionRecord? {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in urls where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            let record = try decoder.decode(PendingUserInteractionRecord.self, from: data)
            if record.runId == runId && record.toolCallId == toolCallId {
                return record
            }
        }
        return nil
    }

    private func fileURL(for id: String) -> URL {
        directory.appending(path: "\(id).json")
    }
}

public enum PendingInteractionPresentationGate {
    public static func persistBeforePresenting(
        _ record: PendingUserInteractionRecord,
        store: any PendingUserInteractionStore,
        present: () async throws -> Void
    ) async throws {
        try await store.put(record)
        try await present()
    }
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter NativeAttachmentStoreTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeAttachmentStore.swift \
  local-ios-agent/toolkit/Sources/LocalNativeToolkit/PendingUserInteraction.swift \
  local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeAttachmentStoreTests.swift
git commit -m "feat: add native attachment interaction stores"
```

---

### Task 5: Update Existing Native Tools To Manifest And Envelope

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/CalendarTools.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/ReminderTools.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/MetaTools.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/MetaToolsTests.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeCapabilityToolsTests.swift`

**Interfaces:**
- Consumes: `NativeToolManifest`, `NativeToolResultBuilder`.
- Produces: existing calendar/reminder/meta tools with manifest metadata and envelope-shaped results.

- [ ] **Step 1: Write failing test for meta tool envelope**

Add to `MetaToolsTests.swift`:

```swift
@Test
func listToolsReturnsEnvelopeWithTrustedToolResultAndToolArray() async throws {
    let tool = NativeListToolsTool(catalogProvider: {
        try NativeToolCatalog(tools: [
            MetaStubTool(name: "zeta.tool", riskLevel: .confirm, permissionScope: "zeta.scope"),
            MetaStubTool(name: "alpha.tool", riskLevel: .readOnly, permissionScope: nil),
        ])
    })

    let result = await tool.execute(argumentsJson: "{}")
    let data = try #require(result.structuredJson.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let payload = try #require(object["result"] as? [String: Any])
    let tools = try #require(payload["tools"] as? [[String: Any]])
    let provenance = try #require(object["provenance"] as? [String: Any])

    #expect(object["schema_version"] as? Int == 1)
    #expect(object["manifest_id"] as? String == "native.native.list_tools.v1")
    #expect(provenance["trust_level"] as? String == "trusted_tool_result")
    #expect(tools.map { $0["name"] as? String } == ["alpha.tool", "zeta.tool"])
    #expect(tools[0]["risk_level"] as? String == "read_only")
    #expect(tools[1]["permission_scope"] as? String == "zeta.scope")
    #expect(result.isError == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter MetaToolsTests/listToolsReturnsEnvelopeWithTrustedToolResultAndToolArray
```

Expected: FAIL because the tool still returns older structured JSON.

- [ ] **Step 3: Add helper manifests in each tool file**

In each tool file, add a private manifest property. Example for `NativeListToolsTool`:

```swift
private var manifest: NativeToolManifest {
    NativeToolManifest(
        manifestId: "native.native.list_tools.v1",
        capabilityId: "native.list_tools",
        title: "List Tools",
        description: "List available native tools.",
        mode: .background,
        permissionScope: nil,
        requiredPrivacyKeys: [],
        requiresForegroundUI: false,
        minimumOS: "iOS 17.0",
        regionPolicy: "available_with_service_fallback",
        fallback: NativeToolFallback(kind: .none, message: ""),
        riskLevel: .readOnly,
        approvalPolicy: .never,
        trustLevel: .trustedToolResult,
        retention: .runOnly,
        audit: NativeToolAudit(label: "List Tools", resultSummaryPolicy: .metadataOnly)
    )
}
```

Pass `manifest: manifest` when constructing `NativeToolSchema`.

- [ ] **Step 4: Return envelope-shaped results**

Build meta tool summaries in sorted order:

```swift
let toolSummaries = catalog.schemas
    .map { schema in
        ToolSummary(
            name: schema.name,
            riskLevel: schema.riskLevel,
            permissionScope: schema.permissionScope?.name
        )
    }
    .sorted { $0.name < $1.name }
let toolCount = toolSummaries.count
```

For successful meta tool results, return:

```swift
NativeToolResultBuilder.success(
    manifestId: manifest.manifestId,
    toolName: schema.name,
    toolCallId: "unknown",
    displayText: displayText,
    modelText: modelText,
    resultKind: "native_tool_status",
    resultPayload: [
        "count": .number(Double(toolCount)),
        "tools": .array(toolSummaries.map { summary in
            .object([
                "name": .string(summary.name),
                "risk_level": .string(riskLevelString(summary.riskLevel)),
                "permission_scope": summary.permissionScope.map(JSONValue.string) ?? .string(""),
            ])
        }),
    ],
    sourceKind: "tool",
    sourceId: schema.name,
    displayName: manifest.title,
    attachmentIds: [],
    trustLevel: manifest.trustLevel,
    sensitivity: .public,
    retention: manifest.retention,
    modelTextPolicy: "tool_status",
    sourceLabel: "Tool",
    auditSummary: manifest.audit.label,
    auditRedaction: manifest.audit.resultSummaryPolicy.rawValue
)
```

Add this local helper in `MetaTools.swift`:

```swift
private func riskLevelString(_ riskLevel: NativeToolRiskLevel) -> String {
    switch riskLevel {
    case .readOnly:
        "read_only"
    case .confirm:
        "confirm"
    case .destructive:
        "destructive"
    }
}
```

Use the same pattern for Calendar and Reminder tools, with their manifest ids and permission scopes:

```swift
"native.calendar.search_events.v1" -> "calendar.events.read_full"
"native.reminders.create.v1" -> "reminders.full"
```

- [ ] **Step 5: Run focused native toolkit tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter LocalNativeToolkitTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/CalendarTools.swift \
  local-ios-agent/toolkit/Sources/LocalNativeToolkit/ReminderTools.swift \
  local-ios-agent/toolkit/Sources/LocalNativeToolkit/MetaTools.swift \
  local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/MetaToolsTests.swift \
  local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeCapabilityToolsTests.swift
git commit -m "feat: envelope native tool outputs"
```

---

### Task 6: Rust Profile Revision Pinning

**Files:**
- Modify: `local-ios-agent/rust-core/src/run_snapshot/snapshot.rs`
- Modify: `local-ios-agent/rust-core/src/run_snapshot/resolver.rs`
- Modify: `local-ios-agent/rust-core/src/execution/execution_service.rs`
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`
- Modify: `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`

**Interfaces:**
- Consumes: existing `AgentProfileId`, `AgentProfileVersion`, `AgentProfileReference::pinned`.
- Produces: start run path that requires profile revision and resolves exact revision.

- [ ] **Step 1: Add failing contract test**

In `local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`, import `AgentProfileVersion` from `user_customization` and add:

```rust
#[test]
fn start_run_uses_pinned_profile_revision_not_latest() {
    let service = RunSnapshotService::fixture_with_profile_version(2);

    let error = service
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::new(1),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.profile_revision_missing");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd local-ios-agent/rust-core
cargo test start_run_uses_pinned_profile_revision_not_latest
```

Expected: FAIL because `StartRunRequest::new` does not accept `AgentProfileVersion`.

- [ ] **Step 3: Add profile version to StartRunRequest**

In `snapshot.rs`, change `StartRunRequest`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StartRunRequest {
    agent_profile_id: AgentProfileId,
    profile_revision_id: AgentProfileVersion,
    user_intent: RunUserIntent,
    conversation_run_frame_ref: ConversationRunFrameRef,
}
```

Change constructor:

```rust
pub fn new(
    agent_profile_id: impl Into<String>,
    profile_revision_id: AgentProfileVersion,
    user_intent: impl Into<String>,
    conversation_run_frame_ref: ConversationRunFrameRef,
) -> Self {
    Self {
        agent_profile_id: AgentProfileId::new(agent_profile_id),
        profile_revision_id,
        user_intent: RunUserIntent::new(user_intent),
        conversation_run_frame_ref,
    }
}
```

Add accessor:

```rust
pub fn profile_revision_id(&self) -> AgentProfileVersion {
    self.profile_revision_id
}
```

- [ ] **Step 4: Resolve pinned profile**

In `resolver.rs`, replace:

```rust
let profile = self.profile(request.agent_profile_id())?;
```

with:

```rust
let profile = self.profile(request.agent_profile_id(), request.profile_revision_id())?;
```

Change helper:

```rust
fn profile(
    &self,
    profile_id: &AgentProfileId,
    profile_revision_id: AgentProfileVersion,
) -> RunSnapshotResult<AgentProfile> {
    self.profile_repository
        .profile(&AgentProfileReference::pinned(profile_id.clone(), profile_revision_id))
        .ok_or_else(|| {
            RunSnapshotError::new(
                "snapshot.profile_revision_missing",
                "agent profile revision could not be found for run snapshot resolution",
            )
        })
}
```

- [ ] **Step 5: Update FFI JSON request**

In `ffi_bridge.rs`, change `StartRunRequestJson`:

```rust
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StartRunRequestJson {
    agent_profile_id: String,
    profile_revision_id: u64,
    user_intent: String,
    conversation_run_frame_ref: ConversationRunFrameRefJson,
    #[serde(default)]
    options: Value,
}
```

Change start call:

```rust
.start_run(StartExecutionRequest::new(
    run_id,
    request.agent_profile_id,
    AgentProfileVersion::new(request.profile_revision_id),
    request.user_intent,
    frame_ref,
))
```

Update `StartExecutionRequest::new` and `ExecutionService` to carry `AgentProfileVersion` into `StartRunRequest::new(...)`.

- [ ] **Step 6: Run Rust tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test run_snapshot
cargo test ffi_bridge
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/rust-core/src/run_snapshot/snapshot.rs \
  local-ios-agent/rust-core/src/run_snapshot/resolver.rs \
  local-ios-agent/rust-core/src/execution/execution_service.rs \
  local-ios-agent/rust-core/src/ffi_bridge.rs \
  local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs \
  local-ios-agent/rust-core/tests/integration/ffi_bridge.rs
git commit -m "feat: pin runs to agent profile revisions"
```

---

### Task 7: Swift Profile Revision DTO And Bridge Propagation

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentBuilderClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/MockRuntimeClient.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ChatInteractionCoordinator.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentProfileRevisionDTOTests.swift`

**Interfaces:**
- Consumes: Rust FFI `profile_revision_id: u64`.
- Produces: `AgentProfileDTO.profileRevisionId`, `StartExecutionRequestDTO.profileRevisionId`.

- [ ] **Step 1: Write failing DTO encoding test**

Create `AgentProfileRevisionDTOTests.swift`:

```swift
import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Agent profile revision DTOs")
struct AgentProfileRevisionDTOTests {
    @Test
    func startExecutionRequestEncodesProfileRevisionId() throws {
        let request = StartExecutionRequestDTO(
            agentProfileId: "profile_1",
            profileRevisionId: 1,
            userIntent: "hello",
            conversationRunFrameRef: ConversationRunFrameRefDTO(
                frameId: "frame_1",
                sessionId: "session_1",
                branchHeadId: "user_1",
                userTurnId: "user_1"
            )
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["agent_profile_id"] as? String == "profile_1")
        #expect(object["profile_revision_id"] as? Int == 1)
        #expect(object["user_intent"] as? String == "hello")
    }

    @Test
    func agentProfileDTOCarriesLatestRevision() throws {
        let profile = AgentProfileDTO(
            profileId: "profile_1",
            profileRevisionId: 2,
            displayName: "Assistant"
        )

        let data = try JSONEncoder().encode(profile)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["profile_id"] as? String == "profile_1")
        #expect(object["profile_revision_id"] as? Int == 2)
    }
}
```

Add these runtime tests to `AgentRuntimeServiceTests.swift`:

```swift
@Test("coordinator path passes seed profile revision")
@MainActor
func coordinatorPathPassesSeedProfileRevision() async throws {
    let coordinator = RecordingChatInteractionCoordinator()
    let service = AgentRuntimeService(
        runtimeClient: ScriptedRuntimeClient(),
        toolDriver: MinimalHostToolDriver(),
        coordinator: coordinator
    )

    _ = try await service.sendMessage(
        "hello",
        state: AgentViewState(phase: .ready, currentSessionId: "session_1")
    )

    #expect(coordinator.agentProfileRevisionIds == [1])
}

@Test("coordinator path rejects explicitly missing profile revision")
@MainActor
func coordinatorPathRejectsExplicitlyMissingProfileRevision() async throws {
    let coordinator = RecordingChatInteractionCoordinator()
    let service = AgentRuntimeService(
        runtimeClient: ScriptedRuntimeClient(),
        toolDriver: MinimalHostToolDriver(),
        coordinator: coordinator
    )
    var state = AgentViewState(phase: .ready, currentSessionId: "session_1")
    state.selectedAgentProfileRevisionId = nil

    await #expect(throws: AgentRuntimeServiceError.missingAgentProfileRevision) {
        _ = try await service.sendMessage("hello", state: state)
    }

    #expect(coordinator.sentMessages.isEmpty)
}

@Test("coordinator path passes selected profile revision")
@MainActor
func coordinatorPathPassesSelectedProfileRevision() async throws {
    let coordinator = RecordingChatInteractionCoordinator()
    let service = AgentRuntimeService(
        runtimeClient: ScriptedRuntimeClient(),
        toolDriver: MinimalHostToolDriver(),
        coordinator: coordinator
    )
    var state = AgentViewState(phase: .ready, currentSessionId: "session_1")
    state.selectedAgentProfileRevisionId = 7

    _ = try await service.sendMessage("hello", state: state)

    #expect(coordinator.agentProfileRevisionIds == [7])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter AgentProfileRevisionDTOTests
```

Expected: FAIL because DTO initializers do not accept `profileRevisionId`.

Run:

```bash
cd local-ios-agent
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentRuntimeServiceTests
```

Expected: FAIL because `AgentRuntimeServiceError.missingAgentProfileRevision`, `selectedAgentProfileRevisionId`, and coordinator revision parameters do not exist.

- [ ] **Step 3: Add DTO and state fields**

In `AgentOSDTOs.swift`, change `StartExecutionRequestDTO`:

```swift
public struct StartExecutionRequestDTO: Codable, Equatable, Sendable {
    public var agentProfileId: String
    public var profileRevisionId: UInt64
    public var userIntent: String
    public var conversationRunFrameRef: ConversationRunFrameRefDTO
    public var options: ExecutionOptionsDTO

    public init(
        agentProfileId: String,
        profileRevisionId: UInt64,
        userIntent: String,
        conversationRunFrameRef: ConversationRunFrameRefDTO,
        options: ExecutionOptionsDTO = ExecutionOptionsDTO()
    ) {
        self.agentProfileId = agentProfileId
        self.profileRevisionId = profileRevisionId
        self.userIntent = userIntent
        self.conversationRunFrameRef = conversationRunFrameRef
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case agentProfileId = "agent_profile_id"
        case profileRevisionId = "profile_revision_id"
        case userIntent = "user_intent"
        case conversationRunFrameRef = "conversation_run_frame_ref"
        case options
    }
}
```

Change `AgentProfileDTO`:

```swift
public struct AgentProfileDTO: Codable, Equatable, Sendable {
    public var profileId: String
    public var profileRevisionId: UInt64
    public var displayName: String

    public init(profileId: String, profileRevisionId: UInt64, displayName: String) {
        self.profileId = profileId
        self.profileRevisionId = profileRevisionId
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case profileRevisionId = "profile_revision_id"
        case displayName = "display_name"
    }
}
```

In `AgentViewState.swift`, add:

```swift
// Development seed profile revision for the current hard-coded profile_1.
// Replace this with the published Agent Builder revision once Builder persistence lands.
var selectedAgentProfileRevisionId: UInt64? = 1
```

- [ ] **Step 4: Update mocks and coordinator**

In `AgentBuilderClient.swift`, update mock publish:

```swift
public func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO {
    AgentProfileDTO(
        profileId: draft.profileId,
        profileRevisionId: 1,
        displayName: model.displayName
    )
}
```

In `ChatInteractionCoordinator`, add parameter:

```swift
profileRevisionId: UInt64,
```

and pass it:

```swift
StartExecutionRequestDTO(
    agentProfileId: agentProfileId,
    profileRevisionId: profileRevisionId,
    userIntent: text,
    conversationRunFrameRef: preparedTurn.conversationRunFrameRef,
    options: options
)
```

In `AgentRuntimeServiceError`, add:

```swift
case missingAgentProfileRevision
```

In `AgentRuntimeService`, reject missing profile revision before calling the coordinator:

```swift
guard let profileRevisionId = state.selectedAgentProfileRevisionId else {
    throw AgentRuntimeServiceError.missingAgentProfileRevision
}
let result = try await coordinator.sendMessage(
    text: text,
    sessionId: state.currentSessionId,
    parentEventId: state.draft.targetParentEventId,
    agentProfileId: state.selectedAgentProfileId,
    profileRevisionId: profileRevisionId,
    options: state.executionOptions,
    onEvent: { event in
        await collector.apply(event)
        await onEvent(event)
    }
)
```

In `RecordingChatInteractionCoordinator`, add:

```swift
private(set) var agentProfileRevisionIds: [UInt64] = []
```

and append `profileRevisionId` inside the test double's `sendMessage`.

Only seed/mock clients may default to revision `1`. Put that fallback in `MockAgentBuilderClient.publishProfile` and fixture setup, not in `AgentRuntimeService`.

```swift
public func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO {
    AgentProfileDTO(
        profileId: draft.profileId,
        profileRevisionId: publishedRevision,
        displayName: model.displayName
    )
}
```

- [ ] **Step 5: Run Swift bridge tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter AgentProfileRevisionDTOTests
```

Expected: PASS.

Run:

```bash
cd local-ios-agent
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentRuntimeServiceTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift \
  local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentBuilderClient.swift \
  local-ios-agent/toolkit/Sources/LocalAgentBridge/MockRuntimeClient.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ChatInteractionCoordinator.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentProfileRevisionDTOTests.swift
git commit -m "feat: propagate agent profile revisions in swift"
```

---

### Task 8: Agent Builder Draft Lifecycle Foundation

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderViewModelTests.swift`

**Interfaces:**
- Consumes: `AgentBuilderClient.publishProfile`.
- Produces: `AgentDraftLifecycleState`, `publishedProfileRevisionId`, version-token validation guard.

- [ ] **Step 1: Add lifecycle enum**

In `AgentBuilderViewModel.swift`, add:

```swift
enum AgentDraftLifecycleState: Equatable, Sendable {
    case empty
    case editing
    case dirty
    case validating
    case invalid
    case readyToPublish
    case publishing
    case published(profileRevisionId: UInt64)
    case publishFailed(String)
}
```

Add properties:

```swift
var lifecycle: AgentDraftLifecycleState = .empty
var publishedProfileRevisionId: UInt64?
private var draftVersion: UInt64 = 0
```

- [ ] **Step 2: Add lifecycle tests**

Add these tests to `AgentBuilderViewModelTests.swift`:

```swift
@Test("editing after validation returns draft to dirty")
func editingAfterValidationReturnsDraftToDirty() async {
    let viewModel = AgentBuilderViewModel.fixtureReadyToPublish()

    await viewModel.validateCurrentDraft()
    #expect(viewModel.lifecycle == .readyToPublish)

    viewModel.markEdited()
    #expect(viewModel.lifecycle == .dirty)
}

@Test("publish pins returned profile revision")
func publishPinsReturnedProfileRevision() async {
    let viewModel = AgentBuilderViewModel.fixtureReadyToPublish(publishedRevision: 3)

    await viewModel.validateCurrentDraft()
    await viewModel.publishCurrentDraft()

    #expect(viewModel.publishedProfileRevisionId == 3)
    #expect(viewModel.lifecycle == .published(profileRevisionId: 3))
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
cd local-ios-agent
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderViewModelTests
```

Expected: FAIL because `AgentDraftLifecycleState`, `fixtureReadyToPublish`, and lifecycle methods do not exist.

- [ ] **Step 4: Add edit and validation guards**

Add methods:

```swift
func markEdited() {
    draftVersion += 1
    switch lifecycle {
    case .validating, .invalid, .readyToPublish, .editing, .published, .publishFailed, .empty:
        lifecycle = .dirty
    case .dirty, .publishing:
        break
    }
}

func validateCurrentDraft() async {
    let version = draftVersion
    lifecycle = .validating
    await refreshReadiness()
    guard version == draftVersion else {
        lifecycle = .dirty
        return
    }
    lifecycle = readiness.issues.isEmpty ? .readyToPublish : .invalid
}
```

- [ ] **Step 5: Add publish**

Add method:

```swift
func publishCurrentDraft() async {
    guard lifecycle == .readyToPublish else {
        return
    }
    let version = draftVersion
    lifecycle = .publishing
    do {
        let profile = try await builderClient.publishProfile(AgentBuilderDraftDTO(profileId: profileId))
        guard version == draftVersion else {
            lifecycle = .dirty
            return
        }
        publishedProfileRevisionId = profile.profileRevisionId
        lifecycle = .published(profileRevisionId: profile.profileRevisionId)
    } catch {
        lifecycle = .publishFailed(error.localizedDescription)
    }
}
```

- [ ] **Step 6: Add ready fixture**

Add this fixture to `AgentBuilderViewModel.swift`:

```swift
static func fixtureReadyToPublish(publishedRevision: UInt64 = 1) -> AgentBuilderViewModel {
    AgentBuilderViewModel(
        profileId: "profile_1",
        builderClient: MockAgentBuilderClient.readyToPublish(publishedRevision: publishedRevision),
        permissionClient: MockPermissionClient(issues: [])
    )
}
```

Add this helper to `MockAgentBuilderClient`:

```swift
public static func readyToPublish(publishedRevision: UInt64 = 1) -> Self {
    Self(model: AgentBuilderUIModel(
        profileId: "profile_1",
        displayName: "Assistant",
        readiness: PermissionReadinessUIModel()
    ), publishedRevision: publishedRevision)
}
```

Extend the mock actor with a stored `publishedRevision: UInt64` and return that value from `publishProfile`.

- [ ] **Step 7: Verify app tests**

Run:

```bash
cd local-ios-agent
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderViewModelTests
```

Expected: PASS.

- [ ] **Step 8: Run relevant Swift package tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderViewModel.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderViewModelTests.swift \
  local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentBuilderClient.swift
git commit -m "feat: add agent builder draft lifecycle"
```

---

## Final Verification

After all tasks are complete, run:

```bash
cd local-ios-agent/toolkit
swift test
```

Expected: all Swift package tests pass.

Run:

```bash
cd local-ios-agent/rust-core
cargo test
```

Expected: all Rust tests pass.

Run:

```bash
cd local-ios-agent
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: LocalAgentApp and LocalAgentAppTests build and pass.

Run:

```bash
git -C "$(git rev-parse --show-toplevel)" status --short
```

Expected: only pre-existing untracked files remain, or no output if the workspace is clean.

## Handoff Notes

- Implement tasks in order. Task 1 and Task 2 establish contracts consumed by later tasks.
- Do not implement Conversation Workspace inline cards in this plan. Use `2026-07-07-swift-conversation-workspace-design.md` for that follow-up.
- Do not move model download/provider management into Rust. Swift owns model readiness and routing.
- Do not add arbitrary user-defined native tools. This plan only builds the first-party native toolkit contract.
