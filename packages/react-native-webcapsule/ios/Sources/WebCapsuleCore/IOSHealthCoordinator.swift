import Foundation

struct ReadyMessage: Equatable, Sendable {
    let type: String
    let protocolVersion: Int64
    let sessionId: String
    let capsuleId: String
    let version: String
}

enum ReadyMessageParser {
    private static let fields: Set<String> = [
        "type", "protocolVersion", "sessionId", "capsuleId", "version",
    ]

    static func parse(_ value: String) throws -> ReadyMessage {
        do {
            let parsed = try StrictJSON.parse(Data(value.utf8))
            guard case let .object(root) = parsed else {
                throw invalid("Ready message must be an object")
            }
            guard root.entries.count == fields.count,
                  Set(root.entries.map(\.key)) == fields else {
                throw invalid("Ready message fields differ")
            }
            guard case let .string(type) = required(root, "type"),
                  case let .integer(protocolVersion) = required(root, "protocolVersion"),
                  case let .string(sessionId) = required(root, "sessionId"),
                  case let .string(capsuleId) = required(root, "capsuleId"),
                  case let .string(version) = required(root, "version") else {
                throw invalid("Ready message field types are invalid")
            }
            guard type == "ready", protocolVersion == 1 else {
                throw invalid("Ready protocol is unsupported")
            }
            return ReadyMessage(
                type: type,
                protocolVersion: protocolVersion,
                sessionId: sessionId,
                capsuleId: capsuleId,
                version: version
            )
        } catch let error as WebCapsuleError where error.code == .readyMessageInvalid {
            throw error
        } catch {
            throw invalid("Ready message is invalid JSON")
        }
    }

    private static func required(_ object: StrictJSONObject, _ key: String) -> StrictJSONValue {
        object[key] ?? .null
    }

    private static func invalid(_ message: String) -> WebCapsuleError {
        WebCapsuleError(code: .readyMessageInvalid, message: message)
    }
}

struct ReadyMessageSource: Equatable, Sendable {
    let isMainFrame: Bool
    let scheme: String
    let host: String
    let port: Int
    let documentURL: URL?
}

enum WebCapsuleReadyBridgeContract {
    static let channelName = "WebCapsuleBridge"
    static let protocolVersion: Int64 = 1

    static func bootstrapJSON(session: SessionDescriptor) -> String {
        let value = StrictJSONValue.object(StrictJSONObject(entries: [
            ("capsuleId", .string(session.capsuleId)),
            ("protocolVersion", .integer(protocolVersion)),
            ("sessionId", .string(session.sessionId)),
            ("type", .string("ready")),
            ("version", .string(session.version)),
        ]))
        return String(decoding: CanonicalJSON.serialize(value), as: UTF8.self)
    }

    static func bootstrapScript(session: SessionDescriptor) -> String {
        let sessionJSON = bootstrapJSON(session: session)
        return "Object.defineProperty(globalThis,'__WEBCAPSULE_SESSION__',{value:Object.freeze(\(sessionJSON)),writable:false,configurable:false,enumerable:false});Object.defineProperty(globalThis,'WebCapsuleBridge',{value:Object.freeze({postMessage:function(value){globalThis.webkit.messageHandlers.WebCapsuleBridge.postMessage(value);}}),writable:false,configurable:false,enumerable:false});"
    }
}

protocol IOSHealthScheduling: AnyObject {
    var nowNanoseconds: UInt64 { get }
    func schedule(afterNanoseconds: UInt64, _ action: @escaping @Sendable () -> Void) -> AnyObject
    func cancel(_ token: AnyObject)
}

final class DispatchHealthScheduler: IOSHealthScheduling, @unchecked Sendable {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    var nowNanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }

    func schedule(afterNanoseconds: UInt64, _ action: @escaping @Sendable () -> Void) -> AnyObject {
        let item = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: afterNanoseconds)), execute: item)
        return item
    }

    func cancel(_ token: AnyObject) {
        (token as? DispatchWorkItem)?.cancel()
    }
}

final class IOSHealthCoordinator: @unchecked Sendable {
    static let readyTimeoutNanoseconds: UInt64 = 15_000_000_000
    static let stabilizationNanoseconds: UInt64 = 3_000_000_000

    private enum State {
        case waitingForEntry
        case waitingForReady
        case stabilizing
        case succeeded
        case failed
        case closed
    }

    private let session: SessionDescriptor
    private let entryURL: URL
    private let scheduler: IOSHealthScheduling
    private let readyDeadlineNanoseconds: UInt64
    private let commit: @Sendable () throws -> Void
    private let success: @Sendable () -> Void
    private let failure: @Sendable (WebCapsuleError) -> Void
    private let lock = NSRecursiveLock()
    private var state: State = .waitingForEntry
    private var timer: AnyObject?

    init(
        session: SessionDescriptor,
        entryURL: URL,
        scheduler: IOSHealthScheduling,
        commit: @escaping @Sendable () throws -> Void,
        success: @escaping @Sendable () -> Void,
        failure: @escaping @Sendable (WebCapsuleError) -> Void
    ) {
        self.session = session
        self.entryURL = entryURL
        self.scheduler = scheduler
        self.commit = commit
        self.success = success
        self.failure = failure

        let deadline = session.createdMonotonicNanoseconds.addingReportingOverflow(Self.readyTimeoutNanoseconds)
        let now = scheduler.nowNanoseconds
        readyDeadlineNanoseconds = deadline.overflow ? 0 : deadline.partialValue
        guard !deadline.overflow, now < deadline.partialValue else {
            failOnce(WebCapsuleError(code: .readyTimeout, message: "Ready deadline expired"))
            return
        }
        timer = scheduler.schedule(afterNanoseconds: deadline.partialValue - now) { [weak self] in
            self?.failOnce(WebCapsuleError(code: .readyTimeout, message: "Ready deadline expired"))
        }
    }

    func entryLoaded() {
        lock.lock()
        defer { lock.unlock() }
        if state == .waitingForEntry { state = .waitingForReady }
    }

    func ready(body: String, source: ReadyMessageSource) {
        lock.lock()
        defer { lock.unlock() }
        if state == .stabilizing {
            failOnce(WebCapsuleError(code: .readyMessageInvalid, message: "Duplicate ready message"))
            return
        }
        if scheduler.nowNanoseconds >= readyDeadlineNanoseconds {
            failOnce(WebCapsuleError(code: .readyTimeout, message: "Ready deadline expired"))
            return
        }
        guard state == .waitingForReady else {
            failOnce(WebCapsuleError(code: .readyMessageInvalid, message: "Ready arrived before entry completed"))
            return
        }
        guard source.isMainFrame,
              source.scheme == PinnedResourceResolver.scheme,
              source.host == session.capsuleId,
              source.port == 0,
              WebCapsuleNavigationPolicy.allowsTopLevelNavigation(
                  candidate: source.documentURL,
                  entryURL: entryURL
              ) else {
            failOnce(WebCapsuleError(code: .readyMessageInvalid, message: "Ready source is not the pinned main frame"))
            return
        }
        let message: ReadyMessage
        do {
            message = try ReadyMessageParser.parse(body)
        } catch let error as WebCapsuleError {
            failOnce(error)
            return
        } catch {
            failOnce(WebCapsuleError(code: .readyMessageInvalid, message: "Ready message is invalid"))
            return
        }
        guard message.sessionId == session.sessionId,
              message.capsuleId == session.capsuleId,
              message.version == session.version else {
            failOnce(WebCapsuleError(code: .sessionMismatch, message: "Ready identity differs from session"))
            return
        }
        cancelTimer()
        state = .stabilizing
        timer = scheduler.schedule(afterNanoseconds: Self.stabilizationNanoseconds) { [weak self] in
            self?.completeStabilization()
        }
    }

    func entryFailed(_ message: String) {
        failOnce(WebCapsuleError(code: .entryLoadFailed, message: message))
    }

    func invalidReady(_ message: String) {
        failOnce(WebCapsuleError(code: .readyMessageInvalid, message: message))
    }

    func fatal(_ message: String) {
        failOnce(WebCapsuleError(code: .stabilizationFailed, message: message))
    }

    func preparationFailed(_ error: WebCapsuleError) {
        failOnce(error)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        cancelTimer()
        if state != .succeeded && state != .failed { state = .closed }
    }

    private func completeStabilization() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .stabilizing else { return }
        do {
            try commit()
            guard state == .stabilizing else { return }
            state = .succeeded
            timer = nil
            success()
        } catch let error as WebCapsuleError {
            failOnce(error)
        } catch {
            failOnce(WebCapsuleError(code: .rollbackFailed, message: "Health commit failed"))
        }
    }

    private func failOnce(_ error: WebCapsuleError) {
        lock.lock()
        defer { lock.unlock() }
        guard state != .succeeded, state != .failed, state != .closed else { return }
        cancelTimer()
        state = .failed
        failure(error)
    }

    private func cancelTimer() {
        if let timer { scheduler.cancel(timer) }
        timer = nil
    }
}
