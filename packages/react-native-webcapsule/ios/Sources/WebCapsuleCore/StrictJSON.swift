import Foundation

indirect enum StrictJSONValue: Sendable {
    case object(StrictJSONObject)
    case array([StrictJSONValue])
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null
}

struct StrictJSONObject: Sendable {
    let entries: [(key: String, value: StrictJSONValue)]

    subscript(_ key: String) -> StrictJSONValue? {
        entries.first { $0.key == key }?.value
    }
}

enum StrictJSON {
    static func parse(_ data: Data) throws -> StrictJSONValue {
        guard let text = String(data: data, encoding: .utf8) else {
            throw WebCapsuleError(code: .invalidJSONValue, message: "JSON is not valid UTF-8")
        }
        var parser = Parser(text)
        return try parser.parse()
    }
}

private struct Parser {
    private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    private let scalars: [Unicode.Scalar]
    private var position = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    mutating func parse() throws -> StrictJSONValue {
        skipWhitespace()
        guard position < scalars.count else {
            throw invalid("JSON input is empty")
        }
        let value = try parseValue()
        skipWhitespace()
        guard position == scalars.count else {
            throw invalid("JSON contains trailing input")
        }
        return value
    }

    private mutating func parseValue() throws -> StrictJSONValue {
        guard let scalar = current else {
            throw invalid("Unexpected end of JSON input")
        }
        switch scalar.value {
        case 0x7B:
            return try parseObject()
        case 0x5B:
            return try parseArray()
        case 0x22:
            return .string(try parseString())
        case 0x74:
            try consumeLiteral("true")
            return .bool(true)
        case 0x66:
            try consumeLiteral("false")
            return .bool(false)
        case 0x6E:
            try consumeLiteral("null")
            return .null
        case 0x2D, 0x30...0x39:
            return .integer(try parseInteger())
        default:
            throw invalid("Unexpected JSON token")
        }
    }

    private mutating func parseObject() throws -> StrictJSONValue {
        try consume(0x7B)
        skipWhitespace()
        var entries: [(key: String, value: StrictJSONValue)] = []
        var keys = Set<Data>()
        if take(0x7D) {
            return .object(StrictJSONObject(entries: entries))
        }
        while true {
            guard current?.value == 0x22 else {
                throw invalid("JSON object key must be a string")
            }
            let key = try parseString()
            guard keys.insert(Data(key.utf8)).inserted else {
                throw WebCapsuleError(code: .duplicateJSONKey, message: "Duplicate JSON object key")
            }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            entries.append((key, try parseValue()))
            skipWhitespace()
            if take(0x7D) {
                return .object(StrictJSONObject(entries: entries))
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws -> StrictJSONValue {
        try consume(0x5B)
        skipWhitespace()
        var values: [StrictJSONValue] = []
        if take(0x5D) {
            return .array(values)
        }
        while true {
            values.append(try parseValue())
            skipWhitespace()
            if take(0x5D) {
                return .array(values)
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        try consume(0x22)
        var result = String()
        while let scalar = current {
            position += 1
            if scalar.value == 0x22 {
                return result
            }
            if scalar.value == 0x5C {
                guard let escape = current else {
                    throw invalid("Unterminated JSON escape")
                }
                position += 1
                switch escape.value {
                case 0x22: result.append("\"")
                case 0x5C: result.append("\\")
                case 0x2F: result.append("/")
                case 0x62: result.append("\u{08}")
                case 0x66: result.append("\u{0C}")
                case 0x6E: result.append("\n")
                case 0x72: result.append("\r")
                case 0x74: result.append("\t")
                case 0x75:
                    let first = try parseHexQuad()
                    let codePoint: UInt32
                    if (0xD800...0xDBFF).contains(first) {
                        try consume(0x5C)
                        try consume(0x75)
                        let second = try parseHexQuad()
                        guard (0xDC00...0xDFFF).contains(second) else {
                            throw invalid("Invalid JSON surrogate pair")
                        }
                        codePoint = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    } else {
                        guard !(0xDC00...0xDFFF).contains(first) else {
                            throw invalid("Unpaired JSON low surrogate")
                        }
                        codePoint = first
                    }
                    guard let decoded = Unicode.Scalar(codePoint) else {
                        throw invalid("Invalid JSON Unicode scalar")
                    }
                    result.unicodeScalars.append(decoded)
                default:
                    throw invalid("Invalid JSON escape")
                }
            } else {
                guard scalar.value > 0x1F else {
                    throw invalid("Unescaped control character in JSON string")
                }
                result.unicodeScalars.append(scalar)
            }
        }
        throw invalid("Unterminated JSON string")
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let scalar = current, let digit = hexValue(scalar.value) else {
                throw invalid("Invalid JSON Unicode escape")
            }
            position += 1
            value = value * 16 + digit
        }
        return value
    }

    private mutating func parseInteger() throws -> Int64 {
        let start = position
        _ = take(0x2D)
        guard let scalar = current else {
            throw invalid("Incomplete JSON number")
        }
        if scalar.value == 0x30 {
            position += 1
            if let next = current, (0x30...0x39).contains(next.value) {
                throw invalid("JSON number has a leading zero")
            }
        } else if (0x31...0x39).contains(scalar.value) {
            repeat {
                position += 1
            } while current.map { (0x30...0x39).contains($0.value) } == true
        } else {
            throw invalid("Invalid JSON number")
        }
        if let next = current, next.value == 0x2E || next.value == 0x65 || next.value == 0x45 {
            throw invalid("Manifest numbers must be integers")
        }
        let text = String(String.UnicodeScalarView(scalars[start..<position]))
        guard let value = Int64(text),
              value >= -Self.maximumSafeInteger,
              value <= Self.maximumSafeInteger else {
            throw invalid("Integer is outside the I-JSON safe range")
        }
        return value
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for scalar in literal.unicodeScalars {
            try consume(scalar.value)
        }
    }

    private mutating func consume(_ expected: UInt32) throws {
        guard current?.value == expected else {
            throw invalid("Unexpected JSON token")
        }
        position += 1
    }

    private mutating func take(_ expected: UInt32) -> Bool {
        guard current?.value == expected else {
            return false
        }
        position += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let value = current?.value, value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D {
            position += 1
        }
    }

    private var current: Unicode.Scalar? {
        position < scalars.count ? scalars[position] : nil
    }

    private func hexValue(_ value: UInt32) -> UInt32? {
        switch value {
        case 0x30...0x39: return value - 0x30
        case 0x41...0x46: return value - 0x41 + 10
        case 0x61...0x66: return value - 0x61 + 10
        default: return nil
        }
    }

    private func invalid(_ message: String) -> WebCapsuleError {
        WebCapsuleError(code: .invalidJSONValue, message: message)
    }
}
