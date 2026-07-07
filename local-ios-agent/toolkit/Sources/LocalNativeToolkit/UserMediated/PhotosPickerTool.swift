import LocalAgentBridge

public struct PhotosPickImagesTool: NativeTool {
    public let schema: NativeToolSchema

    public init() {
        let manifest = Self.manifest
        self.schema = NativeToolSchema(
            name: "photos.pick_images",
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
            interactionKind: "photos_picker",
            displayText: "Choose images to continue."
        )
    }

    private static var manifest: NativeToolManifest {
        userMediatedManifest(
            manifestId: "native.photos.pick_images.v1",
            capabilityId: "photos.pick_images",
            title: "Pick Images",
            description: "Ask the user to choose images."
        )
    }
}
