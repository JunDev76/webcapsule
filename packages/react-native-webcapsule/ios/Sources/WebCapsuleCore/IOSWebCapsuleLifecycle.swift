import Foundation

public final class IOSWebCapsuleLifecycleController: @unchecked Sendable {
    public typealias Prepare = @Sendable (WebCapsuleConfig) throws -> IOSPreparedRuntimeSession
    public typealias Ready = @Sendable (IOSPreparedRuntimeSession) -> Void
    public typealias Failed = @Sendable (WebCapsuleError) -> Void

    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let prepare: Prepare
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var requestedConfig: WebCapsuleConfig?
    private var retainedSession: IOSPreparedRuntimeSession?
    private var invalidated = false

    public init(
        workQueue: DispatchQueue = DispatchQueue(
            label: "dev.webcapsule.ios-bootstrap",
            qos: .userInitiated
        ),
        callbackQueue: DispatchQueue = .main,
        prepare: @escaping Prepare
    ) {
        self.workQueue = workQueue
        self.callbackQueue = callbackQueue
        self.prepare = prepare
    }

    /// Equivalent repeated props are idempotent. A changed config invalidates the
    /// prior pinned session and starts one serialized background bootstrap.
    @discardableResult
    public func apply(config: WebCapsuleConfig, onReady: @escaping Ready, onError: @escaping Failed) -> Bool {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return false
        }
        if requestedConfig == config {
            lock.unlock()
            return false
        }
        generation &+= 1
        let token = generation
        requestedConfig = config
        let old = retainedSession
        retainedSession = nil
        lock.unlock()
        old?.session.releaseTrial()

        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let prepared = try self.prepare(config)
                guard self.accept(prepared, token: token) else {
                    prepared.session.releaseTrial()
                    return
                }
                self.callbackQueue.async { [weak self] in
                    guard let self, self.isCurrent(token: token) else { return }
                    onReady(prepared)
                }
            } catch {
                let failure = Self.normalize(error)
                self.callbackQueue.async { [weak self] in
                    guard let self, self.isCurrent(token: token) else { return }
                    onError(failure)
                }
            }
        }
        return true
    }

    public func invalidate() {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        invalidated = true
        generation &+= 1
        requestedConfig = nil
        let retained = retainedSession
        retainedSession = nil
        lock.unlock()
        retained?.session.releaseTrial()
    }

    private func accept(_ prepared: IOSPreparedRuntimeSession, token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated, token == generation else { return false }
        retainedSession = prepared
        return true
    }

    private func isCurrent(token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !invalidated && token == generation
    }

    private static func normalize(_ error: Error) -> WebCapsuleError {
        if let error = error as? WebCapsuleError { return error }
        return WebCapsuleError(code: .storageIOFailed, message: "iOS runtime preparation failed")
    }

    deinit { invalidate() }
}
