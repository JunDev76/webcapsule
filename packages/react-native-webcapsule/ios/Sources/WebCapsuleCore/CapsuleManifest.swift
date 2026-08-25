import Foundation

public struct CapsuleFileEntry: Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let size: Int64
    public let mediaType: String

    public init(path: String, sha256: String, size: Int64, mediaType: String) {
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.mediaType = mediaType
    }
}

public struct CapsuleNetworkPolicy: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        case deny
        case allowlist
    }

    public let mode: Mode
    public let origins: [String]?

    public init(mode: Mode, origins: [String]? = nil) {
        self.mode = mode
        self.origins = origins
    }
}

public struct CapsuleNavigationPolicy: Equatable, Sendable {
    public let externalOrigins: [String]

    public init(externalOrigins: [String]) {
        self.externalOrigins = externalOrigins
    }
}

public struct CapsulePolicy: Equatable, Sendable {
    public let network: CapsuleNetworkPolicy
    public let navigation: CapsuleNavigationPolicy
    public let bridgeCapabilities: [String]

    public init(
        network: CapsuleNetworkPolicy,
        navigation: CapsuleNavigationPolicy,
        bridgeCapabilities: [String]
    ) {
        self.network = network
        self.navigation = navigation
        self.bridgeCapabilities = bridgeCapabilities
    }
}

public struct CapsuleManifest: Equatable, Sendable {
    public let formatVersion: Int
    public let capsuleId: String
    public let version: String
    public let entry: String
    public let createdAt: String
    public let minimumRuntimeVersion: String
    public let keyId: String
    public let files: [CapsuleFileEntry]
    public let policy: CapsulePolicy

    public init(
        formatVersion: Int,
        capsuleId: String,
        version: String,
        entry: String,
        createdAt: String,
        minimumRuntimeVersion: String,
        keyId: String,
        files: [CapsuleFileEntry],
        policy: CapsulePolicy
    ) {
        self.formatVersion = formatVersion
        self.capsuleId = capsuleId
        self.version = version
        self.entry = entry
        self.createdAt = createdAt
        self.minimumRuntimeVersion = minimumRuntimeVersion
        self.keyId = keyId
        self.files = files
        self.policy = policy
    }
}
