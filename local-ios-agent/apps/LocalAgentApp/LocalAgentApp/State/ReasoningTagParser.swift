struct ReasoningTagParser: Equatable, Sendable {
    private var buffer: String

    init() {
        buffer = ""
    }

    mutating func append(_ chunk: String) {
        buffer += chunk
    }

    func snapshot(isFinal: Bool) -> [MessagePartViewState] {
        parse(buffer, isFinal: isFinal)
    }

    mutating func finish() -> [MessagePartViewState] {
        snapshot(isFinal: true)
    }

    private enum Mode {
        case text
        case reasoning
    }

    private func parse(_ source: String, isFinal: Bool) -> [MessagePartViewState] {
        let openingTag = "<think>"
        let closingTag = "</think>"
        var index = source.startIndex
        var mode = Mode.text
        var textBuffer = ""
        var reasoningBuffer = ""
        var parts: [MessagePartViewState] = []

        func nextId(prefix: String) -> String {
            "\(prefix)_\(parts.count)"
        }

        func appendTextPart() {
            guard !textBuffer.isEmpty else {
                return
            }
            parts.append(.text(TextPartViewState(id: nextId(prefix: "text"), text: textBuffer)))
            textBuffer = ""
        }

        func appendReasoningPart(isClosed: Bool) {
            guard !reasoningBuffer.isEmpty || !isClosed else {
                return
            }
            let isStreaming = !isFinal && !isClosed
            parts.append(.reasoning(ReasoningPartViewState(
                id: nextId(prefix: "reasoning"),
                text: reasoningBuffer,
                isCollapsed: !isStreaming,
                isStreaming: isStreaming
            )))
            reasoningBuffer = ""
        }

        while index < source.endIndex {
            let remainder = source[index...]

            switch mode {
            case .text:
                if remainder.hasPrefix(openingTag) {
                    appendTextPart()
                    index = source.index(index, offsetBy: openingTag.count)
                    mode = .reasoning
                } else if remainder.first == "<", openingTag.hasPrefix(remainder), !isFinal {
                    break
                } else {
                    textBuffer.append(source[index])
                    index = source.index(after: index)
                }
            case .reasoning:
                if remainder.hasPrefix(closingTag) {
                    appendReasoningPart(isClosed: true)
                    index = source.index(index, offsetBy: closingTag.count)
                    mode = .text
                } else if remainder.first == "<", closingTag.hasPrefix(remainder), !isFinal {
                    break
                } else {
                    reasoningBuffer.append(source[index])
                    index = source.index(after: index)
                }
            }
        }

        switch mode {
        case .text:
            appendTextPart()
        case .reasoning:
            appendReasoningPart(isClosed: false)
        }

        return parts
    }
}
