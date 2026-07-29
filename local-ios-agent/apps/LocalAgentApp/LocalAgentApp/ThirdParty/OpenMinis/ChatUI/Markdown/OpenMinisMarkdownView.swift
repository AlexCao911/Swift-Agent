import SwiftUI
import UIKit

/// Product-facing renderer backed by OpenMinis' cmark AST and math renderers.
/// The renderer owns presentation only; prompt and agent context remain in Rust.
struct OpenMinisMarkdownView: View {
    private let content: MarkdownContent

    init(_ markdown: String) {
        content = MarkdownContent(markdown)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
                OpenMinisMarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct OpenMinisMarkdownBlockView: View {
    let block: BlockNode

    @ViewBuilder
    var body: some View {
        switch block {
        case let .blockquote(children):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                nestedBlocks(children)
            }

        case let .bulletedList(_, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        nestedBlocks(items[index].children)
                    }
                }
            }

        case let .numberedList(_, start, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + index).")
                            .monospacedDigit()
                        nestedBlocks(items[index].children)
                    }
                }
            }

        case let .taskList(_, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: items[index].isCompleted ? "checkmark.square.fill" : "square")
                            .foregroundStyle(items[index].isCompleted ? Color.accentColor : Color.secondary)
                        nestedBlocks(items[index].children)
                    }
                }
            }

        case let .codeBlock(fenceInfo, content):
            VStack(alignment: .leading, spacing: 6) {
                if let language = fenceInfo?.split(separator: " ").first, !language.isEmpty {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        case let .htmlBlock(content):
            Text(content)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)

        case let .paragraph(content):
            Text(OpenMinisMarkdownAttributedText.make(content))
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, content):
            Text(OpenMinisMarkdownAttributedText.make(content))
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 4 : 0)

        case let .table(_, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        GridRow {
                            ForEach(rows[rowIndex].cells.indices, id: \.self) { cellIndex in
                                Text(OpenMinisMarkdownAttributedText.make(
                                    rows[rowIndex].cells[cellIndex].content
                                ))
                                .font(rowIndex == 0 ? .callout.bold() : .callout)
                                .padding(.vertical, 2)
                            }
                        }
                        if rowIndex == 0 {
                            Divider()
                        }
                    }
                }
                .padding(10)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .thematicBreak:
            Divider()

        case let .mathBlock(content):
            OpenMinisMathBlockView(latex: content)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }

    private func nestedBlocks(_ blocks: [BlockNode]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                OpenMinisMarkdownBlockView(block: child)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private enum OpenMinisMarkdownAttributedText {
    static func make(_ nodes: [InlineNode]) -> AttributedString {
        AttributedString(render(nodes, traits: []))
    }

    private static func render(
        _ nodes: [InlineNode],
        traits: UIFontDescriptor.SymbolicTraits
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for node in nodes {
            switch node {
            case let .text(value):
                result.append(styledText(value, traits: traits))
            case .softBreak:
                result.append(styledText(" ", traits: traits))
            case .lineBreak:
                result.append(styledText("\n", traits: traits))
            case let .code(code):
                result.append(NSAttributedString(
                    string: code,
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                        .foregroundColor: UIColor.label,
                        .backgroundColor: UIColor.secondarySystemFill,
                    ]
                ))
            case let .html(html):
                result.append(styledText(html, traits: traits))
            case let .emphasis(children):
                result.append(render(children, traits: traits.union(.traitItalic)))
            case let .strong(children):
                result.append(render(children, traits: traits.union(.traitBold)))
            case let .strikethrough(children):
                let value = NSMutableAttributedString(attributedString: render(children, traits: traits))
                value.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: 0, length: value.length)
                )
                result.append(value)
            case let .link(destination, children):
                let value = NSMutableAttributedString(attributedString: render(children, traits: traits))
                if let url = URL(string: destination) {
                    value.addAttribute(.link, value: url, range: NSRange(location: 0, length: value.length))
                }
                result.append(value)
            case let .image(source, children):
                let alt = render(children, traits: traits).string
                result.append(styledText(alt.isEmpty ? source : alt, traits: traits))
            case let .inlineMath(latex):
                if let rendered = SwiftMathRenderer.render(
                    latex: latex,
                    displayMode: false,
                    fontSize: 16
                ) {
                    let attachment = NSTextAttachment()
                    attachment.image = rendered.image
                    attachment.bounds = CGRect(
                        x: 0,
                        y: -3,
                        width: rendered.size.width,
                        height: rendered.size.height
                    )
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    result.append(styledText("$\(latex)$", traits: traits))
                }
            }
        }
        return result
    }

    private static func styledText(
        _ value: String,
        traits: UIFontDescriptor.SymbolicTraits
    ) -> NSAttributedString {
        let base = UIFont.systemFont(ofSize: 16)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        return NSAttributedString(
            string: value,
            attributes: [
                .font: UIFont(descriptor: descriptor, size: 16),
                .foregroundColor: UIColor.label,
            ]
        )
    }
}

@MainActor
private struct OpenMinisMathBlockView: View {
    let latex: String
    @State private var renderedImage: UIImage?

    var body: some View {
        Group {
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Math formula: \(latex)")
            } else {
                Text(latex)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: 180)
        .task(id: latex) {
            if let native = SwiftMathRenderer.render(
                latex: latex,
                displayMode: true,
                fontSize: 18
            ) {
                renderedImage = native.image
                return
            }

            KaTeXRenderer.shared.renderCached(
                latex: latex,
                displayMode: true,
                fontSize: 18
            ) { image, _ in
                renderedImage = image
            }
        }
    }
}
