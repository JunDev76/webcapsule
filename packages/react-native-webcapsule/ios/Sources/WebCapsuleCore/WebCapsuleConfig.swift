import Foundation

public struct WebCapsuleConfig: Equatable, Sendable {
    public let capsuleId: String
    public let bundledAssetPath: String
    public let publicKeys: [String: String]
    public let runtimeVersion: String

    public init(
        capsuleId: String,
        bundledAssetPath: String,
        publicKeys: [String: String],
        runtimeVersion: String
    ) {
        self.capsuleId = capsuleId
        self.bundledAssetPath = bundledAssetPath
        self.publicKeys = publicKeys
        self.runtimeVersion = runtimeVersion
    }
}
