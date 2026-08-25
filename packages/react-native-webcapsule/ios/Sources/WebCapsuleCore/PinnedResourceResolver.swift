import CryptoKit
import Darwin
import Foundation

public struct PinnedResourceMetadata: Equatable, Sendable {
    public let url: URL
    public let mediaType: String
    public let contentLength: Int64

    init(url: URL, mediaType: String, contentLength: Int64) {
        self.url = url
        self.mediaType = mediaType
        self.contentLength = contentLength
    }
}

final class PinnedBlobStream: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let expectedSize: Int64
    private let expectedSHA256: String
    private var digest = SHA256()
    private var offset: Int64 = 0
    private var completedValidated = false

    init(descriptor: Int32, expectedSize: Int64, expectedSHA256: String) {
        self.descriptor = descriptor
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
    }

    func read(maximumCount: Int) throws -> Data? {
        precondition(maximumCount > 0)
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return nil }
        guard offset < expectedSize else {
            if !completedValidated { try validateCompletedStreamLocked() }
            closeLocked()
            return nil
        }
        let requested = min(maximumCount, Int(expectedSize - offset))
        var buffer = [UInt8](repeating: 0, count: requested)
        while true {
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0 {
                if errno == EINTR { continue }
                closeLocked()
                throw WebCapsuleError(
                    code: .storageInvariantViolation,
                    message: "Pinned CAS blob cannot be streamed"
                )
            }
            guard count > 0 else {
                closeLocked()
                throw WebCapsuleError(
                    code: .storageInvariantViolation,
                    message: "Pinned CAS blob ended before its declared size"
                )
            }
            let data = Data(buffer[0..<count])
            digest.update(data: data)
            offset += Int64(count)
            if offset == expectedSize {
                try validateCompletedStreamLocked()
            }
            return data
        }
    }

    func close() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    private func validateCompletedStreamLocked() throws {
        guard descriptor >= 0 else { return }
        var attributes = stat()
        let observed = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard offset == expectedSize,
              observed == expectedSHA256,
              Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == Darwin.geteuid(),
              attributes.st_mode & 0o777 == S_IRUSR | S_IRGRP | S_IROTH,
              attributes.st_size == expectedSize else {
            closeLocked()
            throw WebCapsuleError(
                code: .storageInvariantViolation,
                message: "Pinned CAS blob changed while streaming"
            )
        }
        completedValidated = true
    }

    private func closeLocked() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit { close() }
}

final class PinnedResource {
    let metadata: PinnedResourceMetadata
    let stream: PinnedBlobStream

    init(metadata: PinnedResourceMetadata, stream: PinnedBlobStream) {
        self.metadata = metadata
        self.stream = stream
    }
}

/// Resolves only resources declared by one immutable session descriptor.
/// Registry state is neither read nor consulted after initialization.
public final class PinnedResourceResolver: @unchecked Sendable {
    public static let scheme = "webcapsule"

    private let session: SessionDescriptor
    private let storage: CapsuleStorage
    private let afterBlobOpen: @Sendable () throws -> Void

    public convenience init(storageRootURL: URL, session: SessionDescriptor) throws {
        try self.init(storageRootURL: storageRootURL, session: session, afterBlobOpen: {})
    }

    init(
        storageRootURL: URL,
        session: SessionDescriptor,
        afterBlobOpen: @escaping @Sendable () throws -> Void
    ) throws {
        let storage = try CapsuleStorage(rootURL: storageRootURL, createLayout: false)
        try storage.pinResourceShards(Array(session.files.values))
        self.storage = storage
        self.session = session
        self.afterBlobOpen = afterBlobOpen
    }

    public var entryURL: URL {
        // Descriptor values were validated before selection, so construction cannot fail.
        URL(string: Self.urlString(
            capsuleId: session.capsuleId,
            version: session.version,
            path: session.entry
        ))!
    }

    func resolve(_ url: URL) throws -> PinnedResource {
        try resolve(rawURL: url.absoluteString)
    }

    func resolve(rawURL: String) throws -> PinnedResource {
        let parsed = try parse(rawURL)
        guard let file = session.files[parsed.path] else {
            throw denied("Resource is not declared by the pinned session")
        }
        let stream = try storage.openPinnedBlob(file)
        do {
            try afterBlobOpen()
        } catch {
            stream.close()
            throw error
        }
        guard let responseURL = URL(string: rawURL), responseURL.absoluteString == rawURL else {
            stream.close()
            throw denied("Resource URL is invalid")
        }
        return PinnedResource(
            metadata: PinnedResourceMetadata(
                url: responseURL,
                mediaType: file.mediaType,
                contentLength: file.size
            ),
            stream: stream
        )
    }

    static func urlString(capsuleId: String, version: String, path: String) -> String {
        let encodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { PercentCodec.encode(String($0)) }
            .joined(separator: "/")
        return "\(scheme)://\(PercentCodec.encode(capsuleId))/\(PercentCodec.encode(version))/\(encodedPath)"
    }

    private func parse(_ rawURL: String) throws -> (path: String, query: String?) {
        guard !rawURL.contains("#"), rawURL.hasPrefix("\(Self.scheme)://") else {
            throw denied("Resource scheme or fragment is invalid")
        }
        let remainder = rawURL.dropFirst(Self.scheme.utf8.count + 3)
        let pathAndAuthority: Substring
        let query: String?
        if let queryIndex = remainder.firstIndex(of: "?") {
            pathAndAuthority = remainder[..<queryIndex]
            query = String(remainder[remainder.index(after: queryIndex)...])
        } else {
            pathAndAuthority = remainder
            query = nil
        }
        guard let slash = pathAndAuthority.firstIndex(of: "/") else {
            throw denied("Resource version or content path is absent")
        }
        let authority = String(pathAndAuthority[..<slash])
        guard !authority.isEmpty,
              !authority.contains("@"),
              !authority.contains(":"),
              authority == PercentCodec.encode(session.capsuleId),
              try PercentCodec.decodeSegment(authority) == session.capsuleId else {
            throw denied("Resource authority differs from the pinned capsule")
        }
        let encodedPath = pathAndAuthority[pathAndAuthority.index(after: slash)...]
        let segments = encodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2 else {
            throw denied("Resource version or content path is absent")
        }
        let encodedVersion = String(segments[0])
        guard encodedVersion == PercentCodec.encode(session.version),
              try PercentCodec.decodeSegment(encodedVersion) == session.version else {
            throw denied("Resource version differs from the pinned session")
        }
        let decodedPath = try segments.dropFirst().map { try PercentCodec.decodeSegment(String($0)) }
            .joined(separator: "/")
        do {
            try CapsulePathValidator.validate(decodedPath)
        } catch {
            throw denied("Resource content path is unsafe")
        }
        return (decodedPath, query)
    }

    private func denied(_ message: String) -> WebCapsuleError {
        WebCapsuleError(code: .resourceDenied, message: message)
    }
}

enum PercentCodec {
    private static let hexadecimal = Array("0123456789ABCDEF".utf8)

    static func encode(_ value: String) -> String {
        String(decoding: value.utf8.flatMap { byte -> [UInt8] in
            if isUnreserved(byte) { return [byte] }
            return [0x25, hexadecimal[Int(byte >> 4)], hexadecimal[Int(byte & 0x0F)]]
        }, as: UTF8.self)
    }

    static func decodeSegment(_ value: String) throws -> String {
        guard !value.isEmpty else { throw denied("Empty URL path segment") }
        let input = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == 0x25 {
                guard index + 2 < input.count,
                      let high = nibble(input[index + 1]),
                      let low = nibble(input[index + 2]) else {
                    throw denied("Malformed percent escape")
                }
                let decoded = high << 4 | low
                guard decoded != 0x2F, decoded != 0x5C else {
                    throw denied("Encoded path separator is forbidden")
                }
                output.append(decoded)
                index += 3
            } else {
                guard byte < 0x80, byte != 0x5C else {
                    throw denied("URL segment is not canonical encoded UTF-8")
                }
                output.append(byte)
                index += 1
            }
        }
        guard let decoded = String(bytes: output, encoding: .utf8),
              !containsEncodedOctet(decoded.utf8),
              encode(decoded) == value else {
            throw denied("URL segment encoding is not canonical")
        }
        return decoded
    }

    private static func containsEncodedOctet(_ bytes: String.UTF8View) -> Bool {
        let values = Array(bytes)
        guard values.count >= 3 else { return false }
        for index in 0...(values.count - 3) where values[index] == 0x25 {
            if nibble(values[index + 1]) != nil,
               nibble(values[index + 2]) != nil {
                return true
            }
        }
        return false
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte)
            || [0x2D, 0x2E, 0x5F, 0x7E].contains(byte)
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        default: return nil
        }
    }

    private static func denied(_ message: String) -> WebCapsuleError {
        WebCapsuleError(code: .resourceDenied, message: message)
    }
}
