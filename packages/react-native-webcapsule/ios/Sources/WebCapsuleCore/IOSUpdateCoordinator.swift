import Foundation

struct IOSUpdateRequest: Sendable {
    let config: WebCapsuleConfig
    let bundledArchiveURL: URL
    let indexURL: URL
    let channel: String
}

enum IOSUpdateInstallResult: Equatable, Sendable {
    case installed(
        previousVersion: String,
        currentVersion: String,
        highestSeenVersion: String,
        generation: Int64
    )
    case upToDate(
        currentVersion: String,
        highestSeenVersion: String,
        generation: Int64
    )
}

final class IOSUpdateCoordinator: @unchecked Sendable {
    private let transport: UpdateTransport
    private let storageRootURL: URL
    private let trustedCacheBaseURL: URL
    private let beforeCommit: @Sendable () -> Void

    init(
        storageRootURL: URL,
        trustedCacheBaseURL: URL,
        transport: UpdateTransport = HTTPSUpdateTransport(),
        beforeCommit: @escaping @Sendable () -> Void = {}
    ) {
        self.storageRootURL = storageRootURL
        self.trustedCacheBaseURL = trustedCacheBaseURL
        self.transport = transport
        self.beforeCommit = beforeCommit
    }

    func install(_ request: IOSUpdateRequest) throws -> IOSUpdateInstallResult {
        guard UpdateProcessGuard.shared.acquire(request.config.capsuleId) else {
            throw WebCapsuleError(code: .updateInProgress, message: "An update is already running for this capsule")
        }
        defer { UpdateProcessGuard.shared.release(request.config.capsuleId) }

        try WebCapsuleConfigValidator.validate(request.config)
        try UpdateIndexVerifier.validateChannel(request.channel)
        let exactIndexURL = try UpdateIndexVerifier.strictHTTPS(request.indexURL.absoluteString)
        let verificationRequest = CapsuleVerificationRequest(
            expectedCapsuleId: request.config.capsuleId,
            runtimeVersion: request.config.runtimeVersion,
            publicKeys: request.config.publicKeys
        )
        let runtime = try IOSRuntimeBootstrap(storageRootURL: storageRootURL)
        let snapshot = try runtime.prepareUpdateSnapshot(
            bundledArchiveURL: request.bundledArchiveURL,
            request: verificationRequest
        )

        let indexBytes = try transport.fetchIndex(exactIndexURL)
        let index = try UpdateIndexVerifier.verify(
            indexBytes,
            expectedCapsuleId: request.config.capsuleId,
            expectedChannel: request.channel,
            publicKeys: request.config.publicKeys
        )
        guard let release = try UpdateIndexVerifier.select(
            index,
            runtimeVersion: request.config.runtimeVersion,
            highestSeenVersion: snapshot.highestSeenVersion,
            blockedVersions: Set(snapshot.blockedVersions)
        ) else {
            return .upToDate(
                currentVersion: snapshot.active.version,
                highestSeenVersion: snapshot.highestSeenVersion,
                generation: snapshot.generation
            )
        }

        let downloaded = try transport.fetchCapsule(release, trustedCacheBaseURL: trustedCacheBaseURL)
        defer { downloaded.cleanup() }
        beforeCommit()
        let registry = try runtime.verifyAndInstallPendingUpdate(
            expected: snapshot,
            archiveURL: downloaded.fileURL,
            expectedVersion: release.version,
            bundledArchiveURL: request.bundledArchiveURL,
            request: verificationRequest
        )
        return .installed(
            previousVersion: snapshot.active.version,
            currentVersion: registry.active.version,
            highestSeenVersion: registry.highestSeenVersion,
            generation: registry.generation
        )
    }
}

private final class UpdateProcessGuard: @unchecked Sendable {
    static let shared = UpdateProcessGuard()

    private let lock = NSLock()
    private var running = Set<String>()

    func acquire(_ capsuleId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running.insert(capsuleId).inserted
    }

    func release(_ capsuleId: String) {
        lock.lock()
        running.remove(capsuleId)
        lock.unlock()
    }
}
