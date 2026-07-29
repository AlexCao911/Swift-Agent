import Foundation

enum OpenMinisToolArgumentRepair {
    static func repair(
        rawJSON: String,
        definition: OpenMinisToolDefinitionSnapshot
    ) -> [String: Any]? {
        var object = parseObject(rawJSON)
        if object == nil {
            for suffix in ["\"", "\"}", "\"]}", "}", "}}", "]}", "]}}", "]", "]]"] {
                if let repaired = parseObject(rawJSON + suffix) {
                    object = repaired
                    break
                }
            }
        }
        guard var object else { return nil }

        for field in definition.requiredFields {
            guard let raw = object[field] else { continue }
            if raw is String { continue }
            if raw is NSNull {
                object.removeValue(forKey: field)
            } else if raw is [Any] || raw is [String: Any] {
                continue
            } else if let number = raw as? NSNumber {
                object[field] = CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? (number.boolValue ? "true" : "false")
                    : number.stringValue
            } else {
                object[field] = String(describing: raw)
            }
        }

        let schemaFields = definition.inputSchema
            .objectValue(forKey: "properties")?
            .objectKeys ?? []
        for field in definition.requiredFields where object[field] == nil {
            guard let candidate = object.keys.sorted().first(where: {
                !schemaFields.contains($0) && levenshteinAtMostOne($0, field)
            }) else {
                continue
            }
            object[field] = object.removeValue(forKey: candidate)
        }
        return object
    }

    static func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
              ) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func levenshteinAtMostOne(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.lowercased())
        let right = Array(rhs.lowercased())
        if left == right { return true }
        guard abs(left.count - right.count) <= 1 else { return false }
        if left.count == right.count {
            return zip(left, right).filter { $0.0 != $0.1 }.count == 1
        }

        let (longer, shorter) = left.count > right.count
            ? (left, right)
            : (right, left)
        var longIndex = 0
        var shortIndex = 0
        var skipped = false
        while longIndex < longer.count, shortIndex < shorter.count {
            if longer[longIndex] == shorter[shortIndex] {
                longIndex += 1
                shortIndex += 1
            } else if skipped == false {
                longIndex += 1
                skipped = true
            } else {
                return false
            }
        }
        return true
    }
}
