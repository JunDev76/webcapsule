import Foundation

enum CanonicalJSON {
    static func serialize(_ value: StrictJSONValue) -> Data {
        var result = String()
        append(value, to: &result)
        return Data(result.utf8)
    }

    private static func append(_ value: StrictJSONValue, to result: inout String) {
        switch value {
        case let .object(object):
            result.append("{")
            let entries = object.entries.sorted { utf16Precedes($0.key, $1.key) }
            for (index, entry) in entries.enumerated() {
                if index > 0 { result.append(",") }
                appendString(entry.key, to: &result)
                result.append(":")
                append(entry.value, to: &result)
            }
            result.append("}")
        case let .array(values):
            result.append("[")
            for (index, item) in values.enumerated() {
                if index > 0 { result.append(",") }
                append(item, to: &result)
            }
            result.append("]")
        case let .string(string):
            appendString(string, to: &result)
        case let .integer(integer):
            result.append(String(integer))
        case let .bool(boolean):
            result.append(boolean ? "true" : "false")
        case .null:
            result.append("null")
        }
    }

    private static func appendString(_ value: String, to result: inout String) {
        result.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result.append("\\b")
            case 0x09: result.append("\\t")
            case 0x0A: result.append("\\n")
            case 0x0C: result.append("\\f")
            case 0x0D: result.append("\\r")
            case 0x22: result.append("\\\"")
            case 0x5C: result.append("\\\\")
            case 0x00...0x1F:
                let digits = Array("0123456789abcdef".utf8)
                let value = Int(scalar.value)
                result.append("\\u00")
                result.append(Character(UnicodeScalar(digits[(value >> 4) & 0xF])))
                result.append(Character(UnicodeScalar(digits[value & 0xF])))
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result.append("\"")
    }

    private static func utf16Precedes(_ lhs: String, _ rhs: String) -> Bool {
        Array(lhs.utf16).lexicographicallyPrecedes(Array(rhs.utf16))
    }
}
