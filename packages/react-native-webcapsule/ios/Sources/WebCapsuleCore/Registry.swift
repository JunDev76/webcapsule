import Foundation

let registryMaximumSafeInteger: Int64 = 9_007_199_254_740_991
let registryMaximumPendingAttempts: Int64 = 2

public struct ActiveVersion: Equatable, Sendable {
    public let version: String
    public let healthy: Bool

    init(version: String, healthy: Bool) {
        self.version = version
        self.healthy = healthy
    }
}

public struct PreviousVersion: Equatable, Sendable {
    public let version: String

    init(version: String) {
        self.version = version
    }
}

public struct PendingVersion: Equatable, Sendable {
    public let version: String
    public let attempts: Int64

    init(version: String, attempts: Int64) {
        self.version = version
        self.attempts = attempts
    }
}

/// Canonical mutable runtime state. Values can only be created by the validated
/// codec and internal state transitions.
public struct CapsuleRegistry: Equatable, Sendable {
    public let schemaVersion: Int
    public let capsuleId: String
    public let generation: Int64
    public let active: ActiveVersion
    public let previous: PreviousVersion?
    public let pending: PendingVersion?
    public let highestSeenVersion: String
    public let blockedVersions: [String]

    init(
        schemaVersion: Int,
        capsuleId: String,
        generation: Int64,
        active: ActiveVersion,
        previous: PreviousVersion?,
        pending: PendingVersion?,
        highestSeenVersion: String,
        blockedVersions: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.capsuleId = capsuleId
        self.generation = generation
        self.active = active
        self.previous = previous
        self.pending = pending
        self.highestSeenVersion = highestSeenVersion
        self.blockedVersions = blockedVersions
    }
}

enum RegistryCodec {
    private static let rootFields: Set<String> = [
        "schemaVersion", "capsuleId", "generation", "active", "previous", "pending",
        "highestSeenVersion", "blockedVersions",
    ]
    private static let activeFields: Set<String> = ["version", "healthy"]
    private static let previousFields: Set<String> = ["version"]
    private static let pendingFields: Set<String> = ["version", "attempts"]

    static func parse(_ data: Data, expectedCapsuleId: String) throws -> CapsuleRegistry {
        do {
            guard data.last == 0x0A, data.dropLast().last != 0x0A else {
                throw invalid("Registry must end with exactly one LF")
            }
            let value = try StrictJSON.parse(Data(data.dropLast()))
            guard case let .object(root) = value else { throw invalid("Registry must be an object") }
            try exact(root, fields: rootFields, label: "Registry")
            guard case let .integer(schemaVersion) = try required(root, "schemaVersion"), schemaVersion == 1,
                  case let .string(capsuleId) = try required(root, "capsuleId"),
                  case let .integer(generation) = try required(root, "generation"),
                  case let .object(activeObject) = try required(root, "active"),
                  case let .string(highestSeenVersion) = try required(root, "highestSeenVersion"),
                  case let .array(blockedValues) = try required(root, "blockedVersions") else {
                throw invalid("Registry field type is invalid")
            }
            try exact(activeObject, fields: activeFields, label: "active")
            guard case let .string(activeVersion) = try required(activeObject, "version"),
                  case let .bool(healthy) = try required(activeObject, "healthy") else {
                throw invalid("Active field type is invalid")
            }
            let previous = try parsePrevious(required(root, "previous"))
            let pending = try parsePending(required(root, "pending"))
            let blockedVersions = try blockedValues.map { value -> String in
                guard case let .string(version) = value else {
                    throw invalid("blockedVersions values must be strings")
                }
                return version
            }
            let registry = CapsuleRegistry(
                schemaVersion: 1,
                capsuleId: capsuleId,
                generation: generation,
                active: ActiveVersion(version: activeVersion, healthy: healthy),
                previous: previous,
                pending: pending,
                highestSeenVersion: highestSeenVersion,
                blockedVersions: blockedVersions
            )
            guard capsuleId == expectedCapsuleId else { throw invalid("Registry filename identity differs") }
            try validate(registry)
            guard try serialize(registry) == data else { throw invalid("Registry is not canonical") }
            return registry
        } catch let error as WebCapsuleError where error.code == .registryInvalid {
            throw error
        } catch {
            throw invalid("Registry JSON, schema, or semantics are invalid")
        }
    }

    static func serialize(_ registry: CapsuleRegistry) throws -> Data {
        try validate(registry)
        let active = StrictJSONValue.object(StrictJSONObject(entries: [
            ("version", .string(registry.active.version)),
            ("healthy", .bool(registry.active.healthy)),
        ]))
        let previous: StrictJSONValue = registry.previous.map {
            .object(StrictJSONObject(entries: [("version", .string($0.version))]))
        } ?? .null
        let pending: StrictJSONValue = registry.pending.map {
            .object(StrictJSONObject(entries: [
                ("version", .string($0.version)),
                ("attempts", .integer($0.attempts)),
            ]))
        } ?? .null
        let value = StrictJSONValue.object(StrictJSONObject(entries: [
            ("schemaVersion", .integer(1)),
            ("capsuleId", .string(registry.capsuleId)),
            ("generation", .integer(registry.generation)),
            ("active", active),
            ("previous", previous),
            ("pending", pending),
            ("highestSeenVersion", .string(registry.highestSeenVersion)),
            ("blockedVersions", .array(registry.blockedVersions.map(StrictJSONValue.string))),
        ]))
        var data = CanonicalJSON.serialize(value)
        data.append(0x0A)
        return data
    }

    static func validate(_ registry: CapsuleRegistry) throws {
        do {
            guard registry.schemaVersion == 1,
                  (0...registryMaximumSafeInteger).contains(registry.generation) else {
                throw invalid("Registry scalar invariant failed")
            }
            try CapsuleManifestParser.validateCapsuleID(registry.capsuleId)
            try SemanticVersion.validate(registry.active.version)
            if let previous = registry.previous { try SemanticVersion.validate(previous.version) }
            if let pending = registry.pending {
                try SemanticVersion.validate(pending.version)
                guard (0...registryMaximumPendingAttempts).contains(pending.attempts) else {
                    throw invalid("Pending attempts are invalid")
                }
            }
            try SemanticVersion.validate(registry.highestSeenVersion)
            try registry.blockedVersions.forEach(SemanticVersion.validate)

            if registry.active.healthy {
                guard registry.pending == nil else { throw invalid("Healthy active must not be pending") }
            } else {
                guard registry.pending?.version == registry.active.version else {
                    throw invalid("Unhealthy active must be the pending trial")
                }
            }
            guard registry.previous?.version != registry.active.version else {
                throw invalid("Previous must differ from active")
            }
            let stateVersions = [registry.active.version, registry.previous?.version, registry.pending?.version].compactMap { $0 }
            guard Set(registry.blockedVersions).count == registry.blockedVersions.count,
                  registry.blockedVersions.allSatisfy({ !stateVersions.contains($0) }) else {
                throw invalid("Blocked versions are invalid")
            }
            for pair in zip(registry.blockedVersions, registry.blockedVersions.dropFirst()) {
                guard try SemanticVersion.compare(pair.0, pair.1) == .orderedDescending else {
                    throw invalid("Blocked versions are not strictly descending")
                }
            }
            for version in stateVersions + registry.blockedVersions {
                guard try SemanticVersion.compare(registry.highestSeenVersion, version) != .orderedAscending else {
                    throw invalid("highestSeenVersion is too low")
                }
            }
        } catch let error as WebCapsuleError where error.code == .registryInvalid {
            throw error
        } catch {
            throw invalid("Registry semantic invariant failed")
        }
    }

    private static func parsePrevious(_ value: StrictJSONValue) throws -> PreviousVersion? {
        if case .null = value { return nil }
        guard case let .object(object) = value else { throw invalid("previous must be an object or null") }
        try exact(object, fields: previousFields, label: "previous")
        guard case let .string(version) = try required(object, "version") else {
            throw invalid("Previous version must be a string")
        }
        return PreviousVersion(version: version)
    }

    private static func parsePending(_ value: StrictJSONValue) throws -> PendingVersion? {
        if case .null = value { return nil }
        guard case let .object(object) = value else { throw invalid("pending must be an object or null") }
        try exact(object, fields: pendingFields, label: "pending")
        guard case let .string(version) = try required(object, "version"),
              case let .integer(attempts) = try required(object, "attempts") else {
            throw invalid("Pending fields have invalid types")
        }
        return PendingVersion(version: version, attempts: attempts)
    }

    private static func exact(_ object: StrictJSONObject, fields: Set<String>, label: String) throws {
        guard object.entries.count == fields.count,
              Set(object.entries.map(\.key)) == fields else {
            throw invalid("\(label) fields differ")
        }
    }

    private static func required(_ object: StrictJSONObject, _ key: String) throws -> StrictJSONValue {
        guard let value = object[key] else { throw invalid("Registry field is missing") }
        return value
    }

    private static func invalid(_ message: String) -> WebCapsuleError {
        WebCapsuleError(code: .registryInvalid, message: message)
    }
}

final class RegistryManager {
    private let storage: CapsuleStorage

    init(storage: CapsuleStorage) {
        self.storage = storage
    }

    func readLocked(capsuleId: String) throws -> CapsuleRegistry? {
        try storage.readRegistry(capsuleId: capsuleId).map {
            try RegistryCodec.parse($0, expectedCapsuleId: capsuleId)
        }
    }

    func createInitialLocked(record: VersionRecord) throws -> CapsuleRegistry {
        guard try readLocked(capsuleId: record.capsuleId) == nil else {
            throw WebCapsuleError(code: .registryInvalid, message: "Registry already exists")
        }
        let registry = fresh(record: record)
        try storage.replaceRegistry(capsuleId: record.capsuleId, bytes: RegistryCodec.serialize(registry))
        return registry
    }

    func replaceFreshLocked(record: VersionRecord) throws -> CapsuleRegistry {
        let registry = fresh(record: record)
        try storage.replaceRegistry(capsuleId: record.capsuleId, bytes: RegistryCodec.serialize(registry))
        return registry
    }

    func compareAndSwapLocked(
        capsuleId: String,
        expectedGeneration: Int64,
        transform: (CapsuleRegistry) throws -> CapsuleRegistry
    ) throws -> CapsuleRegistry {
        let current: CapsuleRegistry
        do {
            guard let read = try readLocked(capsuleId: capsuleId) else {
                throw WebCapsuleError(code: .registryInvalid, message: "Registry is missing")
            }
            current = read
        } catch {
            throw WebCapsuleError(code: .updateStateChanged, message: "Registry cannot satisfy generation comparison")
        }
        guard current.generation == expectedGeneration, current.generation < registryMaximumSafeInteger else {
            throw WebCapsuleError(code: .updateStateChanged, message: "Registry generation changed or is exhausted")
        }
        let next = try transform(current)
        guard next.schemaVersion == 1,
              next.capsuleId == capsuleId,
              next.generation == current.generation + 1 else {
            throw WebCapsuleError(code: .registryInvalid, message: "Registry update identity or generation is invalid")
        }
        try storage.replaceRegistry(capsuleId: capsuleId, bytes: RegistryCodec.serialize(next))
        return next
    }

    func incrementPendingAttemptLocked(_ expected: CapsuleRegistry) throws -> CapsuleRegistry {
        guard let pending = expected.pending,
              !expected.active.healthy,
              expected.active.version == pending.version,
              pending.attempts < registryMaximumPendingAttempts else {
            throw WebCapsuleError(code: .registryInvalid, message: "Pending trial cannot be attempted")
        }
        do {
            return try compareAndSwapLocked(
                capsuleId: expected.capsuleId,
                expectedGeneration: expected.generation
            ) { current in
                guard current == expected else {
                    throw WebCapsuleError(code: .sessionMismatch, message: "Registry changed before trial")
                }
                return CapsuleRegistry(
                    schemaVersion: 1,
                    capsuleId: current.capsuleId,
                    generation: current.generation + 1,
                    active: current.active,
                    previous: current.previous,
                    pending: PendingVersion(version: pending.version, attempts: pending.attempts + 1),
                    highestSeenVersion: current.highestSeenVersion,
                    blockedVersions: current.blockedVersions
                )
            }
        } catch let error as WebCapsuleError where error.code == .updateStateChanged {
            throw WebCapsuleError(code: .sessionMismatch, message: "Registry changed before trial")
        }
    }

    func commitHealthyLocked(session: SessionDescriptor) throws -> CapsuleRegistry {
        try sessionTransition {
            try compareAndSwapLocked(
                capsuleId: session.capsuleId,
                expectedGeneration: session.registryGeneration
            ) { current in
                try self.assertSession(current, session: session)
                return CapsuleRegistry(
                    schemaVersion: 1,
                    capsuleId: current.capsuleId,
                    generation: current.generation + 1,
                    active: ActiveVersion(version: current.active.version, healthy: true),
                    previous: current.previous,
                    pending: nil,
                    highestSeenVersion: current.highestSeenVersion,
                    blockedVersions: current.blockedVersions
                )
            }
        }
    }

    func rollbackPendingLocked(
        session: SessionDescriptor,
        restoredVersion: String
    ) throws -> CapsuleRegistry {
        try sessionTransition {
            try compareAndSwapLocked(
                capsuleId: session.capsuleId,
                expectedGeneration: session.registryGeneration
            ) { current in
                try self.assertSession(current, session: session)
                guard current.pending?.attempts == registryMaximumPendingAttempts,
                      current.previous?.version == restoredVersion else {
                    throw WebCapsuleError(code: .sessionMismatch, message: "Final rollback state differs")
                }
                return CapsuleRegistry(
                    schemaVersion: 1,
                    capsuleId: current.capsuleId,
                    generation: current.generation + 1,
                    active: ActiveVersion(version: restoredVersion, healthy: true),
                    previous: nil,
                    pending: nil,
                    highestSeenVersion: current.highestSeenVersion,
                    blockedVersions: try self.insertBlocked(current.blockedVersions, session.version)
                )
            }
        }
    }

    func rollbackExhaustedLocked(_ expected: CapsuleRegistry, restoredVersion: String) throws -> CapsuleRegistry {
        try compareAndSwapLocked(capsuleId: expected.capsuleId, expectedGeneration: expected.generation) { current in
            guard current == expected,
                  !current.active.healthy,
                  current.pending?.attempts == registryMaximumPendingAttempts,
                  current.previous?.version == restoredVersion else {
                throw WebCapsuleError(code: .updateStateChanged, message: "Exhausted pending state changed")
            }
            return CapsuleRegistry(
                schemaVersion: 1,
                capsuleId: current.capsuleId,
                generation: current.generation + 1,
                active: ActiveVersion(version: restoredVersion, healthy: true),
                previous: nil,
                pending: nil,
                highestSeenVersion: current.highestSeenVersion,
                blockedVersions: try insertBlocked(current.blockedVersions, current.active.version)
            )
        }
    }

    func registerBundledFallbackLocked(_ expected: CapsuleRegistry, record: VersionRecord) throws -> CapsuleRegistry {
        try compareAndSwapLocked(capsuleId: expected.capsuleId, expectedGeneration: expected.generation) { current in
            guard current == expected,
                  record.capsuleId == current.capsuleId,
                  record.version != current.active.version else {
                throw WebCapsuleError(code: .updateStateChanged, message: "Bundled fallback state changed")
            }
            let highest = try SemanticVersion.compare(record.version, current.highestSeenVersion) == .orderedDescending
                ? record.version : current.highestSeenVersion
            return CapsuleRegistry(
                schemaVersion: 1,
                capsuleId: current.capsuleId,
                generation: current.generation + 1,
                active: ActiveVersion(version: record.version, healthy: false),
                previous: nil,
                pending: PendingVersion(version: record.version, attempts: 0),
                highestSeenVersion: highest,
                blockedVersions: try insertBlocked(current.blockedVersions, current.active.version)
            )
        }
    }

    private func assertSession(_ current: CapsuleRegistry, session: SessionDescriptor) throws {
        guard current.generation == session.registryGeneration,
              !current.active.healthy,
              current.active.version == session.version,
              current.pending?.version == session.trialVersion,
              current.pending?.attempts == session.trialAttempt else {
            throw WebCapsuleError(code: .sessionMismatch, message: "Pending trial no longer matches session")
        }
    }

    private func sessionTransition<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as WebCapsuleError where
            error.code == .registryInvalid || error.code == .updateStateChanged {
            throw WebCapsuleError(code: .sessionMismatch, message: "Registry changed during session")
        }
    }

    private func fresh(record: VersionRecord) -> CapsuleRegistry {
        CapsuleRegistry(
            schemaVersion: 1,
            capsuleId: record.capsuleId,
            generation: 0,
            active: ActiveVersion(version: record.version, healthy: false),
            previous: nil,
            pending: PendingVersion(version: record.version, attempts: 0),
            highestSeenVersion: record.version,
            blockedVersions: []
        )
    }

    private func insertBlocked(_ existing: [String], _ version: String) throws -> [String] {
        var result = Array(Set(existing + [version]))
        result.sort { left, right in
            (try? SemanticVersion.compare(left, right)) == .orderedDescending
        }
        return result
    }
}
