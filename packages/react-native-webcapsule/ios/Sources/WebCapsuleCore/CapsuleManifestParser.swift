import Foundation

public enum CapsuleManifestParser {
    private static let maximumFileSize: Int64 = 50 * 1024 * 1024
    private static let maximumExpandedSize: Int64 = 250 * 1024 * 1024

    public static func parse(_ data: Data) throws -> CapsuleManifest {
        let root = try StrictJSON.parse(data).object("manifest")
        try root.requireExactly([
            "formatVersion", "capsuleId", "version", "entry", "createdAt",
            "minimumRuntimeVersion", "keyId", "files", "policy",
        ], label: "manifest")

        let formatVersion = try root.required("formatVersion").int("formatVersion")
        guard formatVersion == 1 else {
            throw WebCapsuleError(code: .unsupportedFormatVersion, message: "Unsupported manifest formatVersion")
        }
        let capsuleId = try root.required("capsuleId").string("capsuleId")
        try validateCapsuleID(capsuleId)
        let version = try root.required("version").string("version")
        try SemanticVersion.validate(version)
        let entry = try root.required("entry").string("entry")
        try CapsulePathValidator.validate(entry)
        let createdAt = try root.required("createdAt").string("createdAt")
        try validateTimestamp(createdAt)
        let minimumRuntimeVersion = try root.required("minimumRuntimeVersion").string("minimumRuntimeVersion")
        try SemanticVersion.validate(minimumRuntimeVersion)
        let keyId = try root.required("keyId").string("keyId")
        try validateKeyID(keyId)

        let fileValues = try root.required("files").array("files")
        guard fileValues.count <= CapsulePathValidator.maximumFileCount else {
            throw WebCapsuleError(code: .limitExceeded, message: "File count limit exceeded")
        }
        var files: [CapsuleFileEntry] = []
        files.reserveCapacity(fileValues.count)
        var totalSize: Int64 = 0
        for value in fileValues {
            let file = try parseFile(value)
            let (sum, overflow) = totalSize.addingReportingOverflow(file.size)
            guard !overflow, sum <= maximumExpandedSize else {
                throw WebCapsuleError(code: .limitExceeded, message: "Expanded content limit exceeded")
            }
            totalSize = sum
            files.append(file)
        }
        let paths = files.map(\.path)
        try CapsulePathValidator.validateSet(paths)
        try CapsulePathValidator.validateAscendingUTF8Order(paths)
        guard paths.contains(entry) else {
            throw WebCapsuleError(code: .invalidManifest, message: "entry must reference a manifest file")
        }

        return CapsuleManifest(
            formatVersion: Int(formatVersion),
            capsuleId: capsuleId,
            version: version,
            entry: entry,
            createdAt: createdAt,
            minimumRuntimeVersion: minimumRuntimeVersion,
            keyId: keyId,
            files: files,
            policy: try parsePolicy(root.required("policy"))
        )
    }

    private static func parseFile(_ value: StrictJSONValue) throws -> CapsuleFileEntry {
        let file = try value.object("file entry")
        try file.requireExactly(["path", "sha256", "size", "mediaType"], label: "file entry")
        let path = try file.required("path").string("file.path")
        try CapsulePathValidator.validate(path)
        let sha256 = try file.required("sha256").string("file.sha256")
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw WebCapsuleError(code: .invalidHash, message: "SHA-256 must be lowercase hexadecimal")
        }
        let size = try file.required("size").int("file.size")
        guard size >= 0, size <= maximumFileSize else {
            throw WebCapsuleError(code: .limitExceeded, message: "Invalid file size")
        }
        let mediaType = try file.required("mediaType").string("file.mediaType")
        try validateMediaType(mediaType)
        return CapsuleFileEntry(path: path, sha256: sha256, size: size, mediaType: mediaType)
    }

    private static func parsePolicy(_ value: StrictJSONValue) throws -> CapsulePolicy {
        let policy = try value.object("policy")
        try policy.requireExactly(["network", "navigation", "bridgeCapabilities"], label: "policy")

        guard case let .object(network) = try policy.required("network") else {
            throw WebCapsuleError(code: .invalidPolicy, message: "policy.network must be an object")
        }
        let mode = try network.required("mode").string("policy.network.mode")
        let networkPolicy: CapsuleNetworkPolicy
        switch mode {
        case "deny":
            try network.requireExactly(["mode"], label: "policy.network")
            networkPolicy = CapsuleNetworkPolicy(mode: .deny)
        case "allowlist":
            try network.requireExactly(["mode", "origins"], label: "policy.network")
            let origins = try parseStringArray(
                network.required("origins"),
                label: "policy.network.origins",
                validator: validateHTTPSOrigin
            )
            networkPolicy = CapsuleNetworkPolicy(mode: .allowlist, origins: origins)
        default:
            throw WebCapsuleError(code: .invalidPolicy, message: "Unknown network policy mode")
        }

        let navigation = try policy.required("navigation").object("policy.navigation")
        try navigation.requireExactly(["externalOrigins"], label: "policy.navigation")
        let externalOrigins = try parseStringArray(
            navigation.required("externalOrigins"),
            label: "policy.navigation.externalOrigins",
            validator: validateHTTPSOrigin
        )
        let bridgeCapabilities = try parseStringArray(
            policy.required("bridgeCapabilities"),
            label: "policy.bridgeCapabilities",
            validator: validateCapability
        )
        return CapsulePolicy(
            network: networkPolicy,
            navigation: CapsuleNavigationPolicy(externalOrigins: externalOrigins),
            bridgeCapabilities: bridgeCapabilities
        )
    }

    private static func parseStringArray(
        _ value: StrictJSONValue,
        label: String,
        validator: (String) throws -> Void
    ) throws -> [String] {
        let values = try value.array(label)
        var result: [String] = []
        var seen = Set<Data>()
        for value in values {
            let item = try value.string(label)
            try validator(item)
            guard seen.insert(Data(item.utf8)).inserted else {
                throw WebCapsuleError(code: .invalidPolicy, message: "\(label) contains a duplicate value")
            }
            result.append(item)
        }
        return result
    }

    private static func validateCapsuleID(_ value: String) throws {
        let bytes = Array(value.utf8)
        var hasSeparator = false
        var segmentLength = 0
        for byte in bytes {
            if byte == 0x2E || byte == 0x2D {
                guard segmentLength > 0 else { throw invalidCapsuleID() }
                hasSeparator = true
                segmentLength = 0
            } else if (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) {
                segmentLength += 1
            } else {
                throw invalidCapsuleID()
            }
        }
        guard bytes.count <= 255, hasSeparator, segmentLength > 0 else {
            throw invalidCapsuleID()
        }
    }

    private static func validateKeyID(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), isASCIIAlphaNumeric(bytes[0]), bytes.dropFirst().allSatisfy({
            isASCIIAlphaNumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }) else {
            throw WebCapsuleError(code: .invalidKeyID, message: "Invalid key ID")
        }
    }

    private static func validateTimestamp(_ value: String) throws {
        let bytes = Array(value.utf8)
        let separators: [Int: UInt8] = [4: 0x2D, 7: 0x2D, 10: 0x54, 13: 0x3A, 16: 0x3A, 19: 0x5A]
        guard bytes.count == 20,
              separators.allSatisfy({ bytes[$0.key] == $0.value }),
              bytes.enumerated().allSatisfy({ separators[$0.offset] != nil || (0x30...0x39).contains($0.element) }) else {
            throw invalidTimestamp()
        }
        func number(_ start: Int, _ length: Int) -> Int {
            bytes[start..<(start + length)].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        }
        let year = number(0, 4)
        let month = number(5, 2)
        let day = number(8, 2)
        let hour = number(11, 2)
        let minute = number(14, 2)
        let second = number(17, 2)
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month),
              (1...days[month - 1]).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second),
              second.isMultiple(of: 2) else {
            throw invalidTimestamp()
        }
    }

    private static func validateMediaType(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowedPunctuation = Set("!#$&^_.+-".utf8)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { isASCIIAlphaNumeric($0) || allowedPunctuation.contains($0) }
        }) else {
            throw WebCapsuleError(code: .invalidMediaType, message: "Invalid media type")
        }
    }

    private static func validateHTTPSOrigin(_ value: String) throws {
        guard !value.hasSuffix("/"),
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            throw WebCapsuleError(code: .invalidURL, message: "Invalid HTTPS origin")
        }
        guard let urlHost = URL(string: value)?.host else {
            throw WebCapsuleError(code: .invalidURL, message: "Invalid HTTPS origin")
        }
        let canonicalHost = urlHost.contains(":") ? "[\(urlHost.lowercased())]" : urlHost.lowercased()
        guard value == "https://\(canonicalHost)" else {
            throw WebCapsuleError(code: .invalidURL, message: "Invalid HTTPS origin")
        }
    }

    private static func validateCapability(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), isASCIIAlphaNumeric(bytes[0]), bytes.dropFirst().allSatisfy({
            isASCIIAlphaNumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x3A || $0 == 0x2D
        }) else {
            throw WebCapsuleError(code: .invalidPolicy, message: "Invalid bridge capability")
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func invalidCapsuleID() -> WebCapsuleError {
        WebCapsuleError(code: .invalidCapsuleID, message: "Invalid capsule ID")
    }

    private static func invalidTimestamp() -> WebCapsuleError {
        WebCapsuleError(code: .invalidTimestamp, message: "Invalid build timestamp")
    }
}

private extension StrictJSONValue {
    func object(_ label: String) throws -> StrictJSONObject {
        guard case let .object(value) = self else {
            throw WebCapsuleError(code: .invalidJSONValue, message: "\(label) must be an object")
        }
        return value
    }

    func array(_ label: String) throws -> [StrictJSONValue] {
        guard case let .array(value) = self else {
            throw WebCapsuleError(code: .invalidJSONValue, message: "\(label) must be an array")
        }
        return value
    }

    func string(_ label: String) throws -> String {
        guard case let .string(value) = self else {
            throw WebCapsuleError(code: .invalidJSONValue, message: "\(label) must be a string")
        }
        return value
    }

    func int(_ label: String) throws -> Int64 {
        guard case let .integer(value) = self else {
            throw WebCapsuleError(code: .invalidJSONValue, message: "\(label) must be an integer")
        }
        return value
    }
}

private extension StrictJSONObject {
    func requireExactly(_ expected: Set<String>, label: String) throws {
        guard entries.count == expected.count, entries.allSatisfy({ expected.contains($0.key) }) else {
            throw WebCapsuleError(code: .invalidJSONValue, message: "\(label) has missing or extra properties")
        }
    }

    func required(_ key: String) throws -> StrictJSONValue {
        guard let value = self[key] else {
            throw WebCapsuleError(code: .invalidJSONValue, message: "Missing required property: \(key)")
        }
        return value
    }
}
