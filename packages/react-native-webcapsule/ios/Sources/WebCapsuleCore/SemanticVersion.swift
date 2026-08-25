import Foundation

enum SemanticVersion {
    static func validate(_ value: String) throws {
        _ = try parse(value)
    }

    static func compare(_ lhs: String, _ rhs: String) throws -> ComparisonResult {
        let left = try parse(lhs)
        let right = try parse(rhs)

        for index in 0..<3 {
            let comparison = compareNumeric(left.core[index], right.core[index])
            if comparison != .orderedSame {
                return comparison
            }
        }

        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending
        case (_, nil):
            return .orderedAscending
        case let (.some(leftIdentifiers), .some(rightIdentifiers)):
            for index in 0..<min(leftIdentifiers.count, rightIdentifiers.count) {
                let leftIdentifier = leftIdentifiers[index]
                let rightIdentifier = rightIdentifiers[index]
                let leftNumeric = leftIdentifier.allSatisfy(\.isNumber)
                let rightNumeric = rightIdentifier.allSatisfy(\.isNumber)
                let comparison: ComparisonResult
                if leftNumeric && rightNumeric {
                    comparison = compareNumeric(leftIdentifier, rightIdentifier)
                } else if leftNumeric {
                    comparison = .orderedAscending
                } else if rightNumeric {
                    comparison = .orderedDescending
                } else {
                    comparison = compareASCII(leftIdentifier, rightIdentifier)
                }
                if comparison != .orderedSame {
                    return comparison
                }
            }
            if leftIdentifiers.count == rightIdentifiers.count {
                return .orderedSame
            }
            return leftIdentifiers.count < rightIdentifiers.count ? .orderedAscending : .orderedDescending
        }
    }

    private struct ParsedVersion {
        let core: [String]
        let prerelease: [String]?
    }

    private static func parse(_ value: String) throws -> ParsedVersion {
        let plusParts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard plusParts.count <= 2 else { throw invalidVersion() }
        if plusParts.count == 2 {
            try validateIdentifiers(String(plusParts[1]), numericLeadingZerosAllowed: true)
        }

        let precedence = String(plusParts[0])
        let dashParts = precedence.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = dashParts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard core.count == 3 else { throw invalidVersion() }
        for identifier in core {
            guard isASCIIInteger(identifier), identifier == "0" || !identifier.hasPrefix("0") else {
                throw invalidVersion()
            }
        }

        let prerelease: [String]?
        if dashParts.count == 2 {
            let text = String(dashParts[1])
            try validateIdentifiers(text, numericLeadingZerosAllowed: false)
            prerelease = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        } else {
            prerelease = nil
        }
        return ParsedVersion(core: core, prerelease: prerelease)
    }

    private static func validateIdentifiers(_ value: String, numericLeadingZerosAllowed: Bool) throws {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !identifiers.isEmpty else { throw invalidVersion() }
        for identifier in identifiers {
            guard !identifier.isEmpty,
                  identifier.utf8.allSatisfy({ isASCIIAlphaNumeric($0) || $0 == 0x2D }) else {
                throw invalidVersion()
            }
            if !numericLeadingZerosAllowed,
               isASCIIInteger(identifier),
               identifier.count > 1,
               identifier.hasPrefix("0") {
                throw invalidVersion()
            }
        }
    }

    private static func isASCIIInteger(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }

    private static func isASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    private static func compareNumeric(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        return compareASCII(lhs, rhs)
    }

    private static func compareASCII(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        if left == right { return .orderedSame }
        return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
    }

    private static func invalidVersion() -> WebCapsuleError {
        WebCapsuleError(code: .invalidVersion, message: "Invalid SemVer version")
    }
}
