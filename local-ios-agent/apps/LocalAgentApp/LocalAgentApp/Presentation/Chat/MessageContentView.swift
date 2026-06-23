import SwiftUI
import UIKit

struct MessageContentView: View {
    let message: AgentMessageViewState
    let isUserMessage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.parts) { part in
                switch part {
                case .text(let text):
                    Text(text.text)
                        .font(.body)
                        .textSelection(.enabled)
                case .reasoning(let reasoning):
                    ReasoningBlockView(reasoning: reasoning)
                case .tool(let tool):
                    Label(tool.displayText, systemImage: "wrench.and.screwdriver")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .error(let error):
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                case .attachment(let attachment):
                    AttachmentChipView(attachment: attachment, isUserMessage: isUserMessage)
                }
            }

            ForEach(message.attachments) { attachment in
                AttachmentChipView(attachment: attachment, isUserMessage: isUserMessage)
            }

            if message.isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

struct ReasoningBlockView: View {
    let reasoning: ReasoningPartViewState
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(reasoning.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(reasoning.isStreaming ? "Thinking..." : "Reasoning", systemImage: "brain.head.profile")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onAppear {
            isExpanded = !reasoning.isCollapsed
        }
        .onChange(of: reasoning.isCollapsed) {
            isExpanded = !reasoning.isCollapsed
        }
    }
}

private struct AttachmentChipView: View {
    let attachment: AttachmentViewState
    let isUserMessage: Bool

    var body: some View {
        if attachment.kind == .image, let image = image {
            VStack(alignment: .leading, spacing: 6) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 148, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Label(attachment.displayName, systemImage: "photo")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(labelForeground)
            }
            .padding(6)
            .background(chipBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Label(attachment.displayName, systemImage: attachmentIconName)
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(labelForeground)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(chipBackground, in: Capsule())
        }
    }

    private var attachmentIconName: String {
        switch attachment.kind {
        case .image:
            "photo"
        case .link:
            "link"
        case .file:
            "doc.text"
        }
    }

    private var image: UIImage? {
        if let localPath = attachment.localPath,
           let image = UIImage(contentsOfFile: localPath)
        {
            return image
        }
        guard let previewImageData = attachment.previewImageData else {
            return rgbImage
        }
        return UIImage(data: previewImageData) ?? rgbImage
    }

    private var rgbImage: UIImage? {
        guard let width = attachment.imageWidth,
              let height = attachment.imageHeight,
              width > 0,
              height > 0,
              let rgbDataBase64 = attachment.rgbDataBase64,
              let rgbData = Data(base64Encoded: rgbDataBase64),
              rgbData.count == width * height * 3
        else {
            return nil
        }

        var rgbaData = Data(count: width * height * 4)
        rgbaData.withUnsafeMutableBytes { rgbaBuffer in
            rgbData.withUnsafeBytes { rgbBuffer in
                let rgbBytes = rgbBuffer.bindMemory(to: UInt8.self)
                let rgbaBytes = rgbaBuffer.bindMemory(to: UInt8.self)

                for pixelIndex in 0..<(width * height) {
                    let rgbIndex = pixelIndex * 3
                    let rgbaIndex = pixelIndex * 4
                    rgbaBytes[rgbaIndex] = rgbBytes[rgbIndex]
                    rgbaBytes[rgbaIndex + 1] = rgbBytes[rgbIndex + 1]
                    rgbaBytes[rgbaIndex + 2] = rgbBytes[rgbIndex + 2]
                    rgbaBytes[rgbaIndex + 3] = 255
                }
            }
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: rgbaData as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private var labelForeground: Color {
        isUserMessage ? .white : .primary
    }

    private var chipBackground: Color {
        isUserMessage ? .white.opacity(0.18) : Color(.tertiarySystemBackground)
    }
}
