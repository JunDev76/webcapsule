import Foundation

public enum WebCapsuleConfigValidator {
    private static let capsuleIdPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9]+(?:[.-][a-z0-9]+)+$"
    )
    private static let keyIdPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
    )
    private static let semverPattern = try! NSRegularExpression(
        pattern: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\\+([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?$"
    )

    public static func validate(_ config: WebCapsuleConfig) throws {
        guard config.capsuleId.utf8.count <= 255,
              matches(capsuleIdPattern, config.capsuleId) else {
            throw WebCapsuleError(code: .invalidCapsuleID, message: "Invalid capsule ID")
        }
        try validateBundledAssetPath(config.bundledAssetPath)
        guard !config.publicKeys.isEmpty else {
            throw WebCapsuleError(code: .invalidArgument, message: "publicKeys must not be empty")
        }
        for (keyId, pem) in config.publicKeys {
            guard matches(keyIdPattern, keyId) else {
                throw WebCapsuleError(code: .invalidKeyID, message: "Invalid key ID")
            }
            guard !pem.isEmpty else {
                throw WebCapsuleError(code: .invalidPublicKey, message: "Public key must not be empty")
            }
        }
        guard matches(semverPattern, config.runtimeVersion) else {
            throw WebCapsuleError(code: .invalidVersion, message: "Invalid runtime version")
        }
    }

    private static func validateBundledAssetPath(_ path: String) throws {
        let invalid = path.isEmpty
            || path.hasPrefix("/")
            || path.hasSuffix("/")
            || path.contains("\\")
            || path.contains("\0")
            || !path.precomposedStringWithCanonicalMapping.utf8.elementsEqual(path.utf8)
            || path.contains("://")
            || path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
            || !path.hasSuffix(".capsule")
        guard !invalid else {
            throw WebCapsuleError(code: .invalidPath, message: "bundledAssetPath must be a bundle-relative POSIX capsule path")
        }
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }
}
