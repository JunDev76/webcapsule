import Darwin
import Foundation
import zlib

struct StrictZipEntry: Equatable {
    let name: String
    let flags: UInt16
    let compressionMethod: UInt16
    let dosTime: UInt16
    let dosDate: UInt16
    let crc32: UInt32
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32

    fileprivate let dataOffset: UInt64
    fileprivate let rangeEnd: UInt64
    fileprivate let ownerID: UUID
}

struct StrictZipExtractionResult: Equatable {
    let size: UInt64
    let crc32: UInt32
}

final class StrictZipReader {
    static let defaultArchiveSizeLimit: UInt64 = 100 * 1024 * 1024
    static let defaultEntryCountLimit = CapsulePathValidator.maximumFileCount + 2

    let entries: [StrictZipEntry]

    private let file: FileHandle
    private let archiveSize: UInt64
    private let ownerID: UUID

    init(
        archiveURL: URL,
        archiveSizeLimit: UInt64 = StrictZipReader.defaultArchiveSizeLimit,
        entryCountLimit: Int = StrictZipReader.defaultEntryCountLimit
    ) throws {
        guard archiveURL.isFileURL, entryCountLimit >= 0 else {
            throw WebCapsuleError(code: .invalidArgument, message: "Invalid ZIP reader argument")
        }
        let descriptor = Darwin.open(archiveURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .archiveInvalid, message: "Capsule archive cannot be opened")
        }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0 else {
            Darwin.close(descriptor)
            throw WebCapsuleError(code: .archiveInvalid, message: "Capsule archive must be a regular file")
        }
        let size = UInt64(attributes.st_size)
        guard size <= archiveSizeLimit else {
            Darwin.close(descriptor)
            throw WebCapsuleError(code: .limitExceeded, message: "Capsule archive exceeds its size limit")
        }

        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let readerID = UUID()
        file = opened
        archiveSize = size
        ownerID = readerID
        do {
            entries = try StrictZipReader.parse(
                file: opened,
                archiveSize: size,
                entryCountLimit: entryCountLimit,
                ownerID: readerID
            )
        } catch {
            try? opened.close()
            throw error
        }
    }

    deinit {
        try? file.close()
    }

    func extractData(_ entry: StrictZipEntry, maximumSize: UInt64) throws -> Data {
        try requireOwned(entry)
        var result = Data()
        _ = try inflate(entry, maximumSize: maximumSize) { bytes in
            result.append(bytes.bindMemory(to: UInt8.self))
        }
        return result
    }

    func extract(
        _ entry: StrictZipEntry,
        to outputURL: URL,
        maximumSize: UInt64
    ) throws -> StrictZipExtractionResult {
        try requireOwned(entry)
        guard outputURL.isFileURL else {
            throw WebCapsuleError(code: .invalidArgument, message: "Extraction target must be a file URL")
        }
        guard UInt64(entry.uncompressedSize) <= maximumSize else {
            throw WebCapsuleError(code: .limitExceeded, message: "ZIP entry exceeds its extraction limit")
        }

        let descriptor = Darwin.open(outputURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw WebCapsuleError(code: .storageIOFailed, message: "Extraction target cannot be created")
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var createdAttributes = stat()
        guard Darwin.fstat(descriptor, &createdAttributes) == 0 else {
            try? output.close()
            _ = Darwin.unlink(outputURL.path)
            throw WebCapsuleError(code: .storageIOFailed, message: "Extraction target cannot be inspected")
        }
        var completed = false
        defer {
            try? output.close()
            if !completed {
                unlinkIfSameFile(outputURL.path, attributes: createdAttributes)
            }
        }
        do {
            let observed = try inflate(entry, maximumSize: maximumSize) { bytes in
                try output.write(contentsOf: Data(bytes))
            }
            try output.synchronize()
            completed = true
            return observed
        } catch let error as WebCapsuleError {
            throw error
        } catch {
            throw WebCapsuleError(code: .storageIOFailed, message: "Extracted bytes cannot be written")
        }
    }

    private func requireOwned(_ entry: StrictZipEntry) throws {
        guard entry.ownerID == ownerID, entries.contains(entry) else {
            throw WebCapsuleError(code: .invalidArgument, message: "ZIP entry does not belong to this reader")
        }
    }

    private func inflate(
        _ entry: StrictZipEntry,
        maximumSize: UInt64,
        sink: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> StrictZipExtractionResult {
        guard UInt64(entry.uncompressedSize) <= maximumSize else {
            throw WebCapsuleError(code: .limitExceeded, message: "ZIP entry exceeds its extraction limit")
        }

        var stream = z_stream()
        let initialized = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else {
            throw WebCapsuleError(code: .archiveInvalid, message: "Raw DEFLATE initialization failed")
        }
        defer { inflateEnd(&stream) }

        var inputOffset = entry.dataOffset
        var compressedRemaining = UInt64(entry.compressedSize)
        var observedSize: UInt64 = 0
        var crc = CRC32()
        var reachedEnd = false
        var outputBuffer = [UInt8](repeating: 0, count: 64 * 1024)

        while compressedRemaining > 0, !reachedEnd {
            let count = Int(min(compressedRemaining, UInt64(64 * 1024)))
            let input = try readExactly(file: file, archiveSize: archiveSize, offset: inputOffset, count: count)
            inputOffset = try checkedAdd(inputOffset, UInt64(count))
            compressedRemaining -= UInt64(count)

            try input.withUnsafeBytes { inputBytes in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(inputBytes.count)
                while !reachedEnd {
                    var status: Int32 = Z_OK
                    let produced = outputBuffer.withUnsafeMutableBytes { outputBytes -> Int in
                        stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(outputBytes.count)
                        status = zlib.inflate(&stream, Z_NO_FLUSH)
                        return outputBytes.count - Int(stream.avail_out)
                    }
                    let needsMoreInput = status == Z_BUF_ERROR && stream.avail_in == 0 && produced == 0
                    guard status == Z_OK || status == Z_STREAM_END || needsMoreInput else {
                        throw WebCapsuleError(code: .archiveInvalid, message: "Raw DEFLATE stream is invalid")
                    }
                    if produced > 0 {
                        let nextSize = try checkedAdd(observedSize, UInt64(produced))
                        guard nextSize <= maximumSize else {
                            throw WebCapsuleError(code: .limitExceeded, message: "ZIP entry exceeds its extraction limit")
                        }
                        observedSize = nextSize
                        try outputBuffer.withUnsafeBytes { bytes in
                            let producedBytes = UnsafeRawBufferPointer(rebasing: bytes[..<produced])
                            crc.update(producedBytes)
                            try sink(producedBytes)
                        }
                    }
                    if status == Z_STREAM_END {
                        reachedEnd = true
                    } else if needsMoreInput || (stream.avail_in == 0 && stream.avail_out > 0) {
                        break
                    } else if produced == 0, stream.avail_in > 0 {
                        throw WebCapsuleError(code: .archiveInvalid, message: "Raw DEFLATE stream made no progress")
                    }
                }
                if reachedEnd, stream.avail_in != 0 {
                    throw WebCapsuleError(code: .archiveInvalid, message: "Raw DEFLATE stream has trailing bytes")
                }
            }
        }

        guard reachedEnd, compressedRemaining == 0,
              UInt64(stream.total_in) == UInt64(entry.compressedSize),
              UInt64(stream.total_out) == observedSize,
              observedSize == UInt64(entry.uncompressedSize),
              crc.value == entry.crc32 else {
            throw WebCapsuleError(code: .archiveInvalid, message: "ZIP entry size or CRC does not match")
        }
        return StrictZipExtractionResult(size: observedSize, crc32: crc.value)
    }

    private static func parse(
        file: FileHandle,
        archiveSize: UInt64,
        entryCountLimit: Int,
        ownerID: UUID
    ) throws -> [StrictZipEntry] {
        guard archiveSize >= 22 else {
            throw WebCapsuleError(code: .archiveInvalid, message: "ZIP EOCD is missing")
        }
        let tailSize = min(archiveSize, UInt64(65_557))
        let tailOffset = archiveSize - tailSize
        let tail = try readExactly(file: file, archiveSize: archiveSize, offset: tailOffset, count: Int(tailSize))
        let signatures = signatureOffsets(in: tail, signature: 0x0605_4B50)
        guard signatures.count == 1, let relativeEOCD = signatures.first else {
            throw WebCapsuleError(code: .archiveInvalid, message: "ZIP EOCD is missing or ambiguous")
        }
        let eocdOffset = try checkedAdd(tailOffset, UInt64(relativeEOCD))
        guard try checkedAdd(eocdOffset, 22) == archiveSize else {
            throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP trailing bytes or archive comment are forbidden")
        }
        let eocd = try slice(tail, at: relativeEOCD, count: 22)
        let disk = eocd.uint16LE(at: 4)
        let centralDisk = eocd.uint16LE(at: 6)
        let diskEntryCount = eocd.uint16LE(at: 8)
        let entryCount = eocd.uint16LE(at: 10)
        let centralSize = eocd.uint32LE(at: 12)
        let centralOffset = eocd.uint32LE(at: 16)
        let commentLength = eocd.uint16LE(at: 20)

        guard disk == 0, centralDisk == 0, diskEntryCount == entryCount else {
            throw WebCapsuleError(code: .invalidArchiveProfile, message: "Multi-disk ZIP archives are forbidden")
        }
        guard commentLength == 0 else {
            throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP archive comments are forbidden")
        }
        guard entryCount != UInt16.max, centralSize != UInt32.max, centralOffset != UInt32.max else {
            throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP64 is forbidden")
        }
        if eocdOffset >= 20 {
            let locator = try readExactly(file: file, archiveSize: archiveSize, offset: eocdOffset - 20, count: 4)
            if locator.uint32LE(at: 0) == 0x0706_4B50 {
                throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP64 locator is forbidden")
            }
        }
        guard Int(entryCount) <= entryCountLimit else {
            throw WebCapsuleError(code: .limitExceeded, message: "ZIP entry count limit exceeded")
        }
        let centralEnd = try checkedAdd(UInt64(centralOffset), UInt64(centralSize))
        guard centralEnd == eocdOffset else {
            throw WebCapsuleError(code: .archiveInvalid, message: "ZIP central directory bounds are inconsistent")
        }

        var entries: [StrictZipEntry] = []
        entries.reserveCapacity(Int(entryCount))
        var position = UInt64(centralOffset)
        for _ in 0..<entryCount {
            let header = try readExactly(file: file, archiveSize: archiveSize, offset: position, count: 46)
            guard header.uint32LE(at: 0) == 0x0201_4B50 else {
                throw WebCapsuleError(code: .archiveInvalid, message: "ZIP central header signature is invalid")
            }
            let madeBy = header.uint16LE(at: 4)
            let versionNeeded = header.uint16LE(at: 6)
            let flags = header.uint16LE(at: 8)
            let method = header.uint16LE(at: 10)
            let dosTime = header.uint16LE(at: 12)
            let dosDate = header.uint16LE(at: 14)
            let crc = header.uint32LE(at: 16)
            let compressedSize = header.uint32LE(at: 20)
            let uncompressedSize = header.uint32LE(at: 24)
            let nameLength = header.uint16LE(at: 28)
            let extraLength = header.uint16LE(at: 30)
            let commentLength = header.uint16LE(at: 32)
            let diskStart = header.uint16LE(at: 34)
            let externalAttributes = header.uint32LE(at: 38)
            let localOffset = header.uint32LE(at: 42)

            guard versionNeeded < 45,
                  compressedSize != UInt32.max,
                  uncompressedSize != UInt32.max,
                  localOffset != UInt32.max,
                  diskStart == 0,
                  extraLength == 0,
                  commentLength == 0 else {
                throw WebCapsuleError(code: .invalidArchiveProfile, message: "Forbidden central ZIP metadata")
            }
            guard flags == 0x0800 || flags == 0x0808, method == 8 else {
                throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP flags or compression method are invalid")
            }
            guard madeBy >> 8 == 3, externalAttributes == 0x81A4_0000 else {
                throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP entry must be a Unix 0644 regular file")
            }

            let nameOffset = try checkedAdd(position, 46)
            let nameBytes = try readExactly(
                file: file,
                archiveSize: archiveSize,
                offset: nameOffset,
                count: Int(nameLength)
            )
            let name = try decodeName(nameBytes)
            guard !name.hasSuffix("/") else {
                throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP directory entries are forbidden")
            }
            try validateArchivePath(name)
            let local = try parseLocal(
                file: file,
                archiveSize: archiveSize,
                offset: UInt64(localOffset),
                nameBytes: nameBytes,
                flags: flags,
                method: method,
                dosTime: dosTime,
                dosDate: dosDate,
                crc: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize
            )
            entries.append(StrictZipEntry(
                name: name,
                flags: flags,
                compressionMethod: method,
                dosTime: dosTime,
                dosDate: dosDate,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset,
                dataOffset: local.dataOffset,
                rangeEnd: local.rangeEnd,
                ownerID: ownerID
            ))
            position = try checkedAdd(nameOffset, UInt64(nameLength))
        }
        guard position == centralEnd else {
            throw WebCapsuleError(code: .archiveInvalid, message: "ZIP central records do not fill the directory")
        }

        try validateEntryProfile(entries, centralOffset: UInt64(centralOffset))
        return entries
    }

    private static func parseLocal(
        file: FileHandle,
        archiveSize: UInt64,
        offset: UInt64,
        nameBytes: Data,
        flags: UInt16,
        method: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        crc: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32
    ) throws -> (dataOffset: UInt64, rangeEnd: UInt64) {
        let header = try readExactly(file: file, archiveSize: archiveSize, offset: offset, count: 30)
        guard header.uint32LE(at: 0) == 0x0403_4B50 else {
            throw WebCapsuleError(code: .archiveInvalid, message: "ZIP local header signature is invalid")
        }
        let localFlags = header.uint16LE(at: 6)
        let localMethod = header.uint16LE(at: 8)
        let localTime = header.uint16LE(at: 10)
        let localDate = header.uint16LE(at: 12)
        let localCRC = header.uint32LE(at: 14)
        let localCompressed = header.uint32LE(at: 18)
        let localUncompressed = header.uint32LE(at: 22)
        let localNameLength = header.uint16LE(at: 26)
        let localExtraLength = header.uint16LE(at: 28)
        guard localFlags == flags,
              localMethod == method,
              localTime == dosTime,
              localDate == dosDate,
              localNameLength == nameBytes.count,
              localExtraLength == 0 else {
            throw WebCapsuleError(code: .invalidArchiveProfile, message: "Local and central ZIP profiles differ")
        }
        let localNameOffset = try checkedAdd(offset, 30)
        let localName = try readExactly(
            file: file,
            archiveSize: archiveSize,
            offset: localNameOffset,
            count: Int(localNameLength)
        )
        guard localName == nameBytes else {
            throw WebCapsuleError(code: .invalidArchiveProfile, message: "Local and central ZIP names differ")
        }

        let usesDescriptor = flags & 0x0008 != 0
        if usesDescriptor {
            guard localCRC == 0, localCompressed == 0, localUncompressed == 0 else {
                throw WebCapsuleError(code: .invalidArchiveProfile, message: "Descriptor local values must be zero")
            }
        } else {
            guard localCRC == crc,
                  localCompressed == compressedSize,
                  localUncompressed == uncompressedSize else {
                throw WebCapsuleError(code: .invalidArchiveProfile, message: "Local and central ZIP sizes differ")
            }
        }

        let dataOffset = try checkedAdd(localNameOffset, UInt64(localNameLength))
        let dataEnd = try checkedAdd(dataOffset, UInt64(compressedSize))
        guard dataEnd <= archiveSize else {
            throw WebCapsuleError(code: .archiveInvalid, message: "ZIP entry data is truncated")
        }
        if usesDescriptor {
            let descriptor = try readExactly(file: file, archiveSize: archiveSize, offset: dataEnd, count: 16)
            guard descriptor.uint32LE(at: 0) == 0x0807_4B50,
                  descriptor.uint32LE(at: 4) == crc,
                  descriptor.uint32LE(at: 8) == compressedSize,
                  descriptor.uint32LE(at: 12) == uncompressedSize else {
                throw WebCapsuleError(code: .invalidArchiveProfile, message: "Signed ZIP data descriptor is invalid")
            }
            return (dataOffset, try checkedAdd(dataEnd, 16))
        }
        return (dataOffset, dataEnd)
    }

    private static func validateEntryProfile(_ entries: [StrictZipEntry], centralOffset: UInt64) throws {
        guard entries.count >= 2,
              entries[0].name == "capsule.json",
              entries[1].name == "capsule.sig" else {
            throw WebCapsuleError(code: .invalidOrder, message: "ZIP metadata entries are missing or out of order")
        }
        guard entries.dropFirst(2).allSatisfy({ $0.name.hasPrefix("files/") }) else {
            throw WebCapsuleError(code: .invalidOrder, message: "ZIP content entries must follow metadata entries")
        }
        let contentNames = entries.dropFirst(2).map(\.name)
        try CapsulePathValidator.validateSet(contentNames)
        try CapsulePathValidator.validateAscendingUTF8Order(contentNames)

        var expectedOffset: UInt64 = 0
        for entry in entries {
            guard UInt64(entry.localHeaderOffset) == expectedOffset,
                  entry.rangeEnd <= centralOffset else {
                throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP local records overlap, contain gaps, or intrude into the central directory")
            }
            expectedOffset = entry.rangeEnd
        }
        guard expectedOffset == centralOffset else {
            throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP bytes between local records and central directory are forbidden")
        }
    }

    private static func decodeName(_ bytes: Data) throws -> String {
        guard let value = String(data: bytes, encoding: .utf8), Data(value.utf8) == bytes else {
            throw WebCapsuleError(code: .invalidPath, message: "ZIP entry name is not exact UTF-8")
        }
        return value
    }

    private static func validateArchivePath(_ value: String) throws {
        if value.contains("\\") || value.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            throw WebCapsuleError(code: .invalidArchiveProfile, message: "ZIP entry contains a forbidden raw path")
        }
        try CapsulePathValidator.validate(value)
    }
}

private func unlinkIfSameFile(_ path: String, attributes: stat) {
    var current = stat()
    guard Darwin.lstat(path, &current) == 0,
          current.st_dev == attributes.st_dev,
          current.st_ino == attributes.st_ino else {
        return
    }
    _ = Darwin.unlink(path)
}

private struct CRC32 {
    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        for byte in bytes {
            state ^= UInt32(byte)
            for _ in 0..<8 {
                state = (state >> 1) ^ (state & 1 == 1 ? 0xEDB8_8320 : 0)
            }
        }
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
}

private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
        throw WebCapsuleError(code: .archiveInvalid, message: "ZIP offset arithmetic overflow")
    }
    return result
}

private func readExactly(
    file: FileHandle,
    archiveSize: UInt64,
    offset: UInt64,
    count: Int
) throws -> Data {
    guard count >= 0, try checkedAdd(offset, UInt64(count)) <= archiveSize else {
        throw WebCapsuleError(code: .archiveInvalid, message: "ZIP structure is truncated")
    }
    do {
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw WebCapsuleError(code: .archiveInvalid, message: "ZIP structure is truncated")
        }
        return data
    } catch let error as WebCapsuleError {
        throw error
    } catch {
        throw WebCapsuleError(code: .archiveInvalid, message: "ZIP archive cannot be read")
    }
}

private func slice(_ data: Data, at offset: Int, count: Int) throws -> Data {
    guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
        throw WebCapsuleError(code: .archiveInvalid, message: "ZIP structure is truncated")
    }
    return data.subdata(in: offset..<(offset + count))
}

private func signatureOffsets(in data: Data, signature: UInt32) -> [Int] {
    guard data.count >= 4 else { return [] }
    return (0...(data.count - 4)).filter { data.uint32LE(at: $0) == signature }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[index(startIndex, offsetBy: offset)])
            | UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 8
            | UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 16
            | UInt32(self[index(startIndex, offsetBy: offset + 3)]) << 24
    }
}
