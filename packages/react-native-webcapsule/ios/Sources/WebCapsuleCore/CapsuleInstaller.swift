import Foundation

public struct CapsuleInstallResult: Equatable, Sendable {
    public let record: VersionRecord
    public let installed: Bool
    public let publishedBlobCount: Int

    init(record: VersionRecord, installed: Bool, publishedBlobCount: Int) {
        self.record = record
        self.installed = installed
        self.publishedBlobCount = publishedBlobCount
    }
}

/// Publishes verified Capsule content into immutable local storage.
///
/// The caller must provide an existing, dedicated, non-symlink storage root on
/// the desired filesystem and is responsible for backup-exclusion policy. Blob
/// and record bytes are fsynced before hard-link create-if-absent publication;
/// like Android v1, parent-directory fsync durability is not claimed. A failed
/// install may leave valid unreferenced CAS blobs. A crash-created incomplete
/// version directory is rejected and is left for the later recovery layer.
/// This installer never creates or mutates registry/activation state.
public final class CapsuleInstaller: @unchecked Sendable {
    private let storage: CapsuleStorage
    private let verifier: CapsuleVerifier

    public init(
        storageRootURL: URL,
        verificationLimits: CapsuleVerificationLimits = .v1
    ) throws {
        storage = try CapsuleStorage(rootURL: storageRootURL)
        verifier = CapsuleVerifier(limits: verificationLimits)
    }

    init(
        storageRootURL: URL,
        verificationLimits: CapsuleVerificationLimits = .v1,
        faultInjector: @escaping CapsuleInstallFaultInjector
    ) throws {
        storage = try CapsuleStorage(rootURL: storageRootURL, faultInjector: faultInjector)
        verifier = CapsuleVerifier(limits: verificationLimits)
    }

    /// Independently verifies a trusted bundled archive file, then publishes it.
    /// Private signing keys are neither accepted nor stored.
    public func installBundled(
        archiveURL: URL,
        request: CapsuleVerificationRequest
    ) throws -> CapsuleInstallResult {
        let verified = try verifier.verify(
            archiveURL: archiveURL,
            stagingRootURL: storage.stagingURL,
            request: request
        )
        return try installVerified(verified)
    }

    /// Consumes a transient verifier result exactly once.
    public func installVerified(_ capsule: VerifiedCapsule) throws -> CapsuleInstallResult {
        try storage.withExclusiveLock {
            try storage.install(capsule)
        }
    }

    /// Strictly reads immutable metadata and revalidates every referenced blob.
    public func readInstalledVersion(capsuleId: String, version: String) throws -> VersionRecord {
        try storage.withExclusiveLock {
            try storage.read(capsuleId: capsuleId, version: version)
        }
    }
}
