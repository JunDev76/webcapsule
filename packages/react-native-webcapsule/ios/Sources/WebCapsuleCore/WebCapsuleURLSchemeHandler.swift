import Foundation
#if canImport(WebKit)
import WebKit
#endif

protocol PinnedResourceTaskSink: AnyObject {
    var requestURL: URL? { get }
    func didReceive(_ response: URLResponse)
    func didReceive(_ data: Data)
    func didFinish()
    func didFail(_ error: Error)
}

final class PinnedResourceTaskCoordinator: @unchecked Sendable {
    static let maximumChunkSize = 64 * 1024

    private enum Status {
        case running
        case stopped
        case terminal
    }

    private final class State {
        weak var sink: PinnedResourceTaskSink?
        var status: Status = .running
        var stream: PinnedBlobStream?

        init(sink: PinnedResourceTaskSink) {
            self.sink = sink
        }
    }

    private let resolver: PinnedResourceResolver
    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let lock = NSRecursiveLock()
    private var states: [ObjectIdentifier: State] = [:]

    init(
        resolver: PinnedResourceResolver,
        workQueue: DispatchQueue = DispatchQueue(label: "dev.webcapsule.resource-stream", qos: .userInitiated),
        callbackQueue: DispatchQueue = .main
    ) {
        self.resolver = resolver
        self.workQueue = workQueue
        self.callbackQueue = callbackQueue
    }

    func start(_ sink: PinnedResourceTaskSink) {
        let key = ObjectIdentifier(sink)
        lock.lock()
        if let existing = states.removeValue(forKey: key) {
            existing.status = .terminal
            let stream = existing.stream
            existing.stream = nil
            lock.unlock()
            stream?.close()
            callbackQueue.async { [weak sink] in
                sink?.didFail(WebCapsuleError(code: .resourceDenied, message: "Resource task was started twice"))
            }
            return
        }
        let state = State(sink: sink)
        states[key] = state
        lock.unlock()

        workQueue.async { [weak self, weak state] in
            guard let self, let state else { return }
            self.run(state, key: key)
        }
    }

    func stop(_ sink: PinnedResourceTaskSink) {
        let key = ObjectIdentifier(sink)
        lock.lock()
        guard let state = states.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        state.status = .stopped
        let stream = state.stream
        state.stream = nil
        lock.unlock()
        stream?.close()
    }

    func invalidate() {
        lock.lock()
        let active = Array(states.values)
        states.removeAll()
        for state in active { state.status = .stopped }
        let streams = active.compactMap(\.stream)
        active.forEach { $0.stream = nil }
        lock.unlock()
        streams.forEach { $0.close() }
    }

    private func run(_ state: State, key: ObjectIdentifier) {
        do {
            guard let rawURL = withRunning(state, { $0.sink?.requestURL }) ?? nil else {
                throw WebCapsuleError(code: .resourceDenied, message: "Resource request URL is absent")
            }
            let resource = try resolver.resolve(rawURL)
            guard install(resource.stream, on: state) else {
                resource.stream.close()
                return
            }
            let response = URLResponse(
                url: resource.metadata.url,
                mimeType: resource.metadata.mediaType,
                expectedContentLength: Int(resource.metadata.contentLength),
                textEncodingName: nil
            )
            guard callback(state, { $0.didReceive(response) }) else { return }

            while let chunk = try resource.stream.read(maximumCount: Self.maximumChunkSize) {
                guard callback(state, { $0.didReceive(chunk) }) else { return }
            }
            finish(state, key: key)
        } catch {
            fail(state, key: key, error: normalize(error))
        }
    }

    private func install(_ stream: PinnedBlobStream, on state: State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state.status == .running else { return false }
        state.stream = stream
        return true
    }

    private func callback(_ state: State, _ body: @escaping (PinnedResourceTaskSink) -> Void) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var delivered = false
        callbackQueue.async { [weak self, weak state] in
            defer { semaphore.signal() }
            guard let self, let state else { return }
            self.lock.lock()
            guard state.status == .running, let sink = state.sink else {
                self.lock.unlock()
                return
            }
            body(sink)
            delivered = true
            self.lock.unlock()
        }
        semaphore.wait()
        return delivered
    }

    private func finish(_ state: State, key: ObjectIdentifier) {
        terminal(state, key: key) { $0.didFinish() }
    }

    private func fail(_ state: State, key: ObjectIdentifier, error: Error) {
        terminal(state, key: key) { $0.didFail(error) }
    }

    private func terminal(
        _ state: State,
        key: ObjectIdentifier,
        callback body: @escaping (PinnedResourceTaskSink) -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        callbackQueue.async { [weak self, weak state] in
            defer { semaphore.signal() }
            guard let self, let state else { return }
            self.lock.lock()
            guard state.status == .running, let sink = state.sink else {
                self.lock.unlock()
                return
            }
            state.status = .terminal
            self.states.removeValue(forKey: key)
            let stream = state.stream
            state.stream = nil
            body(sink)
            self.lock.unlock()
            stream?.close()
        }
        semaphore.wait()
    }

    private func withRunning<T>(_ state: State, _ body: (State) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard state.status == .running else { return nil }
        return body(state)
    }

    private func normalize(_ error: Error) -> WebCapsuleError {
        if let error = error as? WebCapsuleError { return error }
        return WebCapsuleError(code: .storageInvariantViolation, message: "Pinned resource serving failed")
    }

    deinit { invalidate() }
}

#if canImport(WebKit)
private final class WebKitResourceTaskSink: PinnedResourceTaskSink {
    let task: WKURLSchemeTask
    private let terminal: () -> Void

    init(task: WKURLSchemeTask, terminal: @escaping () -> Void) {
        self.task = task
        self.terminal = terminal
    }

    var requestURL: URL? { task.request.url }
    func didReceive(_ response: URLResponse) { task.didReceive(response) }
    func didReceive(_ data: Data) { task.didReceive(data) }
    func didFinish() {
        task.didFinish()
        terminal()
    }
    func didFail(_ error: Error) {
        task.didFailWithError(error)
        terminal()
    }
}

/// Session-pinned WebKit custom-scheme handler. It strongly retains the
/// descriptor through its resolver for the entire handler lifetime and never
/// releases a pending-trial lease per resource request.
public final class WebCapsuleURLSchemeHandler: NSObject, WKURLSchemeHandler {
    public let entryURL: URL

    private let coordinator: PinnedResourceTaskCoordinator
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: WebKitResourceTaskSink] = [:]

    public init(storageRootURL: URL, session: SessionDescriptor) throws {
        let resolver = try PinnedResourceResolver(storageRootURL: storageRootURL, session: session)
        entryURL = resolver.entryURL
        coordinator = PinnedResourceTaskCoordinator(resolver: resolver)
        super.init()
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let sink = WebKitResourceTaskSink(task: urlSchemeTask) { [weak self] in
            self?.removeSink(key)
        }
        lock.lock()
        if let existing = sinks.removeValue(forKey: key) {
            lock.unlock()
            coordinator.stop(existing)
            urlSchemeTask.didFailWithError(
                WebCapsuleError(code: .resourceDenied, message: "Resource task was started twice")
            )
            return
        }
        sinks[key] = sink
        lock.unlock()
        coordinator.start(sink)
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        let sink = sinks.removeValue(forKey: key)
        lock.unlock()
        if let sink { coordinator.stop(sink) }
    }

    public func invalidate() {
        lock.lock()
        sinks.removeAll()
        lock.unlock()
        coordinator.invalidate()
    }

    private func removeSink(_ key: ObjectIdentifier) {
        lock.lock()
        sinks.removeValue(forKey: key)
        lock.unlock()
    }

    deinit { invalidate() }
}

public enum WebCapsuleWebViewConfiguration {
    /// Registers a session-pinned `webcapsule` handler on a new configuration.
    /// Navigation, network, cookie, bridge, and health policy remain the owning
    /// view's responsibility.
    public static func make(
        storageRootURL: URL,
        session: SessionDescriptor
    ) throws -> (configuration: WKWebViewConfiguration, handler: WebCapsuleURLSchemeHandler) {
        let handler = try WebCapsuleURLSchemeHandler(storageRootURL: storageRootURL, session: session)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: PinnedResourceResolver.scheme)
        return (configuration, handler)
    }
}
#endif
