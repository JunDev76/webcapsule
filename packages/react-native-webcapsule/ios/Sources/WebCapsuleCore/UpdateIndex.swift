import Foundation

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let url: URL
    let sha256: String
    let size: Int64
    let minimumRuntimeVersion: String
}

struct VerifiedUpdateIndex: Equatable, Sendable {
    let capsuleId: String
    let channel: String
    let keyId: String
    let releases: [UpdateRelease]
}

enum UpdateIndexVerifier {
    private static let capsuleLimit: Int64 = 100 * 1024 * 1024
    private static let indexLimit = 1024 * 1024
    private static let rootFields: Set<String> = [
        "schemaVersion", "capsuleId", "channel", "releases", "keyId", "signature",
    ]
    private static let releaseFields: Set<String> = [
        "version", "url", "sha256", "size", "minimumRuntimeVersion",
    ]

    static func verify(
        _ data: Data,
        expectedCapsuleId: String,
        expectedChannel: String,
        publicKeys: [String: String]
    ) throws -> VerifiedUpdateIndex {
        guard !data.isEmpty, data.count <= indexLimit else {
            throw WebCapsuleError(code: .limitExceeded, message: "Update index size is invalid")
        }
        let parsed = try StrictJSON.parse(data)
        guard case let .object(root) = parsed else { throw invalid("Update index must be an object") }
        try exact(root, fields: rootFields, label: "Update index")
        guard case let .integer(schemaVersion) = try required(root, "schemaVersion"), schemaVersion == 1,
              case let .string(capsuleId) = try required(root, "capsuleId"),
              case let .string(channel) = try required(root, "channel"),
              case let .array(releaseValues) = try required(root, "releases"),
              case let .string(keyId) = try required(root, "keyId"),
              case let .string(encodedSignature) = try required(root, "signature") else {
            throw invalid("Update index field type or schema is invalid")
        }
        do { try CapsuleManifestParser.validateCapsuleID(capsuleId) }
        catch { throw WebCapsuleError(code: .invalidCapsuleID, message: "Invalid capsule ID") }
        guard validChannel(channel) else { throw invalid("Invalid channel") }
        do { try CapsuleManifestParser.validateKeyID(keyId) }
        catch { throw WebCapsuleError(code: .invalidKeyID, message: "Invalid key ID") }
        guard capsuleId == expectedCapsuleId, channel == expectedChannel else {
            throw invalid("Update index identity differs")
        }
        guard !releaseValues.isEmpty else { throw invalid("At least one release is required") }
        let releases = try releaseValues.map(parseRelease)
        for pair in zip(releases, releases.dropFirst()) {
            guard try SemanticVersion.compare(pair.0.version, pair.1.version) == .orderedDescending else {
                throw WebCapsuleError(
                    code: .invalidOrder,
                    message: "Releases must have unique descending SemVer precedence"
                )
            }
        }
        let signature = try parseSignature(encodedSignature)
        let unsigned = StrictJSONValue.object(StrictJSONObject(
            entries: root.entries.filter { $0.key != "signature" }
        ))
        try SignedManifestVerifier.verifyUpdateIndex(
            canonicalIndex: CanonicalJSON.serialize(unsigned),
            signature: signature,
            keyId: keyId,
            publicKeys: publicKeys
        )
        return VerifiedUpdateIndex(
            capsuleId: capsuleId,
            channel: channel,
            keyId: keyId,
            releases: releases
        )
    }

    static func select(
        _ index: VerifiedUpdateIndex,
        runtimeVersion: String,
        highestSeenVersion: String,
        blockedVersions: Set<String>
    ) throws -> UpdateRelease? {
        try SemanticVersion.validate(runtimeVersion)
        try SemanticVersion.validate(highestSeenVersion)
        for release in index.releases where
            try SemanticVersion.compare(release.minimumRuntimeVersion, runtimeVersion) != .orderedDescending
                && SemanticVersion.compare(release.version, highestSeenVersion) == .orderedDescending
                && !blockedVersions.contains(release.version) {
            return release
        }
        return nil
    }

    static func strictHTTPS(_ value: String) throws -> URL {
        guard !value.isEmpty,
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host != nil,
              !components.host!.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.port == nil,
              !hasExplicitPort(value),
              let url = components.url,
              url.baseURL == nil else {
            throw WebCapsuleError(
                code: .invalidURL,
                message: "URL must be absolute HTTPS without userinfo, fragment, or explicit port"
            )
        }
        return url
    }

    private static func hasExplicitPort(_ value: String) -> Bool {
        guard let authorityStart = value.range(of: "://")?.upperBound else { return false }
        let remainder = value[authorityStart...]
        let authority = remainder.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else { return true }
            return authority.index(after: closing) != authority.endIndex
        }
        return authority.contains(":")
    }

    static func validateChannel(_ value: String) throws {
        guard validChannel(value) else { throw invalid("Invalid channel") }
    }

    private static func parseRelease(_ value: StrictJSONValue) throws -> UpdateRelease {
        guard case let .object(object) = value else { throw invalid("Release must be an object") }
        try exact(object, fields: releaseFields, label: "Release")
        guard case let .string(version) = try required(object, "version"),
              case let .string(urlString) = try required(object, "url"),
              case let .string(sha256) = try required(object, "sha256"),
              case let .integer(size) = try required(object, "size"),
              case let .string(minimumRuntimeVersion) = try required(object, "minimumRuntimeVersion") else {
            throw invalid("Release field type is invalid")
        }
        try SemanticVersion.validate(version)
        try SemanticVersion.validate(minimumRuntimeVersion)
        guard VersionRecordCodec.isLowercaseSHA256(sha256) else {
            throw WebCapsuleError(code: .invalidHash, message: "Invalid release SHA-256")
        }
        guard size >= 0 else { throw invalid("Release size must be non-negative") }
        guard size <= capsuleLimit else {
            throw WebCapsuleError(code: .limitExceeded, message: "Release size exceeds capsule limit")
        }
        return UpdateRelease(
            version: version,
            url: try strictHTTPS(urlString),
            sha256: sha256,
            size: size,
            minimumRuntimeVersion: minimumRuntimeVersion
        )
    }

    private static func parseSignature(_ value: String) throws -> Data {
        let bytes = Array(value.utf8)
        guard bytes.count == 88,
              bytes.suffix(2).elementsEqual([0x3D, 0x3D]),
              bytes.dropLast(2).allSatisfy(isBase64Character),
              let signature = Data(base64Encoded: value, options: []),
              signature.count == 64,
              signature.base64EncodedString() == value else {
            throw WebCapsuleError(code: .invalidSignature, message: "Invalid update index signature encoding")
        }
        return signature
    }

    private static func exact(_ object: StrictJSONObject, fields: Set<String>, label: String) throws {
        guard object.entries.count == fields.count, Set(object.entries.map(\.key)) == fields else {
            throw invalid("\(label) fields differ")
        }
    }

    private static func required(_ object: StrictJSONObject, _ key: String) throws -> StrictJSONValue {
        guard let value = object[key] else { throw invalid("Update index field is missing") }
        return value
    }

    private static func validChannel(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first, isLowerAlphaNumeric(first) else {
            return false
        }
        return bytes.allSatisfy { isLowerAlphaNumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    private static func isLowerAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
    }

    private static func isBase64Character(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte) || byte == 0x2B || byte == 0x2F
    }

    private static func invalid(_ message: String) -> WebCapsuleError {
        WebCapsuleError(code: .invalidUpdateIndex, message: message)
    }
}
