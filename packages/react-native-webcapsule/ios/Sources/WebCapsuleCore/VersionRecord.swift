import Foundation

public struct VersionRecordFile: Equatable, Sendable {
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

/// Immutable metadata produced only after archive, signature, and content verification.
/// A version record is not a substitute for signature verification.
public struct VersionRecord: Equatable, Sendable {
    public let schemaVersion: Int
    public let capsuleId: String
    public let version: String
    public let keyId: String
    public let createdAt: String
    public let entry: String
    public let manifestSHA256: String
    public let files: [VersionRecordFile]

    init(
        schemaVersion: Int,
        capsuleId: String,
        version: String,
        keyId: String,
        createdAt: String,
        entry: String,
        manifestSHA256: String,
        files: [VersionRecordFile]
    ) {
        self.schemaVersion = schemaVersion
        self.capsuleId = capsuleId
        self.version = version
        self.keyId = keyId
        self.createdAt = createdAt
        self.entry = entry
        self.manifestSHA256 = manifestSHA256
        self.files = files
    }
}

enum VersionRecordCodec {
    private static let rootFields: Set<String> = [
        "schemaVersion", "capsuleId", "version", "keyId", "createdAt", "entry", "manifestSha256", "files",
    ]
    private static let fileFields: Set<String> = ["path", "sha256", "size", "mediaType"]

    static func fromVerified(_ capsule: VerifiedCapsule) throws -> VersionRecord {
        let record = VersionRecord(
            schemaVersion: 1,
            capsuleId: capsule.manifest.capsuleId,
            version: capsule.manifest.version,
            keyId: capsule.manifest.keyId,
            createdAt: capsule.manifest.createdAt,
            entry: capsule.manifest.entry,
            manifestSHA256: capsule.manifestSHA256,
            files: capsule.manifest.files.map {
                VersionRecordFile(path: $0.path, sha256: $0.sha256, size: $0.size, mediaType: $0.mediaType)
            }
        )
        try validate(record)
        return record
    }

    static func serialize(_ record: VersionRecord) throws -> Data {
        try validate(record)
        let files = record.files.map { file in
            StrictJSONValue.object(StrictJSONObject(entries: [
                ("path", .string(file.path)),
                ("sha256", .string(file.sha256)),
                ("size", .integer(file.size)),
                ("mediaType", .string(file.mediaType)),
            ]))
        }
        let value = StrictJSONValue.object(StrictJSONObject(entries: [
            ("schemaVersion", .integer(Int64(record.schemaVersion))),
            ("capsuleId", .string(record.capsuleId)),
            ("version", .string(record.version)),
            ("keyId", .string(record.keyId)),
            ("createdAt", .string(record.createdAt)),
            ("entry", .string(record.entry)),
            ("manifestSha256", .string(record.manifestSHA256)),
            ("files", .array(files)),
        ]))
        var data = CanonicalJSON.serialize(value)
        data.append(0x0A)
        return data
    }

    static func parse(_ data: Data) throws -> VersionRecord {
        do {
            guard data.last == 0x0A, data.dropLast().last != 0x0A else {
                throw invalid("Version record must end with exactly one LF")
            }
            let value = try StrictJSON.parse(Data(data.dropLast()))
            guard case let .object(root) = value,
                  Set(root.entries.map(\.key)) == rootFields,
                  root.entries.count == rootFields.count else {
                throw invalid("Version record fields differ")
            }
            guard case let .integer(schema) = try required(root, "schemaVersion"), schema == 1,
                  case let .string(capsuleId) = try required(root, "capsuleId"),
                  case let .string(version) = try required(root, "version"),
                  case let .string(keyId) = try required(root, "keyId"),
                  case let .string(createdAt) = try required(root, "createdAt"),
                  case let .string(entry) = try required(root, "entry"),
                  case let .string(manifestSHA256) = try required(root, "manifestSha256"),
                  case let .array(fileValues) = try required(root, "files") else {
                throw invalid("Version record field type is invalid")
            }
            let files = try fileValues.map { value -> VersionRecordFile in
                guard case let .object(file) = value,
                      Set(file.entries.map(\.key)) == fileFields,
                      file.entries.count == fileFields.count,
                      case let .string(path) = try required(file, "path"),
                      case let .string(sha256) = try required(file, "sha256"),
                      case let .integer(size) = try required(file, "size"),
                      case let .string(mediaType) = try required(file, "mediaType") else {
                    throw invalid("Version record file field is invalid")
                }
                return VersionRecordFile(path: path, sha256: sha256, size: size, mediaType: mediaType)
            }
            let record = VersionRecord(
                schemaVersion: 1,
                capsuleId: capsuleId,
                version: version,
                keyId: keyId,
                createdAt: createdAt,
                entry: entry,
                manifestSHA256: manifestSHA256,
                files: files
            )
            try validate(record)
            guard try serialize(record) == data else {
                throw invalid("Version record is not canonical")
            }
            return record
        } catch let error as WebCapsuleError where error.code == .versionRecordInvalid {
            throw error
        } catch {
            throw invalid("Version record is invalid")
        }
    }

    static func validate(_ record: VersionRecord) throws {
        guard record.schemaVersion == 1, isLowercaseSHA256(record.manifestSHA256) else {
            throw invalid("Version record schema or manifest digest is invalid")
        }
        let files = record.files.map { file in
            StrictJSONValue.object(StrictJSONObject(entries: [
                ("path", .string(file.path)),
                ("sha256", .string(file.sha256)),
                ("size", .integer(file.size)),
                ("mediaType", .string(file.mediaType)),
            ]))
        }
        let synthetic = StrictJSONValue.object(StrictJSONObject(entries: [
            ("formatVersion", .integer(1)),
            ("capsuleId", .string(record.capsuleId)),
            ("version", .string(record.version)),
            ("entry", .string(record.entry)),
            ("createdAt", .string(record.createdAt)),
            ("minimumRuntimeVersion", .string("0.0.0")),
            ("keyId", .string(record.keyId)),
            ("files", .array(files)),
            ("policy", .object(StrictJSONObject(entries: [
                ("network", .object(StrictJSONObject(entries: [("mode", .string("deny"))]))),
                ("navigation", .object(StrictJSONObject(entries: [("externalOrigins", .array([]))]))),
                ("bridgeCapabilities", .array([])),
            ]))),
        ]))
        do {
            _ = try CapsuleManifestParser.parse(synthetic)
        } catch {
            throw invalid("Version record semantics are invalid")
        }
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func required(_ object: StrictJSONObject, _ key: String) throws -> StrictJSONValue {
        guard let value = object[key] else { throw invalid("Version record field is missing") }
        return value
    }

    private static func invalid(_ message: String) -> WebCapsuleError {
        WebCapsuleError(code: .versionRecordInvalid, message: message)
    }
}
