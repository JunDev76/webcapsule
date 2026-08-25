import CryptoKit
import Foundation

public struct SessionFile: Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let size: Int64
    public let mediaType: String

    init(path: String, sha256: String, size: Int64, mediaType: String) {
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.mediaType = mediaType
    }
}

/// Immutable, reference-validated selection for one future WebView session.
/// Registry changes after creation do not mutate this value.
public struct SessionDescriptor: Equatable, Sendable {
    public let sessionId: String
    public let capsuleId: String
    public let version: String
    public let entry: String
    public let recordSHA256: String
    public let registryGeneration: Int64
    public let createdMonotonicNanoseconds: UInt64
    public let files: [String: SessionFile]
    public let trialVersion: String?
    public let trialAttempt: Int64?

    private let trialLease: PendingTrialLease?

    init(
        sessionId: String,
        capsuleId: String,
        version: String,
        entry: String,
        recordSHA256: String,
        registryGeneration: Int64,
        createdMonotonicNanoseconds: UInt64,
        files: [String: SessionFile],
        trialVersion: String?,
        trialAttempt: Int64?
    ) {
        self.init(
            sessionId: sessionId,
            capsuleId: capsuleId,
            version: version,
            entry: entry,
            recordSHA256: recordSHA256,
            registryGeneration: registryGeneration,
            createdMonotonicNanoseconds: createdMonotonicNanoseconds,
            files: files,
            trialVersion: trialVersion,
            trialAttempt: trialAttempt,
            trialLease: nil
        )
    }

    fileprivate init(
        sessionId: String,
        capsuleId: String,
        version: String,
        entry: String,
        recordSHA256: String,
        registryGeneration: Int64,
        createdMonotonicNanoseconds: UInt64,
        files: [String: SessionFile],
        trialVersion: String?,
        trialAttempt: Int64?,
        trialLease: PendingTrialLease?
    ) {
        self.sessionId = sessionId
        self.capsuleId = capsuleId
        self.version = version
        self.entry = entry
        self.recordSHA256 = recordSHA256
        self.registryGeneration = registryGeneration
        self.createdMonotonicNanoseconds = createdMonotonicNanoseconds
        self.files = files
        self.trialVersion = trialVersion
        self.trialAttempt = trialAttempt
        self.trialLease = trialLease
    }

    public static func == (left: SessionDescriptor, right: SessionDescriptor) -> Bool {
        left.sessionId == right.sessionId
            && left.capsuleId == right.capsuleId
            && left.version == right.version
            && left.entry == right.entry
            && left.recordSHA256 == right.recordSHA256
            && left.registryGeneration == right.registryGeneration
            && left.createdMonotonicNanoseconds == right.createdMonotonicNanoseconds
            && left.files == right.files
            && left.trialVersion == right.trialVersion
            && left.trialAttempt == right.trialAttempt
    }

    func releaseTrial() {
        trialLease?.release()
    }
}

private final class PendingTrialLease: @unchecked Sendable {
    private let capsuleId: String
    private let identifier: UUID
    private let owner: PendingTrialGuard

    init(capsuleId: String, identifier: UUID, owner: PendingTrialGuard) {
        self.capsuleId = capsuleId
        self.identifier = identifier
        self.owner = owner
    }

    func release() {
        owner.release(capsuleId: capsuleId, identifier: identifier)
    }

    deinit {
        release()
    }
}

private final class PendingTrialGuard: @unchecked Sendable {
    static let process = PendingTrialGuard()

    private let lock = NSLock()
    private var active: [String: UUID] = [:]

    func acquire(capsuleId: String) throws -> PendingTrialLease {
        lock.lock()
        defer { lock.unlock() }
        guard active[capsuleId] == nil else {
            throw WebCapsuleError(code: .trialSessionInProgress, message: "A pending trial is already running")
        }
        let identifier = UUID()
        active[capsuleId] = identifier
        return PendingTrialLease(capsuleId: capsuleId, identifier: identifier, owner: self)
    }

    fileprivate func release(capsuleId: String, identifier: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if active[capsuleId] == identifier {
            active.removeValue(forKey: capsuleId)
        }
    }
}

public final class IOSRuntimeBootstrap: @unchecked Sendable {
    private let storage: CapsuleStorage
    private let verifier: CapsuleVerifier
    private let registries: RegistryManager
    private let monotonicClock: @Sendable () -> UInt64
    private let sessionID: @Sendable () -> String

    public init(
        storageRootURL: URL,
        verificationLimits: CapsuleVerificationLimits = .v1
    ) throws {
        let storage = try CapsuleStorage(rootURL: storageRootURL)
        self.storage = storage
        verifier = CapsuleVerifier(limits: verificationLimits)
        registries = RegistryManager(storage: storage)
        monotonicClock = { DispatchTime.now().uptimeNanoseconds }
        sessionID = { UUID().uuidString.lowercased() }
    }

    init(
        storageRootURL: URL,
        verificationLimits: CapsuleVerificationLimits = .v1,
        registryFaultInjector: @escaping RegistryWriteFaultInjector,
        monotonicClock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sessionID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) throws {
        let storage = try CapsuleStorage(
            rootURL: storageRootURL,
            registryFaultInjector: registryFaultInjector
        )
        self.storage = storage
        verifier = CapsuleVerifier(limits: verificationLimits)
        registries = RegistryManager(storage: storage)
        self.monotonicClock = monotonicClock
        self.sessionID = sessionID
    }

    /// Independently verifies the configured bundled archive when recovery is
    /// required, durably commits any pending attempt, then returns an immutable
    /// active-version session selection. Ready/stabilization remain deferred.
    public func start(
        bundledArchiveURL: URL,
        request: CapsuleVerificationRequest
    ) throws -> SessionDescriptor {
        try SignedManifestVerifier.validate(request.manifestRequestForRuntime)
        return try storage.withExclusiveLock(capsuleId: request.expectedCapsuleId) {
            let recovered = try recoverLocked(bundledArchiveURL: bundledArchiveURL, request: request)
            let reconciled = try reconcileExhaustedLocked(
                recovered,
                bundledArchiveURL: bundledArchiveURL,
                request: request
            )
            return try selectLocked(registry: reconciled)
        }
    }

    func readRegistry(capsuleId: String) throws -> CapsuleRegistry? {
        try storage.withExclusiveLock(capsuleId: capsuleId) {
            try registries.readLocked(capsuleId: capsuleId)
        }
    }

    func compareAndSwap(
        capsuleId: String,
        expectedGeneration: Int64,
        transform: (CapsuleRegistry) throws -> CapsuleRegistry
    ) throws -> CapsuleRegistry {
        try storage.withExclusiveLock(capsuleId: capsuleId) {
            try registries.compareAndSwapLocked(
                capsuleId: capsuleId,
                expectedGeneration: expectedGeneration,
                transform: transform
            )
        }
    }

    private func recoverLocked(
        bundledArchiveURL: URL,
        request: CapsuleVerificationRequest
    ) throws -> CapsuleRegistry {
        var originalFailure: Error?
        do {
            if let registry = try registries.readLocked(capsuleId: request.expectedCapsuleId) {
                try verifyReferencesLocked(registry)
                try storage.cleanupStagingOperations(capsuleId: request.expectedCapsuleId)
                try storage.cleanupRegistryTemps(capsuleId: request.expectedCapsuleId)
                return registry
            }
            throw WebCapsuleError(code: .registryInvalid, message: "Registry is missing")
        } catch let error as WebCapsuleError where error.code == .unsafeStorageLayout {
            throw error
        } catch {
            originalFailure = error
        }

        do {
            try storage.cleanupStagingOperations(capsuleId: request.expectedCapsuleId)
            try storage.cleanupRegistryTemps(capsuleId: request.expectedCapsuleId)
            let record = try installBundledLocked(archiveURL: bundledArchiveURL, request: request)
            let verified = try storage.read(capsuleId: record.capsuleId, version: record.version)
            guard verified == record, record.capsuleId == request.expectedCapsuleId else {
                throw WebCapsuleError(code: .registryRecoveryFailed, message: "Bundled installation result differs")
            }
            return try registries.replaceFreshLocked(record: verified)
        } catch let error as WebCapsuleError where
            error.code == .bundledCapsuleUnavailable || error.code == .unsafeStorageLayout {
            throw error
        } catch {
            let detail = originalFailure.map { "; original: \($0)" } ?? ""
            throw WebCapsuleError(
                code: .registryRecoveryFailed,
                message: "Bundled-only registry recovery failed\(detail)"
            )
        }
    }

    private func reconcileExhaustedLocked(
        _ registry: CapsuleRegistry,
        bundledArchiveURL: URL,
        request: CapsuleVerificationRequest
    ) throws -> CapsuleRegistry {
        guard !registry.active.healthy,
              registry.pending?.attempts == registryMaximumPendingAttempts else {
            return registry
        }
        if let previous = registry.previous?.version {
            if (try? storage.read(capsuleId: registry.capsuleId, version: previous)) != nil {
                return try registries.rollbackExhaustedLocked(registry, restoredVersion: previous)
            }
        }

        let bundled: VersionRecord
        do {
            bundled = try installBundledLocked(archiveURL: bundledArchiveURL, request: request)
            guard try storage.read(capsuleId: bundled.capsuleId, version: bundled.version) == bundled else {
                throw WebCapsuleError(code: .registryRecoveryFailed, message: "Bundled fallback is incomplete")
            }
        } catch {
            if registry.previous == nil {
                throw WebCapsuleError(code: .noRunnableVersion, message: "Pending bundled capsule exhausted all attempts")
            }
            throw WebCapsuleError(code: .rollbackTargetUnavailable, message: "Neither previous nor bundled fallback is runnable")
        }
        guard bundled.capsuleId == registry.capsuleId else {
            throw WebCapsuleError(code: .rollbackFailed, message: "Bundled fallback identity differs")
        }
        guard bundled.version != registry.active.version else {
            throw WebCapsuleError(code: .noRunnableVersion, message: "Exhausted bundled artifact cannot be retried")
        }
        return try registries.registerBundledFallbackLocked(registry, record: bundled)
    }

    private func verifyReferencesLocked(_ registry: CapsuleRegistry) throws {
        var unique = Set<String>()
        for version in [registry.active.version, registry.previous?.version, registry.pending?.version].compactMap({ $0 }) {
            if unique.insert(version).inserted {
                do {
                    _ = try storage.read(capsuleId: registry.capsuleId, version: version)
                } catch {
                    throw WebCapsuleError(code: .registryInvalid, message: "Registry reference is not runnable")
                }
            }
        }
    }

    private func selectLocked(registry recovered: CapsuleRegistry) throws -> SessionDescriptor {
        var registry = recovered
        var trialLease: PendingTrialLease?
        var trialAttempt: Int64?
        if !registry.active.healthy {
            guard let pending = registry.pending,
                  pending.version == registry.active.version,
                  pending.attempts < registryMaximumPendingAttempts else {
                throw WebCapsuleError(code: .noRunnableVersion, message: "Pending trial attempts are exhausted")
            }
            trialLease = try PendingTrialGuard.process.acquire(capsuleId: registry.capsuleId)
            do {
                registry = try registries.incrementPendingAttemptLocked(registry)
                trialAttempt = registry.pending?.attempts
            } catch {
                trialLease?.release()
                throw error
            }
        }
        // Capture the health deadline origin immediately after the durable
        // attempt transition, before record/blob validation or WebView setup.
        let createdMonotonicNanoseconds = monotonicClock()

        let record: VersionRecord
        do {
            record = try storage.read(capsuleId: registry.capsuleId, version: registry.active.version)
        } catch {
            trialLease?.release()
            throw WebCapsuleError(code: .noRunnableVersion, message: "Active version cannot be selected")
        }
        let recordBytes = try VersionRecordCodec.serialize(record)
        let digest = SHA256.hash(data: recordBytes).map { String(format: "%02x", $0) }.joined()
        let files = Dictionary(uniqueKeysWithValues: record.files.map {
            ($0.path, SessionFile(path: $0.path, sha256: $0.sha256, size: $0.size, mediaType: $0.mediaType))
        })
        return SessionDescriptor(
            sessionId: sessionID(),
            capsuleId: record.capsuleId,
            version: record.version,
            entry: record.entry,
            recordSHA256: digest,
            registryGeneration: registry.generation,
            createdMonotonicNanoseconds: createdMonotonicNanoseconds,
            files: files,
            trialVersion: registry.active.healthy ? nil : registry.active.version,
            trialAttempt: trialAttempt,
            trialLease: trialLease
        )
    }

    private func installBundledLocked(
        archiveURL: URL,
        request: CapsuleVerificationRequest
    ) throws -> VersionRecord {
        do {
            let verified = try verifier.verify(
                archiveURL: archiveURL,
                stagingRootURL: storage.stagingURL,
                request: request
            )
            return try storage.install(verified).record
        } catch {
            throw WebCapsuleError(code: .bundledCapsuleUnavailable, message: "Bundled capsule cannot be verified and installed")
        }
    }
}

private extension CapsuleVerificationRequest {
    var manifestRequestForRuntime: ManifestVerificationRequest {
        ManifestVerificationRequest(
            expectedCapsuleId: expectedCapsuleId,
            runtimeVersion: runtimeVersion,
            publicKeys: publicKeys
        )
    }
}
