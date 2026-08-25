import Foundation

enum IOSTrialOutcome: Equatable, Sendable {
    case healthy(CapsuleRegistry)
    case pending(CapsuleRegistry)
    case rolledBack(
        registry: CapsuleRegistry,
        failedVersion: String,
        restoredVersion: String
    )
    case bundledFallback(
        registry: CapsuleRegistry,
        failedVersion: String,
        bundledVersion: String
    )
    case terminal(failedVersion: String)
}

struct IOSRollbackEvent: Equatable, Sendable {
    let capsuleId: String
    let failedVersion: String
    let restoredVersion: String?
    let reason: String
    let generation: String

    init(
        capsuleId: String,
        failedVersion: String,
        restoredVersion: String?,
        reason: String,
        generation: String
    ) {
        self.capsuleId = capsuleId
        self.failedVersion = failedVersion
        self.restoredVersion = restoredVersion
        self.reason = reason
        self.generation = generation
    }
}

final class IOSTrialOutcomeCoordinator: @unchecked Sendable {
    private let storage: CapsuleStorage
    private let registries: RegistryManager
    private let verifier: CapsuleVerifier
    private let bundledArchiveURL: URL
    private let request: CapsuleVerificationRequest
    private let completedLock = NSLock()
    private var completedOutcomes: [String: IOSTrialOutcome] = [:]

    init(
        storageRootURL: URL,
        bundledArchiveURL: URL,
        request: CapsuleVerificationRequest,
        verificationLimits: CapsuleVerificationLimits = .v1
    ) throws {
        storage = try CapsuleStorage(rootURL: storageRootURL)
        registries = RegistryManager(storage: storage)
        verifier = CapsuleVerifier(limits: verificationLimits)
        self.bundledArchiveURL = bundledArchiveURL
        self.request = request
    }

    func commitHealthy(_ session: SessionDescriptor) throws -> IOSTrialOutcome {
        defer { session.releaseTrial() }
        return try storage.withExclusiveLock(capsuleId: session.capsuleId) {
            if completedOutcome(session.sessionId) != nil {
                throw WebCapsuleError(code: .sessionMismatch, message: "Session outcome already completed")
            }
            _ = try storage.read(capsuleId: session.capsuleId, version: session.version)
            let outcome: IOSTrialOutcome
            if session.trialVersion == nil {
                guard let registry = try registries.readLocked(capsuleId: session.capsuleId),
                      registry.active.healthy,
                      registry.active.version == session.version else {
                    throw WebCapsuleError(code: .sessionMismatch, message: "Healthy session is no longer active")
                }
                outcome = .healthy(registry)
            } else {
                outcome = .healthy(try registries.commitHealthyLocked(session: session))
            }
            storeCompletedOutcome(outcome, sessionId: session.sessionId)
            return outcome
        }
    }

    func recordExplicitFailure(_ session: SessionDescriptor) throws -> IOSTrialOutcome {
        defer { session.releaseTrial() }
        if let completed = completedOutcome(session.sessionId) {
            if case .healthy = completed {
                throw WebCapsuleError(code: .sessionMismatch, message: "Session already committed healthy")
            }
            return completed
        }
        let outcome = try storage.withExclusiveLock(capsuleId: session.capsuleId) {
            if let completed = completedOutcome(session.sessionId) {
                if case .healthy = completed {
                    throw WebCapsuleError(code: .sessionMismatch, message: "Session already committed healthy")
                }
                return completed
            }
            let result: IOSTrialOutcome
            if session.trialVersion == nil {
                guard let registry = try registries.readLocked(capsuleId: session.capsuleId),
                      registry.active.healthy,
                      registry.active.version == session.version else {
                    throw WebCapsuleError(code: .sessionMismatch, message: "Healthy session is no longer active")
                }
                result = .healthy(registry)
            } else {
                let registry = try matchingRegistry(session)
                if let attempts = registry.pending?.attempts,
                   attempts < registryMaximumPendingAttempts {
                    result = .pending(registry)
                } else {
                    result = try reconcileLocked(registry, session: session)
                }
            }
            storeCompletedOutcome(result, sessionId: session.sessionId)
            return result
        }
        return outcome
    }

    static func rollbackEvent(
        session: SessionDescriptor,
        outcome: IOSTrialOutcome,
        reason: WebCapsuleErrorCode
    ) -> IOSRollbackEvent? {
        switch outcome {
        case let .rolledBack(registry, failedVersion, restoredVersion):
            return IOSRollbackEvent(
                capsuleId: session.capsuleId,
                failedVersion: failedVersion,
                restoredVersion: restoredVersion,
                reason: reason.rawValue,
                generation: String(registry.generation)
            )
        case let .bundledFallback(registry, failedVersion, bundledVersion):
            return IOSRollbackEvent(
                capsuleId: session.capsuleId,
                failedVersion: failedVersion,
                restoredVersion: bundledVersion,
                reason: reason.rawValue,
                generation: String(registry.generation)
            )
        case let .terminal(failedVersion):
            return IOSRollbackEvent(
                capsuleId: session.capsuleId,
                failedVersion: failedVersion,
                restoredVersion: nil,
                reason: WebCapsuleErrorCode.noRunnableVersion.rawValue,
                generation: String(session.registryGeneration)
            )
        case .healthy, .pending:
            return nil
        }
    }

    private func matchingRegistry(_ session: SessionDescriptor) throws -> CapsuleRegistry {
        guard let registry = try registries.readLocked(capsuleId: session.capsuleId),
              registry.generation == session.registryGeneration,
              !registry.active.healthy,
              registry.active.version == session.version,
              registry.pending?.version == session.trialVersion,
              registry.pending?.attempts == session.trialAttempt else {
            throw WebCapsuleError(code: .sessionMismatch, message: "Pending trial no longer matches session")
        }
        return registry
    }

    private func reconcileLocked(
        _ registry: CapsuleRegistry,
        session: SessionDescriptor
    ) throws -> IOSTrialOutcome {
        let failed = registry.active.version
        if let previous = registry.previous?.version {
            let previousIsRunnable: Bool
            do {
                _ = try storage.read(capsuleId: registry.capsuleId, version: previous)
                previousIsRunnable = true
            } catch {
                previousIsRunnable = false
            }
            if previousIsRunnable {
                do {
                    let next = try registries.rollbackPendingLocked(
                        session: session,
                        restoredVersion: previous
                    )
                    return .rolledBack(
                        registry: next,
                        failedVersion: failed,
                        restoredVersion: previous
                    )
                } catch let error as WebCapsuleError where error.code == .sessionMismatch {
                    throw error
                } catch {
                    throw WebCapsuleError(
                        code: .rollbackFailed,
                        message: "Rollback registry transition could not commit"
                    )
                }
            }
        }

        let bundled: VersionRecord
        do {
            let verified = try verifier.verify(
                archiveURL: bundledArchiveURL,
                stagingRootURL: storage.stagingURL,
                request: request
            )
            bundled = try storage.install(verified).record
        } catch {
            if registry.previous == nil { return .terminal(failedVersion: failed) }
            throw WebCapsuleError(
                code: .rollbackTargetUnavailable,
                message: "Neither previous nor bundled capsule is runnable"
            )
        }
        let installed: VersionRecord
        do {
            installed = try storage.read(
                capsuleId: bundled.capsuleId,
                version: bundled.version
            )
        } catch {
            throw WebCapsuleError(
                code: .rollbackFailed,
                message: "Bundled fallback installation is incomplete"
            )
        }
        guard installed == bundled,
              bundled.capsuleId == registry.capsuleId else {
            throw WebCapsuleError(code: .rollbackFailed, message: "Bundled fallback identity is invalid")
        }
        guard bundled.version != failed else {
            if registry.previous == nil { return .terminal(failedVersion: failed) }
            throw WebCapsuleError(code: .rollbackFailed, message: "Bundled fallback repeats failed version")
        }
        do {
            let next = try registries.registerBundledFallbackLocked(registry, record: bundled)
            return .bundledFallback(
                registry: next,
                failedVersion: failed,
                bundledVersion: bundled.version
            )
        } catch let error as WebCapsuleError where error.code == .updateStateChanged {
            throw WebCapsuleError(code: .sessionMismatch, message: "Bundled fallback state changed")
        } catch let error as WebCapsuleError {
            throw error
        } catch {
            throw WebCapsuleError(code: .rollbackFailed, message: "Bundled fallback could not commit")
        }
    }

    private func completedOutcome(_ sessionId: String) -> IOSTrialOutcome? {
        completedLock.lock()
        defer { completedLock.unlock() }
        return completedOutcomes[sessionId]
    }

    private func storeCompletedOutcome(_ outcome: IOSTrialOutcome, sessionId: String) {
        completedLock.lock()
        completedOutcomes[sessionId] = outcome
        completedLock.unlock()
    }
}
