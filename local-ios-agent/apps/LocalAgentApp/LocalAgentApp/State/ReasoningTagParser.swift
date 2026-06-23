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

        parseLoop: while index < source.endIndex {
            switch mode {
            case .text:
                if hasTag(openingTag, in: source, at: index) {
                    appendTextPart()
                    advance(&index, in: source, by: openingTag.count)
                    mode = .reasoning
                } else if isPartialTagPrefix(openingTag, in: source, at: index, isFinal: isFinal) {
                    break parseLoop
                } else {
                    textBuffer.append(source[index])
                    index = source.index(after: index)
                }
            case .reasoning:
                if hasTag(closingTag, in: source, at: index) {
                    appendReasoningPart(isClosed: true)
                    advance(&index, in: source, by: closingTag.count)
                    mode = .text
                } else if isPartialTagPrefix(closingTag, in: source, at: index, isFinal: isFinal) {
                    break parseLoop
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

    private func hasTag(_ tag: String, in source: String, at index: String.Index) -> Bool {
        var sourceIndex = index
        for tagCharacter in tag {
            guard sourceIndex < source.endIndex, source[sourceIndex] == tagCharacter else {
                return false
            }
            sourceIndex = source.index(after: sourceIndex)
        }
        return true
    }

    private func isPartialTagPrefix(
        _ tag: String,
        in source: String,
        at index: String.Index,
        isFinal: Bool
    ) -> Bool {
        guard !isFinal, index < source.endIndex, source[index] == "<" else {
            return false
        }

        var sourceIndex = index
        var matchedCount = 0
        for tagCharacter in tag {
            guard sourceIndex < source.endIndex else {
                return matchedCount > 0 && matchedCount < tag.count
            }

            guard source[sourceIndex] == tagCharacter else {
                return false
            }

            matchedCount += 1
            sourceIndex = source.index(after: sourceIndex)
        }

        guard sourceIndex == source.endIndex else {
            return false
        }

        return matchedCount < tag.count
    }

    private func advance(_ index: inout String.Index, in source: String, by count: Int) {
        for _ in 0..<count where index < source.endIndex {
            index = source.index(after: index)
        }
    }
}
